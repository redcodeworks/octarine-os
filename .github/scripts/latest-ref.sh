#!/usr/bin/env bash
# The image build's way to use an image this project owns (octarine-binaries, dev-packages): take its promoted `latest`, resolve it to a digest ONCE, verify the
# signature of that digest, and name it. Owned images float at latest (nothing here is pinned in a file); the digest is recorded in an image label, so the exact
# content of a build can be found again.
#
#   latest-ref.sh <registry-image> <cosign public key file> <ENV_NAME>
#
# Logs the reference and, with GITHUB_ENV set, exports <ENV_NAME>=<image>@<digest> for the later steps (`just build` and the dx workflows pass it on as a build
# argument). Fails when `latest` cannot be read or does not verify with the key: there is no fallback to an older image, the build stops and the owner fixes it.
set -euo pipefail
image=${1:?registry image}
key=${2:?cosign public key file}
name=${3:?environment variable name}
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
digest=$(IMAGE="${image}" "${here}/registry-digest.sh" latest) || { echo "::error::cannot read ${image}:latest (a missing tag or a registry error: see the message above)" >&2; exit 1; }
[[ "${digest}" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "::error::bad digest '${digest}' for ${image}:latest" >&2; exit 1; }
ref="${image}@${digest}"
"${here}/cosign-check.sh" --key "${key}" "${ref}" || { echo "::error::the signature of ${ref} (${image}:latest) does not verify with ${key}" >&2; exit 1; }
echo "${name}: ${ref} (latest, signature valid)"
[[ -z "${GITHUB_ENV:-}" ]] || echo "${name}=${ref}" >> "${GITHUB_ENV}"
[[ -z "${GITHUB_STEP_SUMMARY:-}" ]] || echo "${name} \`${ref}\`" >> "${GITHUB_STEP_SUMMARY}"
