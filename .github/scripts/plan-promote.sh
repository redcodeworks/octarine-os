#!/usr/bin/env bash
# Decide whether a push to main can promote an already tested `testing` image to `latest` (retag the same
# digest, no rebuild) and print key=value lines (for $GITHUB_OUTPUT):
#
#   plan-promote.sh <event> <ref> <after>
#
#   promote=true|false
#   source_tag=testing-<short sha>   (only when promote=true)
#   source_digest=<digest>           (only when promote=true)
#
# Environment: PROMOTE_ENABLED (must be `true`), REGISTRY_LOOKUP (command; `$REGISTRY_LOOKUP <tag>` prints
# the digest of that tag of the image or exits non-zero when it does not exist).
#
# Promote only when all hold:
#   * event is push, ref is refs/heads/main, and <after> is a merge commit (two parents);
#   * every file that differs between the testing side (<after>^2) and <after> is docs-only (so the trees
#     are equal apart from docs);
#   * walking first-parent history back from <after>^2, the nearest commit C that has a published
#     `testing-<short sha>` image is reached without crossing a non-docs change (every file changed
#     between C and <after>^2 is docs-only).
# Anything else (schedule, dispatch, non-merge push, differing trees, no image, disabled) means build.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/docs-only.sh"

event="${1:?event}"
ref="${2:?ref}"
after="${3:-HEAD}"
MAX_WALK=${MAX_WALK:-50}

no() { echo "no promote: $*" >&2; echo "promote=false"; exit 0; }

docs_only_between() { # a b: true when every file changed between the two commits is docs-only
    local f
    while IFS= read -r f; do
        [[ -z "${f}" ]] || is_docs "${f}" || return 1
    done < <(git diff --name-only "$1" "$2")
}

[[ "${PROMOTE_ENABLED-}" == true ]] || no "PROMOTE_ENABLED is not 'true'"
[[ "${event}" == push && "${ref}" == refs/heads/main ]] || no "not a push to main (${event} ${ref})"
git cat-file -e "${after}^2^{commit}" 2>/dev/null || no "${after} is not a merge commit"
git cat-file -e "${after}^3^{commit}" 2>/dev/null && no "octopus merge"

tip=$(git rev-parse "${after}^2")
docs_only_between "${tip}" "${after}" || no "main differs from the testing tip outside docs"

n=0
for c in $(git rev-list --first-parent "${tip}"); do
    ((n++ > MAX_WALK)) && no "no testing image within ${MAX_WALK} commits"
    docs_only_between "${c}" "${tip}" || no "a non-docs change lies between the testing tip and the nearest commit"
    for sha in "$(git rev-parse --short "${c}")" "$(git rev-parse --short=7 "${c}")"; do
        if digest=$("${REGISTRY_LOOKUP:?REGISTRY_LOOKUP}" "testing-${sha}" 2>/dev/null) && [[ -n "${digest}" ]]; then
            echo "promote: testing-${sha} (${digest}) covers ${tip}" >&2
            printf 'promote=true\nsource_tag=testing-%s\nsource_digest=%s\n' "${sha}" "${digest}"
            exit 0
        fi
    done
done
no "no testing image found"
