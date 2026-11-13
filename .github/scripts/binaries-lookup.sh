#!/usr/bin/env bash
# Is the prebuilt binaries image for this tree already published and signed?
#
#   binaries-lookup.sh <registry-image> <tree-hash>
#
# The image is tagged with the git tree hash of binaries/ (`git rev-parse HEAD:binaries`). The tag exists and its manifest
# digest (sha256 of `skopeo inspect --raw`, the way every pin here is made) verifies with cosign against cosign.pub (this
# repository's own key): usable=true, nothing to build. A missing tag, an empty answer or a signature that does not verify
# (an unsigned or half-published image): usable=false, the build runs and pushes again. Always exits 0 for those answers;
# the reason is printed and written as `reason=`. Output (to GITHUB_OUTPUT when set): usable, digest, reason.
# COSIGN_KEY_FILE overrides cosign.pub (tests).
set -uo pipefail
image=${1:?registry image}
hash=${2:?tree hash}
key=${COSIGN_KEY_FILE:-cosign.pub}
[[ "${hash}" =~ ^[0-9a-f]{40}$ ]] || { echo "::error::not a tree hash: '${hash}'" >&2; exit 1; }
out() { [[ -z "${GITHUB_OUTPUT:-}" ]] || echo "$1=$2" >> "${GITHUB_OUTPUT}"; echo "$1=$2"; }

manifest=$(skopeo inspect --raw "docker://${image}:${hash}" 2> /dev/null) || manifest=""
if [[ -z "${manifest}" ]]; then
    out usable false; out digest ""; out reason missing
    echo "${image}:${hash} is not published: the binaries will be built"
    exit 0
fi
digest="sha256:$(printf '%s' "${manifest}" | sha256sum | sed 's/ .*//')"
out digest "${digest}"
if cosign verify --key "${key}" "${image}@${digest}" > /dev/null 2>&1; then
    out usable true; out reason signed
    echo "binaries unchanged, nothing to build: ${image}:${hash} = ${digest} (signature valid)"
else
    out usable false; out reason badsignature
    echo "::warning::${image}:${hash} exists (${digest}) but its signature does not verify: the binaries will be built and pushed again"
fi
exit 0
