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
#   * the default-image inputs (vanilla_inputs, inputs-hash.sh: every file except docs and the dx-only files) of the
#     testing side (<after>^2) and of <after> are equal;
#   * walking first-parent history back from <after>^2, the nearest commit C that has a published
#     `testing-<short sha>` image is reached without crossing a commit whose vanilla_inputs differ (so a docs-only
#     or dx-only testing tip, which has no image of its own, promotes the image of the commit behind it).
# Anything else (schedule, dispatch, non-merge push, differing inputs, no image, disabled) means build.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/inputs-hash.sh"

event="${1:?event}"
ref="${2:?ref}"
after="${3:-HEAD}"

no() { echo "no promote: $*" >&2; echo "promote=false"; exit 0; }

[[ "${PROMOTE_ENABLED-}" == true ]] || no "PROMOTE_ENABLED is not 'true'"
[[ "${event}" == push && "${ref}" == refs/heads/main ]] || no "not a push to main (${event} ${ref})"
git cat-file -e "${after}^2^{commit}" 2>/dev/null || no "${after} is not a merge commit"
git cat-file -e "${after}^3^{commit}" 2>/dev/null && no "octopus merge"

tip=$(git rev-parse "${after}^2")
[[ "$(vanilla_inputs "${tip}")" == "$(vanilla_inputs "${after}")" ]] || no "main differs from the testing tip in the default-image inputs"

err=$(mktemp)
trap 'rm -f "${err}"' EXIT
found=$(nearest_image_for_inputs "${tip}" 2> "${err}") || no "$(cat "${err}")"
read -r tag digest <<< "${found}"
echo "promote: ${tag} (${digest}) covers ${tip}" >&2
printf 'promote=true\nsource_tag=%s\nsource_digest=%s\n' "${tag}" "${digest}"
