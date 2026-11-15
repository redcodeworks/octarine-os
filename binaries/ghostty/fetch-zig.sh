#!/usr/bin/env bash
# Download, verify and unpack the pinned Zig toolchain of the Ghostty build.
#
#   fetch-zig.sh <zig.env> <dest dir>
#
# zig.env is parsed strictly (KEY=VALUE, known keys only, formats checked, the URLs must be the official ziglang.org ones for this
# version; ZIG_SIZE is optional). Checks, each of which FAILS the script: the tarball size (when pinned) and sha256 equal the pin; the sha256 equals the value
# https://ziglang.org/download/index.json lists for exactly this version, URL and size (so a pin that was hand-edited or that upstream
# changed cannot go unnoticed); the minisign signature of the tarball verifies with ZIG_MINISIGN_KEY when `minisign` is installed (when it is not,
# the record says so plainly: sha256 and index.json only); `<dest>/zig version` prints ZIG_VERSION. Writes <dest>/FETCH-RECORD (one line per fact,
# for BUILDINFO). Overrides for the tests: CURL (the download command, default curl), ZIG_INDEX_URL (default the official index), MINISIGN.
set -euo pipefail
envfile="${1:?zig.env}"
dest="${2:?destination directory}"
curl_cmd=${CURL:-curl}
index_url=${ZIG_INDEX_URL:-https://ziglang.org/download/index.json}
minisign_cmd=${MINISIGN:-minisign}
die() { echo "::error::fetch-zig.sh: $*" >&2; exit 1; }

declare -A v=()
n=0
while IFS= read -r line || [[ -n "${line}" ]]; do
    n=$((n + 1))
    [[ -z "${line//[[:space:]]/}" || "${line}" =~ ^[[:space:]]*# ]] && continue
    [[ "${line}" =~ ^(ZIG_[A-Z0-9_]+)=([^[:space:]]*)$ ]] || die "${envfile}:${n}: not KEY=VALUE: ${line}"
    key=${BASH_REMATCH[1]}
    case "${key}" in ZIG_VERSION | ZIG_URL | ZIG_SHA256 | ZIG_SIZE | ZIG_SIGNATURE_URL | ZIG_MINISIGN_KEY) ;; *) die "${envfile}:${n}: unknown key ${key}" ;; esac
    [[ -z "${v[${key}]:-}" ]] || die "${envfile}:${n}: duplicate key ${key}"
    v[${key}]=${BASH_REMATCH[2]}
done < "${envfile}"
for k in ZIG_VERSION ZIG_URL ZIG_SHA256 ZIG_SIGNATURE_URL ZIG_MINISIGN_KEY; do [[ -n "${v[${k}]:-}" ]] || die "${envfile}: ${k} is missing"; done
ver=${v[ZIG_VERSION]}
[[ "${ver}" =~ ^0\.[0-9]+\.[0-9]+$ ]] || die "ZIG_VERSION '${ver}' is not a released version (0.X.Y)"
official="https://ziglang.org/download/${ver}/zig-x86_64-linux-${ver}.tar.xz"
[[ "${v[ZIG_URL]}" == "${official}" ]] || die "ZIG_URL must be ${official}"
[[ "${v[ZIG_SIGNATURE_URL]}" == "${official}.minisig" ]] || die "ZIG_SIGNATURE_URL must be ${official}.minisig"
[[ "${v[ZIG_SHA256]}" =~ ^[0-9a-f]{64}$ ]] || die "ZIG_SHA256 is not 64 lowercase hex characters"
[[ -z "${v[ZIG_SIZE]:-}" || "${v[ZIG_SIZE]}" =~ ^[0-9]+$ ]] || die "ZIG_SIZE is not a number"
[[ "${v[ZIG_MINISIGN_KEY]}" =~ ^RW[A-Za-z0-9+/]{52,54}$ ]] || die "ZIG_MINISIGN_KEY is not a minisign public key"

work=$(mktemp -d)
trap 'rm -rf "${work}"' EXIT
"${curl_cmd}" -fsSL --retry 3 -o "${work}/zig.tar.xz" "${v[ZIG_URL]}" || die "cannot download ${v[ZIG_URL]}"
size=$(stat -c %s "${work}/zig.tar.xz")
[[ -z "${v[ZIG_SIZE]:-}" || "${size}" == "${v[ZIG_SIZE]}" ]] || die "the tarball is ${size} bytes, the pin says ${v[ZIG_SIZE]}"
got=$(sha256sum "${work}/zig.tar.xz" | cut -d' ' -f1)
[[ "${got}" == "${v[ZIG_SHA256]}" ]] || die "the tarball sha256 is ${got}, the pin says ${v[ZIG_SHA256]}"

"${curl_cmd}" -fsSL --retry 3 -o "${work}/index.json" "${index_url}" || die "cannot download ${index_url}"
# the size is the one index.json lists for this version (also when zig.env pins none): the pinned sha256 and the index must agree on the real file
jq -e --arg ver "${ver}" --arg url "${v[ZIG_URL]}" --arg sha "${v[ZIG_SHA256]}" --arg size "${size}" \
    '.[$ver]["x86_64-linux"] | .tarball == $url and .shasum == $sha and (.size | tostring) == $size' "${work}/index.json" > /dev/null \
    || die "index.json does not list ${ver} x86_64-linux with this URL, sha256 and size: the pin and upstream disagree (check before changing the pin)"

if command -v "${minisign_cmd}" > /dev/null 2>&1; then
    "${curl_cmd}" -fsSL --retry 3 -o "${work}/zig.tar.xz.minisig" "${v[ZIG_SIGNATURE_URL]}" || die "cannot download ${v[ZIG_SIGNATURE_URL]}"
    "${minisign_cmd}" -V -m "${work}/zig.tar.xz" -x "${work}/zig.tar.xz.minisig" -P "${v[ZIG_MINISIGN_KEY]}" > /dev/null || die "the minisign signature of the tarball does not verify"
    signature="minisign signature verified"
else
    signature="minisign NOT installed: only the sha256 pin and index.json were checked"
fi

mkdir -p "${dest}"
tar -xJf "${work}/zig.tar.xz" -C "${dest}" --strip-components=1
[[ -x "${dest}/zig" ]] || die "the tarball holds no zig executable"
reported=$("${dest}/zig" version)
[[ "${reported}" == "${ver}" ]] || die "zig reports ${reported}, expected ${ver}"
printf 'zig %s from %s, sha256 %s, %s, sha256 equals ziglang.org/download/index.json\n' "${ver}" "${v[ZIG_URL]}" "${v[ZIG_SHA256]}" "${signature}" > "${dest}/FETCH-RECORD"
cat "${dest}/FETCH-RECORD"
