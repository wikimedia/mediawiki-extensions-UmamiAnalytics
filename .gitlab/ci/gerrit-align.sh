#!/usr/bin/env bash
# gerrit:align - escape hatch, run manually.
#
# Adds ONE commit on top of the GitLab branch ALIGN_BRANCH (default: main)
# whose content is exactly the Gerrit branch. Nothing is force-pushed: the
# GitLab history is kept, but GitLab-only changes are undone in the content.
# That commit becomes the new sync point, so a stuck branch (conflict between
# Gerrit and GitLab) starts again from a clean state. Re-apply the discarded
# changes afterwards, e.g. with `git revert <align commit> -- <files>` or by
# cherry-picking them, and push again.

# shellcheck source=gerrit-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/gerrit-common.sh"

lb="${ALIGN_BRANCH:-$GITLAB_MAIN_BRANCH}"
gb="$(gerrit_branch_for "$lb")"

setup_ssh
setup_identities
setup_gerrit_remote
setup_gitlab_remote

gerrit_ref="refs/remotes/gerrit/${gb}"
gitlab_ref="refs/remotes/gitlab/${lb}"
git rev-parse -q --verify "${gerrit_ref}^{commit}" > /dev/null || die "Gerrit branch '$gb' not found."
git rev-parse -q --verify "${gitlab_ref}^{commit}" > /dev/null || die "GitLab branch '$lb' not found."

if git diff --quiet "$gitlab_ref" "$gerrit_ref"; then
	log "GitLab '$lb' already has the same content as Gerrit '$gb'. Nothing to do."
	exit 0
fi

log "GitLab-only changes that this commit undoes on '$lb':"
git diff --stat "$gerrit_ref" "$gitlab_ref" | sed 's/^/    /'

msg="Align with Gerrit ${gb}@$(git rev-parse --short "$gerrit_ref")

Makes the content of GitLab '${lb}' identical to Gerrit '${gb}'.
Changes undone by this commit (re-apply them if still wanted):

$(git diff --stat "$gerrit_ref" "$gitlab_ref")"

new="$(GIT_AUTHOR_NAME="$GITLAB_NAME" GIT_AUTHOR_EMAIL="$GITLAB_EMAIL" \
	GIT_COMMITTER_NAME="$GITLAB_NAME" GIT_COMMITTER_EMAIL="$GITLAB_EMAIL" \
	git commit-tree "${gerrit_ref}^{tree}" -p "$gitlab_ref" -m "$msg")"
git push --quiet -o ci.skip gitlab "${new}:refs/heads/${lb}"
log "Pushed $(git rev-parse --short "$new") on GitLab '$lb'. Update your clone with 'git pull'."
