#!/usr/bin/env bash
# The Ghostty part of a weekly bump, run by .github/scripts/bump-upstream.sh after it changed UPSTREAM_TAG and UPSTREAM_COMMIT:
#
#   bump-extra.sh <upstream.env, already carrying the new tag> <new tag>
#
# 1. downloads the new release tarball and its signature and verifies the signature against the pinned minisign key; only then
#    UPSTREAM_TARBALL_SHA256 is rewritten to the sha256 of that file (so the pin is never taken from an unsigned file),
# 2. checks that the VERSION file inside is the tag,
# 3. reads minimum_zig_version from the tarball's build.zig.zon. When the pinned ZIG_VERSION no longer satisfies it (same major and
#    minor, patch at least) the script exits 3 AFTER writing the sha256: bump-upstream.sh still opens the pull request but flags it in
#    the body (the build of that PR would fail until ZIG_VERSION, ZIG_URL, ZIG_SHA256 and ZIG_MINISIGN_KEY are changed in the same PR,
#    with the facts looked up first). Policy (Kevin, 2026-11-14): follow every stable release, no soak; a signature failure is fatal.
# Needs curl, minisign, sha256sum, tar (the weekly workflow installs minisign).
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../lib/upstream-env.sh
source "${here}/../lib/upstream-env.sh"
# shellcheck source=zig-version.sh
source "${here}/zig-version.sh"
file="${1:?upstream.env}"
tag="${2:?new tag}"
upstream_env_load "${file}"
[[ "${UPSTREAM_TAG}" == "${tag}" ]] || { echo "bump-extra.sh: ${file} does not carry ${tag}" >&2; exit 1; }
version=${tag#v}
url=${UPSTREAM_TARBALL_URL//@VERSION@/${version}}

work=$(mktemp -d)
trap 'rm -rf "${work}"' EXIT
curl --fail --silent --show-error --location --retry 3 --retry-delay 5 --output "${work}/t.tar.gz" "${url}"
curl --fail --silent --show-error --location --retry 3 --retry-delay 5 --output "${work}/t.tar.gz.minisig" "${url}.minisig"
minisign -V -m "${work}/t.tar.gz" -x "${work}/t.tar.gz.minisig" -P "${UPSTREAM_MINISIGN_KEY}" > /dev/null \
    || { echo "::error::the signature of ${url} does not verify against the pinned minisign key: no bump" >&2; exit 1; }
sha=$(sha256sum "${work}/t.tar.gz" | cut -d' ' -f1)
tar -xzOf "${work}/t.tar.gz" "ghostty-${version}/VERSION" > "${work}/VERSION"
[[ "$(cat "${work}/VERSION")" == "${version}" ]] || { echo "::error::the VERSION file inside ${url} is not ${version}" >&2; exit 1; }
tar -xzOf "${work}/t.tar.gz" "ghostty-${version}/build.zig.zon" > "${work}/build.zig.zon"
upstream_env_set_key "${file}" UPSTREAM_TARBALL_SHA256 "${sha}"
need=$(zig_required_of "${work}/build.zig.zon")
if ! zig_satisfies "${need}" "${ZIG_VERSION}"; then
    echo "ghostty ${version}: signature verified, sha256 ${sha}; but it needs Zig ${need} (same major and minor, patch at least) and ZIG_VERSION=${ZIG_VERSION}" >&2
    echo "ZIG-MISMATCH ${need}"
    exit 3
fi
echo "ghostty ${version}: signature verified, sha256 ${sha}, minimum_zig_version ${need} is satisfied by ${ZIG_VERSION}"
