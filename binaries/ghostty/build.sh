#!/usr/bin/env bash
# Build Ghostty from the checked-out tag (lib/fetch-source.sh) with the pinned Zig (fetch-zig.sh, on PATH or in ZIG_DIR) and stage the image content:
#
#   build.sh <upstream.env> <source dir> <out dir>
#
# The distro-style offline build of Ghostty's PACKAGING.md (the one step that needs the network is the dependency fetch; Zig checks every package
# against the content hash in build.zig.zon): fetch the packages of build.zig.zon.txt into an empty ZIG_GLOBAL_CACHE_DIR, then
#   zig build --prefix /usr --system <cache>/p -Doptimize=ReleaseFast -Dcpu=baseline ...   with DESTDIR=<source dir>/.dest
# `--system` links the dependencies Fedora packages dynamically (freetype, harfbuzz, fontconfig, libpng, zlib, oniguruma, simdutf, gtk4-layer-shell);
# glslang and spirv-cross are built from the vendored packages (-fno-sys: no pkg-config file or devel package of Fedora 45 is relied on, fewer
# runtime libraries). -Dinstalled-exe-path=/usr/bin/ghostty writes the absolute path into the desktop file, D-Bus service and systemd user unit.
# Staged: root/usr/... (the whole installed tree, copied to /usr by install-binaries.sh), FILES (every path under root/, one per line), LICENSES/,
# SOURCE, BUILDINFO (stage.sh). The binary is smoke-run with `+version` (a CLI action: no display needed) and ELF-checked.
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

export ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-/tmp/zig-global-cache}"
mkdir -p "${ZIG_GLOBAL_CACHE_DIR}"
(cd "${srcdir}" && ./nix/build-support/fetch-zig-cache.sh)
dest="${srcdir}/.dest"
rm -rf "${dest}"
zig_build() { # extra zig arguments
    (cd "${srcdir}" && DESTDIR="${dest}" zig build \
        --prefix /usr \
        --system "${ZIG_GLOBAL_CACHE_DIR}/p" \
        -Doptimize=ReleaseFast \
        -Dcpu=baseline \
        -Dstrip=true \
        -Dversion-string="${version}" \
        -Dinstalled-exe-path=/usr/bin/ghostty \
        -fno-sys=glslang \
        -fno-sys=spirv-cross "$@")
}
# The first CI build of this recipe died in the zig build step with "thread N panic: reached unreachable code" and no stack trace. When
# the build fails, say what the environment looks like and try once more with one job, the build runner's own verbose output and
# reference traces, so the next log shows where it stops; the failure itself still fails the component (it is optional).
if ! zig_build; then
    echo "::warning::zig build failed; collecting diagnostics and retrying once with -j1 --verbose -freference-trace"
    { zig env; echo "nproc: $(nproc)"; ulimit -a; free -m 2>/dev/null; df -h /tmp /src 2>/dev/null; } >&2 || true
    rm -rf "${dest}"
    zig_build -j1 --verbose -freference-trace=20 || { echo "build.sh: zig build failed twice" >&2; exit 1; }
fi

"${stage}" --out "${out}" --env "${envfile}" --src "${srcdir}" \
    --bin .dest/usr/bin/ghostty:root/usr/bin/ghostty \
    --license LICENSE:ghostty-LICENSE \
    --smoke root/usr/bin/ghostty:+version \
    --elf-x86-64 root/usr/bin/ghostty \
    --info "zig: $(zig version) ($(cat "${ZIG_RECORD:-/opt/zig/FETCH-RECORD}" 2> /dev/null || echo 'no fetch record'))" \
    --info "ghostty: ${version}, zig build --prefix /usr --system -Doptimize=ReleaseFast -Dcpu=baseline -Dstrip=true -fno-sys=glslang -fno-sys=spirv-cross"
# the rest of the installed tree (the binary is already there with its mode)
cp -a "${dest}/usr/." "${out}/root/usr/"
(cd "${out}/root" && find . \( -type f -o -type l \) | sed 's#^\./##' | LC_ALL=C sort) > "${out}/FILES"
[[ -s "${out}/FILES" ]] && grep -qx 'usr/bin/ghostty' "${out}/FILES" || { echo "build.sh: FILES lacks usr/bin/ghostty" >&2; exit 1; }
grep -q '^usr/share/applications/com.mitchellh.ghostty.desktop$' "${out}/FILES" || { echo "build.sh: the desktop file com.mitchellh.ghostty.desktop was not installed" >&2; exit 1; }
echo "staged $(wc -l < "${out}/FILES") files"
