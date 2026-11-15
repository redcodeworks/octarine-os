#!/usr/bin/env bash
# Is a prebuilt binaries image (a component image or the assembled one) already published and signed under this tag?
#
#   binaries-lookup.sh <registry-image> <tag>
#
# Tags are content keys: c-<component>-<key> for a component image, <key> (40 hex) for the assembled image (binaries-key.sh). The tag
# exists and its manifest digest (sha256 of `skopeo inspect --raw`, the way every pin here is made) verifies with cosign against
# cosign.pub (this repository's own key): usable=true, nothing to build. A missing tag, an empty answer or a signature that does not
# verify (an unsigned or half-published image): usable=false, the build runs and pushes again. Always exits 0 for those answers;
# the reason is printed and written as `reason=`. Output (to GITHUB_OUTPUT when set): usable, digest, reason.
# COSIGN_KEY_FILE overrides cosign.pub (tests).
set -uo pipefail
image=${1:?registry image}
tag=${2:?tag}
key=${COSIGN_KEY_FILE:-cosign.pub}
[[ "${tag}" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ && ${#tag} -le 128 ]] || { echo "::error::not a content tag: '${tag}'" >&2; exit 1; }
out() { [[ -z "${GITHUB_OUTPUT:-}" ]] || echo "$1=$2" >> "${GITHUB_OUTPUT}"; echo "$1=$2"; }

manifest=$(skopeo inspect --raw "docker://${image}:${tag}" 2> /dev/null) || manifest=""
if [[ -z "${manifest}" ]]; then
    out usable false; out digest ""; out reason missing
    echo "${image}:${tag} is not published: it will be built"
    exit 0
fi
digest="sha256:$(printf '%s' "${manifest}" | sha256sum | sed 's/ .*//')"
out digest "${digest}"
if cosign verify --key "${key}" "${image}@${digest}" > /dev/null 2>&1; then
    out usable true; out reason signed
    echo "unchanged, nothing to build: ${image}:${tag} = ${digest} (signature valid)"
else
    out usable false; out reason badsignature
    echo "::warning::${image}:${tag} exists (${digest}) but its signature does not verify: it will be built and pushed again"
fi
exit 0
