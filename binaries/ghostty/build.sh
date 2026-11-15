#!/usr/bin/env bash
# Build Ghostty from the checked-out tag (lib/fetch-source.sh) with the pinned Zig (fetch-zig.sh, on PATH or in ZIG_DIR) and stage the image content:
#
#   build.sh <upstream.env> <source dir> <out dir>
#
# The distro-style build of Ghostty's PACKAGING.md, adapted to Zig 0.17 (see the long comment below): the packages of build.zig.zon.txt are fetched into a
# fresh Zig cache and unpacked into a system package directory, then
#   zig build --prefix /usr --system <package dir> -Doptimize=ReleaseFast -Dcpu=baseline ...   with DESTDIR=<source dir>/.dest
# `--system` links the dependencies Fedora packages dynamically (freetype, harfbuzz, fontconfig, oniguruma, GTK, gtk4-layer-shell, ...) and builds the rest from
# the unpacked packages. -Dinstalled-exe-path=/usr/bin/ghostty writes the absolute path into the desktop file, D-Bus service and systemd user unit.
# Staged: root/usr/... (the installed tree without libghostty-vt, copied to /usr by install-binaries.sh), FILES (every path under root/, one per line),
# LICENSES/, SOURCE, BUILDINFO (stage.sh). The binary is smoke-run with `--version` (no display needed) and ELF-checked.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
envfile="${1:?upstream.env}"
srcdir="${2:?source dir}"
out="${3:?out dir}"
stage="${STAGE_SH:-${here}/../lib/stage.sh}"
# shellcheck source=../lib/upstream-env.sh
source "${here}/../lib/upstream-env.sh"
upstream_env_load "${envfile}"
[[ -z "${ZIG_DIR:-}" ]] || export PATH="${ZIG_DIR}:${PATH}"
command -v zig > /dev/null || { echo "build.sh: no zig on PATH" >&2; exit 1; }
version=${UPSTREAM_TAG#v}

# Zig 0.17 changed `zig fetch`: it no longer leaves UNPACKED package directories in <cache>/p but <hash>.tar.gz files, so upstream's
# PACKAGING.md recipe and nix/build-support/fetch-zig-cache.sh (written for older Zig) give `zig build --system <cache>/p` a directory it cannot use:
# it panics at once ("reached unreachable code"), and a plain build in the same polluted cache reports a hash mismatch for every package (found in a
# local build in a Fedora 45 container, 2026-11-15; both attempts failed the same way in CI with Zig 0.17.0 and 0.17.1). So: a FRESH empty Zig cache,
# `zig fetch` of every URL of build.zig.zon.txt (Zig verifies each package against the content hash of build.zig.zon), the saved tarball of each is
# unpacked into the system package directory, and a package whose tarball keeps the upstream top-level directory is flattened one level.
export ZIG_GLOBAL_CACHE_DIR="$(mktemp -d /tmp/zig-global-cache.XXXXXX)"
sys="$(mktemp -d /tmp/zig-syspkgs.XXXXXX)"
(cd "${srcdir}" && zig fetch --help > /dev/null 2>&1 || true)
n=0
while IFS= read -r url; do
    [[ -n "${url}" ]] || continue
    h=$(cd "${srcdir}" && zig fetch "${url}" 2> "${ZIG_GLOBAL_CACHE_DIR}/fetch.err") || { cat "${ZIG_GLOBAL_CACHE_DIR}/fetch.err" >&2; echo "build.sh: zig fetch failed for ${url}" >&2; exit 1; }
    pkg="${ZIG_GLOBAL_CACHE_DIR}/p/${h}.tar.gz"
    [[ -f "${pkg}" ]] || { echo "build.sh: zig fetch left no ${h}.tar.gz for ${url} (a Zig that unpacks into p/ again? then use --system <cache>/p)" >&2; ls -A "${ZIG_GLOBAL_CACHE_DIR}/p" | head >&2; exit 1; }
    tar -xzf "${pkg}" -C "${sys}"
    rm -f "${pkg}"
    n=$((n + 1))
done < "${srcdir}/build.zig.zon.txt"
echo "fetched and unpacked ${n} packages"
for d in "${sys}"/*/; do
    entries=$(ls -A "${d}" | wc -l)
    if [[ "${entries}" == 1 && -d "${d}/$(ls -A "${d}")" ]]; then
        sub=$(ls -A "${d}")
        mv "${d}/${sub}" "${d}/.flat-tmp"
        mv "${d}"/.flat-tmp/* "${d}"/.flat-tmp/.[!.]* "${d}" 2> /dev/null || true
        rmdir "${d}/.flat-tmp"
    fi
done
# still one lone subdirectory after flattening would mean a package nested two levels: fail with a message instead of a confusing Zig error later
for d in "${sys}"/*/; do
    entries=$(ls -A "${d}" | wc -l)
    if [[ "${entries}" == 1 && -d "${d}/$(ls -A "${d}")" ]]; then echo "build.sh: ${d} still holds a single subdirectory after flattening" >&2; exit 1; fi
    [[ "${entries}" -gt 0 ]] || { echo "build.sh: ${d} is empty" >&2; exit 1; }
done

dest="${srcdir}/.dest"
rm -rf "${dest}"
(cd "${srcdir}" && DESTDIR="${dest}" zig build --prefix /usr --system "${sys}" -Doptimize=ReleaseFast -Dcpu=baseline -Dstrip=true \
    -Dversion-string="${version}" -Dinstalled-exe-path=/usr/bin/ghostty)
# libghostty-vt (a stable-ABI development library) is installed too: not wanted in the image
rm -rf "${dest}/usr/include/ghostty" "${dest}"/usr/lib/libghostty-vt*
rmdir "${dest}/usr/include" 2> /dev/null || true
used=system-packages

"${stage}" --out "${out}" --env "${envfile}" --src "${srcdir}" \
    --bin .dest/usr/bin/ghostty:root/usr/bin/ghostty \
    --license LICENSE:ghostty-LICENSE \
    --smoke root/usr/bin/ghostty:--version \
    --elf-x86-64 root/usr/bin/ghostty \
    --info "zig: $(zig version) ($(cat "${ZIG_RECORD:-/opt/zig/FETCH-RECORD}" 2> /dev/null || echo 'no fetch record'))" \
    --info "ghostty: ${version}, zig build --prefix /usr --system <unpacked packages> -Doptimize=ReleaseFast -Dcpu=baseline -Dstrip=true, libghostty-vt pruned"
# the rest of the installed tree (the binary is already there with its mode)
cp -a "${dest}/usr/." "${out}/root/usr/"
(cd "${out}/root" && find . \( -type f -o -type l \) | sed 's#^\./##' | LC_ALL=C sort) > "${out}/FILES"
[[ -s "${out}/FILES" ]] && grep -qx 'usr/bin/ghostty' "${out}/FILES" || { echo "build.sh: FILES lacks usr/bin/ghostty" >&2; exit 1; }
grep -q '^usr/share/applications/com.mitchellh.ghostty.desktop$' "${out}/FILES" || { echo "build.sh: the desktop file com.mitchellh.ghostty.desktop was not installed" >&2; exit 1; }
echo "staged $(wc -l < "${out}/FILES") files"
