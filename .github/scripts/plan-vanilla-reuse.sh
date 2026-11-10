#!/usr/bin/env bash
# Decide whether a push to `testing` can skip the default image build because an image built from identical
# inputs is already published (same vanilla_inputs, see inputs-hash.sh: a dx-only or docs-only change), and print
# key=value lines (for $GITHUB_OUTPUT):
#
#   plan-vanilla-reuse.sh <event> <ref> <after>
#
#   reuse=true|false
#   source_tag=testing-<short sha>   (only when reuse=true)
#   source_digest=<digest>           (only when reuse=true)
#   inputs=<vanilla_inputs of <after>>
#
# Environment: REGISTRY_LOOKUP (command; `$REGISTRY_LOOKUP <tag>` prints the digest of that tag or fails).
# Nothing is published or retagged: the image of the nearest earlier commit stays the `testing` image.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/inputs-hash.sh"

event="${1:?event}"
ref="${2:?ref}"
after="${3:-HEAD}"

no() { echo "no reuse: $*" >&2; echo "reuse=false"; exit 0; }

[[ "${event}" == push && "${ref}" == refs/heads/testing ]] || no "not a push to testing (${event} ${ref})"
inputs=$(vanilla_inputs "${after}")
echo "inputs=${inputs}"
err=$(mktemp)
trap 'rm -f "${err}"' EXIT
found=$(nearest_image_for_inputs "${after}" 2> "${err}") || no "$(cat "${err}")"
read -r tag digest <<< "${found}"
echo "reuse: ${tag} (${digest}) was built from the same default-image inputs as ${after}" >&2
printf 'reuse=true\nsource_tag=%s\nsource_digest=%s\n' "${tag}" "${digest}"
