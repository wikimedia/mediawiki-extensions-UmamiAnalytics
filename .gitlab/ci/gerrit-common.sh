#!/usr/bin/env bash
# Shared helpers for the GitLab <-> Gerrit pipeline (sourced, not executed).
#
# Model: GitLab and Gerrit keep two separate histories with the same content.
# Commits are copied between them with `git rebase` (commits whose patch
# already exists on the other side are skipped automatically) and identities
# are mapped by map-commit.sh:
#   GitLab -> Gerrit : GITLAB_EMAIL -> GERRIT_EMAIL, Change-Id added if missing
#   Gerrit -> GitLab : GERRIT_EMAIL -> GITLAB_EMAIL
# GitLab branches only ever move forward: the pipeline never force-pushes.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${GERRIT_HOST:=gerrit.wikimedia.org}"
: "${GERRIT_PORT:=29418}"
: "${GITLAB_MAIN_BRANCH:=main}"
: "${GERRIT_MAIN_BRANCH:=master}"
: "${SYNC_BRANCH_REGEX:=^(master|REL1_[0-9]+)$}"
: "${GERRIT_USER:?GERRIT_USER is not set}"
: "${GERRIT_PROJECT:?GERRIT_PROJECT is not set}"

# Can be overridden (tests use a local path).
: "${GERRIT_REMOTE_URL:=ssh://${GERRIT_USER}@${GERRIT_HOST}:${GERRIT_PORT}/${GERRIT_PROJECT}}"

log()  { printf '\033[1;34m[gerrit]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[gerrit] WARNING:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[gerrit] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

require_var() {
	local v
	for v in "$@"; do
		[ -n "${!v:-}" ] || die "CI/CD variable $v is not set. Define it in Settings > CI/CD > Variables (protected)."
	done
}

# GitLab branch name -> Gerrit branch name.
gerrit_branch_for() {
	if [ "$1" = "$GITLAB_MAIN_BRANCH" ]; then echo "$GERRIT_MAIN_BRANCH"; else echo "$1"; fi
}

# Gerrit branch name -> GitLab branch name.
gitlab_branch_for() {
	if [ "$1" = "$GERRIT_MAIN_BRANCH" ]; then echo "$GITLAB_MAIN_BRANCH"; else echo "$1"; fi
}

# Writes a CI/CD variable to a file. Works for both "File" variables (value is
# a path) and plain variables (value is the content).
_var_to_file() {
	local value="$1" dest="$2"
	if [ -f "$value" ]; then cp "$value" "$dest"; else printf '%s\n' "$value" > "$dest"; fi
	chmod 600 "$dest"
}

setup_ssh() {
	require_var GERRIT_SSH_PRIVATE_KEY GERRIT_KNOWN_HOSTS
	mkdir -p "$HOME/.ssh"
	chmod 700 "$HOME/.ssh"
	_var_to_file "$GERRIT_SSH_PRIVATE_KEY" "$HOME/.ssh/gerrit_ci"
	_var_to_file "$GERRIT_KNOWN_HOSTS" "$HOME/.ssh/known_hosts"
	ssh-keygen -y -f "$HOME/.ssh/gerrit_ci" > /dev/null 2>&1 \
		|| die "GERRIT_SSH_PRIVATE_KEY is not a valid unencrypted private key (a File variable must end with a newline)."
	# printf instead of a heredoc: robust to tabs being converted to spaces.
	printf '%s\n' \
		"Host ${GERRIT_HOST}" \
		"  Port ${GERRIT_PORT}" \
		"  User ${GERRIT_USER}" \
		"  IdentityFile ~/.ssh/gerrit_ci" \
		"  IdentitiesOnly yes" \
		"  StrictHostKeyChecking yes" \
		"  UserKnownHostsFile ~/.ssh/known_hosts" \
		"  BatchMode yes" > "$HOME/.ssh/config"
	chmod 600 "$HOME/.ssh/config"
}

# Identities. GERRIT_EMAIL must be registered on the Gerrit account (Gerrit
# rejects unknown committer addresses); GITLAB_EMAIL is your GitLab commit
# e-mail (e.g. the anonymised noreply address).
setup_identities() {
	require_var GERRIT_NAME GERRIT_EMAIL GITLAB_EMAIL
	: "${GITLAB_NAME:=$GERRIT_NAME}"
	# Fallback identity for any git command that would need one.
	git config user.name "$GITLAB_NAME"
	git config user.email "$GITLAB_EMAIL"
	git config advice.skippedCherryPicks false
}

setup_gerrit_remote() {
	git remote remove gerrit 2> /dev/null || true
	git remote add gerrit "$GERRIT_REMOTE_URL"
	fetch_gerrit
}

fetch_gerrit() {
	git fetch --quiet --prune gerrit '+refs/heads/*:refs/remotes/gerrit/*'
}

setup_gitlab_remote() {
	if [ -z "${GITLAB_REMOTE_URL:-}" ]; then
		require_var GITLAB_PUSH_TOKEN
		GITLAB_REMOTE_URL="${CI_SERVER_PROTOCOL:-https}://ci-sync:${GITLAB_PUSH_TOKEN}@${CI_SERVER_FQDN:-$CI_SERVER_HOST}/${CI_PROJECT_PATH}.git"
	fi
	git remote remove gitlab 2> /dev/null || true
	git remote add gitlab "$GITLAB_REMOTE_URL"
	git fetch --quiet --prune gitlab '+refs/heads/*:refs/remotes/gitlab/*'
}

gerrit_ssh() {
	ssh -p "$GERRIT_PORT" "${GERRIT_USER}@${GERRIT_HOST}" "$@"
}

# rebase_mapped <to-gerrit|to-gitlab> <onto> <upstream>
# Replays the commits of the current branch that are not in <upstream> (and
# whose patch is not already there) onto <onto>, mapping identities.
# Commits that become empty are dropped; merge commits are flattened.
rebase_mapped() {
	local direction="$1" onto upstream="$3" name email source cid map_log rc=0
	onto="$(git rev-parse "$2^{commit}")"
	if [ "$direction" = to-gerrit ]; then
		name="$GERRIT_NAME"; email="$GERRIT_EMAIL"; source="$GITLAB_EMAIL"; cid=1
	else
		name="$GITLAB_NAME"; email="$GITLAB_EMAIL"; source="$GERRIT_EMAIL"; cid=0
	fi
	map_log="$(mktemp)"
	# git's own progress output is silenced; map-commit.sh reports via MAP_LOG.
	GIT_COMMITTER_NAME="$name" GIT_COMMITTER_EMAIL="$email" \
	MAP_TARGET_NAME="$name" MAP_TARGET_EMAIL="$email" MAP_SOURCE_EMAIL="$source" MAP_ADD_CHANGE_ID="$cid" \
	MAP_ONTO="$onto" MAP_LOG="$map_log" \
	GIT_SEQUENCE_EDITOR=: GIT_EDITOR=: \
		git rebase --quiet --interactive --empty=drop \
		--exec "bash '${SCRIPT_DIR}/map-commit.sh'" --onto "$onto" "$upstream" > /dev/null || rc=$?
	cat "$map_log"
	rm -f "$map_log"
	return "$rc"
}

# sync_point <gerrit-ref> <gitlab-ref>
# Prints "<gerrit-sha> <gitlab-sha>": the newest commit of <gerrit-ref> whose
# content (tree) also exists in the history of <gitlab-ref>, and the newest
# GitLab commit with that content. This is the last state both sides agree on:
# everything after it on one side is new for the other side.
# Fails when the two histories have no content in common.
sync_point() {
	awk 'NR == FNR { if (!($2 in tree)) tree[$2] = $1; next }
	     ($2 in tree) { print $1, tree[$2]; found = 1; exit }
	     END { exit !found }' \
		<(git log --format='%H %T' "$2") <(git log --format='%H %T' "$1")
}

# Copies the Gerrit commits made after the sync point onto the GitLab branch
# (fast-forward only, identities mapped). A missing GitLab release branch is
# created from GitLab `main` at the sync point with the Gerrit branch.
# Returns 0 when done, 2 when the branch needs attention.
sync_branch() {
	local gb="$1" lb gerrit_ref gitlab_ref gitlab_sha onto point gr gl new
	lb="$(gitlab_branch_for "$gb")"
	gerrit_ref="refs/remotes/gerrit/${gb}"
	gitlab_ref="refs/remotes/gitlab/${lb}"
	git rev-parse -q --verify "${gerrit_ref}^{commit}" > /dev/null \
		|| { warn "Gerrit branch '$gb' not found, skipping."; return 0; }
	gitlab_sha="$(git rev-parse -q --verify "${gitlab_ref}^{commit}" || true)"

	if [ -z "$gitlab_sha" ]; then
		if [ "$gb" = "$GERRIT_MAIN_BRANCH" ]; then
			warn "GitLab branch '$lb' does not exist; create it first."
			return 2
		fi
		gitlab_ref="refs/remotes/gitlab/${GITLAB_MAIN_BRANCH}"
	fi
	point="$(sync_point "$gerrit_ref" "$gitlab_ref")" \
		|| { warn "[$gb -> $lb] no content in common between Gerrit and GitLab; nothing done."; return 2; }
	read -r gr gl <<< "$point"
	if [ -z "$gitlab_sha" ]; then
		onto="$gl"
		log "[$gb -> $lb] new GitLab branch, starting from ${GITLAB_MAIN_BRANCH}@${gl:0:9} ($(git log -1 --format=%s "$gl"))."
	else
		onto="$gitlab_sha"
	fi

	git checkout --quiet -B ci-sync "$gerrit_ref"
	if ! rebase_mapped to-gitlab "$onto" "$gr"; then
		git rebase --abort || true
		warn "[$gb -> $lb] Gerrit commits conflict with GitLab commits not merged in Gerrit." \
			"Resolve on GitLab, or run the manual job gerrit:align (see README)."
		return 2
	fi
	new="$(git rev-parse HEAD)"

	if [ "$new" = "$gitlab_sha" ]; then
		log "[$gb -> $lb] no new commits from Gerrit."
	else
		log "[$gb -> $lb] adding $(git rev-list --count "${onto}..${new}") commit(s) from Gerrit:"
		git log --reverse --format='    %h %s' "${onto}..${new}"
		git push --quiet -o ci.skip gitlab "${new}:refs/heads/${lb}"
	fi

	if git diff --quiet "$gerrit_ref" "$new"; then
		log "[$gb -> $lb] content identical."
	else
		log "[$gb -> $lb] GitLab has changes not (yet) merged in Gerrit:"
		git diff --stat "$gerrit_ref" "$new" | sed 's/^/    /'
	fi
	return 0
}
