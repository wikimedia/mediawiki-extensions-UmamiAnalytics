#!/usr/bin/env bash
# gerrit:sync - copy Gerrit-only commits of every branch matching
# SYNC_BRANCH_REGEX to GitLab (fast-forward only, identities mapped).
# Exit code 3 means at least one branch needs attention.

# shellcheck source=gerrit-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/gerrit-common.sh"

setup_ssh
setup_identities
setup_gerrit_remote
setup_gitlab_remote

status=0
while read -r gb; do
	[[ "$gb" =~ $SYNC_BRANCH_REGEX ]] || continue
	rc=0
	sync_branch "$gb" || rc=$?
	if [ "$rc" -eq 2 ]; then status=3; elif [ "$rc" -ne 0 ]; then exit "$rc"; fi
done < <(git for-each-ref --format='%(refname:strip=3)' refs/remotes/gerrit/)

exit "$status"
