#!/usr/bin/env bash
# Run by `git rebase --exec` on every commit copied from one repository to the
# other. GitLab and Gerrit keep separate histories with identical content; only
# identities (and the Change-Id trailer) differ.
#
# Environment (set by rebase_mapped in gerrit-common.sh):
#   MAP_TARGET_NAME / MAP_TARGET_EMAIL  identity to use on the target side
#   MAP_SOURCE_EMAIL                    your e-mail on the source side
#   MAP_ADD_CHANGE_ID                   "1" when copying to Gerrit
#   MAP_ONTO                            SHA the commits are replayed onto
#   MAP_LOG                             file collecting what was changed
#
# Amends HEAD when:
#   - MAP_ADD_CHANGE_ID=1 and there is no Change-Id. The Change-Id is derived
#     from the original author, author date and subject, so re-running a
#     pipeline updates the same Gerrit change instead of creating a duplicate.
#   - the author e-mail is MAP_SOURCE_EMAIL: author becomes the target identity
#     (author date preserved). Other authors are never changed.
#   - the committer e-mail is not MAP_TARGET_EMAIL.
#
# Nothing here prints e-mail addresses: job logs may be public.

set -euo pipefail
shopt -s nocasematch

: "${MAP_TARGET_NAME:?}" "${MAP_TARGET_EMAIL:?}" "${MAP_SOURCE_EMAIL:?}" "${MAP_ONTO:?}" "${MAP_LOG:?}"

# When the rebase drops a commit (patch already on the target side), the exec
# that follows runs on the previous commit, which may belong to the target
# branch itself. Those commits must never be touched.
if git merge-base --is-ancestor HEAD "$MAP_ONTO"; then
	exit 0
fi

msg_file="$(mktemp)"
trap 'rm -f "$msg_file"' EXIT
git log -1 --format=%B HEAD > "$msg_file"
subject="$(git log -1 --format='%h %s' HEAD)"

needs_amend=0
author_args=()

if [ "${MAP_ADD_CHANGE_ID:-0}" = "1" ] \
	&& ! git interpret-trailers --parse < "$msg_file" | grep -Eq '^Change-Id: I[0-9a-f]{40}$'; then
	seed="$(git log -1 --format='%an%n%ae%n%at%n%s' HEAD)"
	change_id="I$(printf '%s' "$seed" | git hash-object --stdin)"
	git interpret-trailers --in-place --trailer "Change-Id: ${change_id}" "$msg_file"
	echo "  + Change-Id ${change_id} added: ${subject}" >> "$MAP_LOG"
	needs_amend=1
fi

if [[ "$(git log -1 --format=%ae HEAD)" == "$MAP_SOURCE_EMAIL" ]]; then
	author_args=(--author="${MAP_TARGET_NAME} <${MAP_TARGET_EMAIL}>" --date="$(git log -1 --format=%aD HEAD)")
	echo "  + author identity mapped: ${subject}" >> "$MAP_LOG"
	needs_amend=1
fi

if [[ "$(git log -1 --format=%ce HEAD)" != "$MAP_TARGET_EMAIL" ]]; then
	needs_amend=1
fi

if [ "$needs_amend" -eq 1 ]; then
	GIT_COMMITTER_NAME="$MAP_TARGET_NAME" GIT_COMMITTER_EMAIL="$MAP_TARGET_EMAIL" \
		git commit --quiet --amend --no-verify --allow-empty --cleanup=whitespace "${author_args[@]}" -F "$msg_file"
fi
