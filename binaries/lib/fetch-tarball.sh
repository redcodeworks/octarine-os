#!/usr/bin/env bash
# Download a source or toolchain tarball, verify it, and only then unpack it. FAILS unless BOTH checks pass:
#
#   fetch-tarball.sh <url> <sha256> <minisign public key> <dest dir>
#
#   1. `<url>.minisig` verifies the tarball against the pinned minisign public key (the publisher's signature),
#   2. the sha256 of the tarball equals the pinned one (the pin in the repository: a re-signed or replaced file with a good
#      signature is still caught, and a bump is a reviewed change of the pin).
# The tarball is unpacked with its top-level directory removed (--strip-components=1) into <dest dir>, which must not exist or be
# empty. Nothing is unpacked from a file that failed a check. Needs curl, minisign, sha256sum, tar (xz and gzip are detected by tar).
# Test hook: the downloader is `curl` from PATH, and file:// URLs work (the tests use local files and a stub minisign).
set -euo pipefail
url="${1:?url}"
want_sha="${2:?sha256}"
key="${3:?minisign public key}"
dest="${4:?destination directory}"

[[ "${want_sha}" =~ ^[0-9a-f]{64}$ ]] || { echo "::error::no valid sha256 is pinned for ${url} (upstream.env): refusing to build" >&2; exit 1; }
[[ "${key}" =~ ^RW[A-Za-z0-9+/]{54}$ ]] || { echo "::error::no valid minisign public key is pinned for ${url} (upstream.env): refusing to build" >&2; exit 1; }
if [[ -e "${dest}" ]] && [[ -n "$(ls -A "${dest}")" ]]; then echo "fetch-tarball.sh: ${dest} is not empty" >&2; exit 1; fi

work=$(mktemp -d)
trap 'rm -rf "${work}"' EXIT
file="${work}/archive"
curl --fail --silent --show-error --location --retry 3 --retry-delay 5 --output "${file}" "${url}"
curl --fail --silent --show-error --location --retry 3 --retry-delay 5 --output "${file}.minisig" "${url}.minisig"

minisign -V -m "${file}" -x "${file}.minisig" -P "${key}" > /dev/null \
    || { echo "::error::the minisign signature of ${url} does not verify against the pinned key" >&2; exit 1; }
got=$(sha256sum "${file}" | cut -d' ' -f1)
if [[ "${got}" != "${want_sha}" ]]; then
    echo "::error::${url} has sha256 ${got}, upstream.env pins ${want_sha} (a replaced file? check before changing the pin)" >&2
    exit 1
fi
mkdir -p "${dest}"
tar -xf "${file}" -C "${dest}" --strip-components=1
echo "verified (minisign + sha256 ${got}): ${url} -> ${dest}"
