#!/usr/bin/env bash
# gerrit:push - send new commits of the current GitLab branch to Gerrit.
#
#  1. Find the last content state both sides agree on (sync_point), and copy
#     the GitLab commits made after it onto the Gerrit branch, mapping
#     identities and adding missing Change-Ids (map-commit.sh). Commits whose
#     changes are already in Gerrit become empty and are dropped.
#  2. Upload them with `git review` (one Gerrit change per commit).
#  3. If GERRIT_AUTO_SUBMIT=true: vote Code-Review +2 and submit each change,
#     oldest first.
#  4. Copy commits that exist only in Gerrit back to GitLab (see sync_branch).
# The GitLab branch itself is never rewritten.

# shellcheck source=gerrit-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/gerrit-common.sh"

branch="${CI_COMMIT_BRANCH:?This job must run on a branch pipeline}"
target="$(gerrit_branch_for "$branch")"
base="refs/remotes/gerrit/${target}"

setup_ssh
setup_identities
setup_gerrit_remote

git rev-parse -q --verify "${base}^{commit}" > /dev/null \
	|| die "Branch '${target}' does not exist in Gerrit (${GERRIT_PROJECT}). Ask a Gerrit admin to create it."

log "GitLab ${branch}@${CI_COMMIT_SHA:0:9} -> Gerrit ${target}@$(git rev-parse --short "$base")"
git checkout --quiet -B ci-push "$CI_COMMIT_SHA"

point="$(sync_point "$base" HEAD)" \
	|| die "GitLab '${branch}' and Gerrit '${target}' have no content in common; see README (first run)."
read -r _ gitlab_point <<< "$point"
log "Last state shared with Gerrit: $(git log -1 --format='%h %s' "$gitlab_point")"

if ! rebase_mapped to-gerrit "$base" "$gitlab_point"; then
	git rebase --abort || true
	die "GitLab commits do not apply cleanly on Gerrit '${target}' (someone changed the same lines in Gerrit)." \
		"Fix it on GitLab, or run the manual job gerrit:align (see README)."
fi

mapfile -t commits < <(git rev-list --reverse "${base}..HEAD")

if [ "${#commits[@]}" -eq 0 ]; then
	log "Nothing new to send: Gerrit '${target}' already has every change."
else
	log "Sending ${#commits[@]} commit(s) to Gerrit:"
	git log --reverse --format='    %h %s' "${base}..HEAD"

	# git-review downloads Gerrit's commit-msg hook when none is installed.
	# Change-Ids are already handled by map-commit.sh, so a stub is enough.
	hook="$(git rev-parse --git-path hooks/commit-msg)"
	mkdir -p "$(dirname "$hook")"
	printf '#!/bin/sh\n# Stub: Change-Ids are added by .gitlab/ci/map-commit.sh\nexit 0\n' > "$hook"
	chmod +x "$hook"

	# -r gerrit: remote set up above   --no-track: ignore track=1 in .gitreview
	# -R: already rebased   -T: no topic   -y: confirm multiple commits
	if ! output="$(git review -r gerrit --no-track -R -T -y "$target" 2>&1)"; then
		echo "$output"
		if grep -q 'no new changes' <<< "$output"; then
			warn "Gerrit already has these exact patch sets (pipeline re-run?)."
		else
			die "git review failed."
		fi
	else
		echo "$output"
	fi

	if [ "${GERRIT_AUTO_SUBMIT:-false}" != "true" ]; then
		log "GERRIT_AUTO_SUBMIT is not 'true': review and submit the changes in Gerrit."
		log "gerrit:sync (schedule or manual) will then bring any Gerrit-side commits to GitLab."
		exit 0
	fi

	attempts="${GERRIT_SUBMIT_ATTEMPTS:-10}"
	interval="${GERRIT_SUBMIT_INTERVAL:-30}"
	for sha in "${commits[@]}"; do
		log "Code-Review +2 and submit ${sha:0:9} $(git log -1 --format=%s "$sha")"
		gerrit_ssh gerrit review --project "$GERRIT_PROJECT" --branch "$target" \
			--code-review +2 --message "'Auto-approved by GitLab CI: ${CI_PIPELINE_URL:-manual run}'" "$sha" \
			|| die "Could not vote +2 on ${sha:0:9}."
		for ((i = 1; ; i++)); do
			if out="$(gerrit_ssh gerrit review --project "$GERRIT_PROJECT" --branch "$target" --submit "$sha" 2>&1)"; then
				break
			fi
			if [ "$i" -ge "$attempts" ]; then
				echo "$out" >&2
				die "Could not submit ${sha:0:9} after ${attempts} attempts. Submit it in Gerrit, then run gerrit:sync."
			fi
			warn "Submit attempt ${i}/${attempts} failed (${out//$'\n'/ }); retrying in ${interval}s."
			sleep "$interval"
		done
	done
	fetch_gerrit
	log "All changes submitted to Gerrit '${target}'."
fi

setup_gitlab_remote
sync_branch "$target" || true
