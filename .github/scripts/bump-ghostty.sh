#!/usr/bin/env bash
# Writes the Ghostty and Zig pins of binaries/ghostty (no git, no pull request: bump-run.sh commits, bump-weekly.sh opens the one pull request).
#
#   bump-ghostty.sh ghostty <new-tag> <new-commit> <zig-version> <zig-url> <zig-sha256> <zig-size>
#       a new stable Ghostty tag: changes upstream.env (tag AND peeled commit) and zig.env (version, URL, sha256, size, signature URL) together,
#       because the Zig minor follows from the Ghostty tag
#
# The Zig arguments must be an official ziglang.org x86_64-linux release entry (what fetch-zig.sh requires), else exit 2 and nothing is touched.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root="${REPO_ROOT:-$(cd "${here}/../.." && pwd)}"
# shellcheck source=../../binaries/lib/upstream-env.sh
source "${root}/binaries/lib/upstream-env.sh"

mode="${1:?ghostty}"
dir="${root}/binaries/ghostty"
case "${mode}" in
    ghostty) new_tag="${2:?new tag}"; new_commit="${3:?new commit}"; zv="${4:?zig version}"; zurl="${5:?zig url}"; zsha="${6:?zig sha256}"; zsize="${7:?zig size}" ;;
    *) echo "bump-ghostty.sh: mode must be ghostty (Zig moves only together with the Ghostty tag)" >&2; exit 2 ;;
esac
[[ "${zv}" =~ ^0\.[0-9]+\.[0-9]+$ && "${zsha}" =~ ^[0-9a-f]{64}$ && "${zsize}" =~ ^[0-9]+$ && "${zurl}" == "https://ziglang.org/download/${zv}/zig-x86_64-linux-${zv}.tar.xz" ]] \
    || { echo "bump-ghostty.sh: the Zig arguments are not an official x86_64-linux release entry" >&2; exit 2; }
upstream_env_set "${dir}/upstream.env" "${new_tag}" "${new_commit}"
# the four value lines and the signature URL; comments and the key stay
sed -i \
    -e "s|^ZIG_VERSION=.*|ZIG_VERSION=${zv}|" -e "s|^ZIG_URL=.*|ZIG_URL=${zurl}|" -e "s|^ZIG_SHA256=.*|ZIG_SHA256=${zsha}|" \
    -e "s|^ZIG_SIZE=.*|ZIG_SIZE=${zsize}|" -e "s|^ZIG_SIGNATURE_URL=.*|ZIG_SIGNATURE_URL=${zurl}.minisig|" "${dir}/zig.env"
