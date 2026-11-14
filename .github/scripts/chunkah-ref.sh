#!/usr/bin/env bash
# Print the verified reference of the chunkah image for `just rechunk`: <image>@<digest> from config/chunkah.env, after cosign accepted its
# keyless signature (the GitHub Actions OIDC issuer, an identity under https://github.com/coreos/chunkah/). Fails (exit 1) when the pin is
# malformed or the verification fails: a rechunk never runs an unverified image. The tag in config/chunkah.env is only a label.
#   chunkah-ref.sh [config/chunkah.env]        (CHUNKAH_ENV overrides the path, for tests)
set -euo pipefail
file=${1:-${CHUNKAH_ENV:-config/chunkah.env}}
[[ -f "${file}" ]] || { echo "::error::${file} not found" >&2; exit 1; }
declare -A v=()
while IFS= read -r line || [[ -n "${line}" ]]; do
    line=${line%%#*}; line=${line#"${line%%[![:space:]]*}"}; line=${line%"${line##*[![:space:]]}"}
    [[ -n "${line}" ]] || continue
    [[ "${line}" =~ ^([A-Z_]+)=(.*)$ ]] || { echo "::error::${file}: not KEY=VALUE: '${line}'" >&2; exit 1; }
    v[${BASH_REMATCH[1]}]=${BASH_REMATCH[2]}
done < "${file}"
image=${v[CHUNKAH_IMAGE]:-}; digest=${v[CHUNKAH_DIGEST]:-}
[[ "${image}" =~ ^[a-z0-9.-]+(:[0-9]+)?(/[a-z0-9._-]+)+$ ]] || { echo "::error::bad CHUNKAH_IMAGE '${image}'" >&2; exit 1; }
[[ "${digest}" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "::error::bad CHUNKAH_DIGEST '${digest}'" >&2; exit 1; }
ref="${image}@${digest}"
cosign verify \
    --certificate-oidc-issuer https://token.actions.githubusercontent.com \
    --certificate-identity-regexp '^https://github.com/coreos/chunkah/' \
    "${ref}" > /dev/null \
    || { echo "::error::cosign verification of ${ref} failed: the chunkah image is not trusted, nothing is rechunked (a changed signing identity upstream, or a bad pin: check config/chunkah.env)" >&2; exit 1; }
echo "${ref}"
