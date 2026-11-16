#!/usr/bin/env bash
# Move the MOVING tags (`testing`) of an image to a digest that is already pushed and SIGNED: a registry-side copy that keeps the digest, then a read-back
# (registry-settled.sh). The one step that runs AFTER signing, so a run cancelled at any earlier point leaves `testing` on the previous signed image
# (octarine-bins does the same: push by immutable tag, sign, verify, only then move `testing`).
#
#   move-tags.sh <registry-image> <digest> <tag>...        (no tag: nothing to do)
#
# Exit 1 when a copy fails (after the retries) or the read-back still shows another digest. Tools: skopeo.
set -euo pipefail
image="${1:?registry image}"
digest="${2:?digest}"
shift 2
[[ "${digest}" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "::error::move-tags.sh: '${digest}' is not a digest" >&2; exit 1; }
here=$(dirname "${BASH_SOURCE[0]}")
for tag in "$@"; do
    "${here}/retry.sh" skopeo copy --all --preserve-digests "docker://${image}@${digest}" "docker://${image}:${tag}"
    "${here}/registry-settled.sh" "${image}" "${tag}" "${digest}" || exit 1
    echo "moved ${tag} -> ${digest}"
done
