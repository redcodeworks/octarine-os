#!/usr/bin/env bash
# Resolve the FLOATING base image (${BASE_IMAGE}:${FEDORA_VERSION}, Universal Blue's silverblue-main) to a digest ONCE at the start of a run, verify its
# cosign signature with the pinned Universal Blue key and print the pin; the build then runs FROM that digest, so one run uses one base, and a base
# that is not signed by that key never gets built on (fail closed).
#
#   base-pin.sh        env: BASE_IMAGE, FEDORA_VERSION, KEY (default keys/ublue-os-main-cosign.pub), GITHUB_ENV / GITHUB_STEP_SUMMARY / GITHUB_OUTPUT when set
#
# Prints and exports BASE_PIN=sha256:<manifest digest of the tag> (the sha256 of `skopeo inspect --raw`, the way every pin here is made).
# Verification: the signature of BASE_IMAGE@<pin>; for a manifest LIST whose own digest carries no signature, the linux/amd64 child it names (an
# index digest pins its children, so a verified child is the one this build uses). Neither verifies: exit 1 with an error that names a rotated key as
# one possible cause (compare keys/ublue-os-main-cosign.pub with https://github.com/ublue-os/main/blob/main/cosign.pub). Exit 1 too when the tag
# cannot be resolved.
set -euo pipefail
image=${BASE_IMAGE:?BASE_IMAGE}
ver=${FEDORA_VERSION:?FEDORA_VERSION}
key=${KEY:-keys/ublue-os-main-cosign.pub}
[[ "${ver}" =~ ^[0-9]+$ ]] || { echo "::error::FEDORA_VERSION '${ver}' is not a number" >&2; exit 1; }
base="${image}:${ver}"
manifest=$(skopeo inspect --raw "docker://${base}" 2> /dev/null) || manifest=""
[[ -n "${manifest}" ]] || { echo "::error::cannot resolve ${base} (does the tag exist? skopeo list-tags docker://${image})" >&2; exit 1; }
pin="sha256:$(printf '%s' "${manifest}" | sha256sum | sed 's/ .*//')"
verified=""
if cosign verify --key "${key}" "${image}@${pin}" > /dev/null 2>&1; then
    verified="the signature of ${pin}"
else
    child=$(jq -r '[.manifests[]? | select(.platform.os == "linux" and .platform.architecture == "amd64") | .digest][0] // empty' <<<"${manifest}" 2> /dev/null || true)
    if [[ "${child}" =~ ^sha256:[0-9a-f]{64}$ ]] && cosign verify --key "${key}" "${image}@${child}" > /dev/null 2>&1; then
        verified="the signature of its linux/amd64 manifest ${child}"
    fi
fi
if [[ -z "${verified}" ]]; then
    echo "::error::${base} (${pin}) is not signed by ${key}: the build stops. Possible causes: Universal Blue rotated its signing key (compare ${key} with https://github.com/ublue-os/main/blob/main/cosign.pub and replace it only after reading why), the image is unsigned, or it was replaced." >&2
    exit 1
fi
echo "BASE_PIN=${pin}"
[[ -z "${GITHUB_ENV:-}" ]] || echo "BASE_PIN=${pin}" >> "${GITHUB_ENV}"
[[ -z "${GITHUB_OUTPUT:-}" ]] || echo "pin=${pin}" >> "${GITHUB_OUTPUT}"
[[ -z "${GITHUB_STEP_SUMMARY:-}" ]] || echo "Base image: \`${base}\` resolved ONCE to \`${pin}\` and verified (${verified}) with \`${key}\`; the build is FROM that digest." >> "${GITHUB_STEP_SUMMARY}"
