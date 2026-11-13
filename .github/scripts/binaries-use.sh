#!/usr/bin/env bash
# The image build's gate for the prebuilt binaries: verify the digest the binaries workflow handed over and name it.
#
#   binaries-use.sh <registry-image> <digest>
#
# Fails when the digest is empty (the binaries of this tree were built by a validation run and not published: merge the change
# through testing), malformed, or not signed by cosign.pub. Otherwise logs the reference (the record of what the build used) and,
# with GITHUB_ENV set, exports BINARIES_IMAGE=<image>@<digest>, which `just build` passes to the Containerfile.
set -euo pipefail
image=${1:?registry image}
digest=${2-}
key=${COSIGN_KEY_FILE:-cosign.pub}
if [[ -z "${digest}" ]]; then
    echo "::error::No published binaries image for this tree (binaries/ changed and this ref cannot publish): push the change to testing first" >&2
    exit 1
fi
[[ "${digest}" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "::error::bad binaries digest '${digest}'" >&2; exit 1; }
ref="${image}@${digest}"
cosign verify --key "${key}" "${ref}" > /dev/null || { echo "::error::cosign verification failed for ${ref}" >&2; exit 1; }
echo "Binaries image used: ${ref} (signature valid)"
[[ -z "${GITHUB_ENV:-}" ]] || echo "BINARIES_IMAGE=${ref}" >> "${GITHUB_ENV}"
