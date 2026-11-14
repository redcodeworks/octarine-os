#!/usr/bin/env bash
# Install the pinned Zig toolchain in the builder: the official release from ziglang.org, verified against the pinned minisign key
# and the pinned sha256 (lib/fetch-tarball.sh), unpacked in /opt/zig and linked as /usr/local/bin/zig.
#
#   fetch-zig.sh <upstream.env>           (ZIG_DEST and ZIG_LINK override the two paths, for the tests)
#
# Fedora 45 packages Zig 0.16 only; Ghostty v1.4.0 needs 0.17 (see upstream.env), so the distribution package cannot be used.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../lib/upstream-env.sh
source "${here}/../lib/upstream-env.sh"
upstream_env_load "${1:?upstream.env}"
dest=${ZIG_DEST:-/opt/zig}
link=${ZIG_LINK:-/usr/local/bin/zig}
[[ -n "${ZIG_VERSION}" && -n "${ZIG_URL}" ]] || { echo "::error::ZIG_VERSION and ZIG_URL are not set in upstream.env" >&2; exit 1; }
"${here}/../lib/fetch-tarball.sh" "${ZIG_URL//@VERSION@/${ZIG_VERSION}}" "${ZIG_SHA256}" "${ZIG_MINISIGN_KEY}" "${dest}"
[[ -x "${dest}/zig" ]] || { echo "::error::the Zig tarball has no ${dest}/zig" >&2; exit 1; }
ln -sf "${dest}/zig" "${link}"
got=$("${link}" version)
[[ "${got}" == "${ZIG_VERSION}" ]] || { echo "::error::zig reports ${got}, upstream.env pins ${ZIG_VERSION}" >&2; exit 1; }
echo "zig ${got} installed from ${ZIG_URL//@VERSION@/${ZIG_VERSION}}"
