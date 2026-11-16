#!/usr/bin/env bash
# Is a prebuilt binaries image (a component image or the assembled one) already published and signed under this tag?
#
#   binaries-lookup.sh <registry-image> <tag>
#
# Tags are content keys: c-<component>-<key> for a component image, <key> (40 hex) for the assembled image (binaries-key.sh). The tag
# exists and its manifest digest (sha256 of `skopeo inspect --raw`, the way every pin here is made) verifies with cosign against
# cosign.pub (this repository's own key): usable=true, nothing to build. A missing tag, an empty answer or a signature that does not
# verify (an unsigned or half-published image): usable=false, the build runs and pushes again. A registry that cannot be READ (after retries) is told apart:
# usable=false, reason=unreadable (also for a cosign check that cannot complete), never `missing` or `badsignature`. Always exits 0 for those answers;
# the reason is printed and written as `reason=`. Output (to GITHUB_OUTPUT when set): usable, digest, reason.
# COSIGN_KEY_FILE overrides cosign.pub (tests).
set -uo pipefail
image=${1:?registry image}
tag=${2:?tag}
key=${COSIGN_KEY_FILE:-cosign.pub}
[[ "${tag}" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ && ${#tag} -le 128 ]] || { echo "::error::not a content tag: '${tag}'" >&2; exit 1; }
out() { [[ -z "${GITHUB_OUTPUT:-}" ]] || echo "$1=$2" >> "${GITHUB_OUTPUT}"; echo "$1=$2"; }

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
rc=0
manifest=$("${here}/registry-read.sh" raw "${image}:${tag}") || rc=$?
if [[ "${rc}" == 4 ]]; then
    # a READ ERROR (retried) is not "not published": say so; the leg still builds (a rebuild is safe: the image is content-addressed), but the log and the reason tell the truth
    out usable false; out digest ""; out reason unreadable
    echo "::warning::${image}:${tag} could not be read (a registry read error after the retries, not a missing tag): it will be built"
    exit 0
fi
if [[ "${rc}" != 0 || -z "${manifest}" ]]; then
    out usable false; out digest ""; out reason missing
    echo "${image}:${tag} is not published: it will be built"
    exit 0
fi
digest="sha256:$(printf '%s' "${manifest}" | sha256sum | sed 's/ .*//')"
out digest "${digest}"
vrc=0
"${here}/cosign-check.sh" --key "${key}" "${image}@${digest}" 2> /dev/null || vrc=$?
if [[ "${vrc}" == 0 ]]; then
    out usable true; out reason signed
    echo "unchanged, nothing to build: ${image}:${tag} = ${digest} (signature valid)"
elif [[ "${vrc}" == 4 ]]; then
    out usable false; out reason unreadable
    echo "::warning::the signature of ${image}:${tag} (${digest}) could not be checked (a read error after the retries, not a bad signature): it will be built and pushed again"
else
    out usable false; out reason badsignature
    echo "::warning::${image}:${tag} exists (${digest}) but its signature does not verify: it will be built and pushed again"
fi
exit 0
