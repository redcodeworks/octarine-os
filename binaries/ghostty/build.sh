#!/usr/bin/env bash
# Build Ghostty from the pinned, verified source tarball (already unpacked by lib/fetch-source.sh) the way PACKAGING.md describes for a
# system package, and stage the image content:
#
#   build.sh <upstream.env> <source dir> <out dir>
#
# 1. The Zig toolchain on PATH must satisfy minimum_zig_version of the pinned source (zig-version.sh) and be the pinned version.
# 2. Every system library the build will link must be found by pkg-config (a missing -devel package fails here with its name).
# 3. The only step that needs the network: nix/build-support/fetch-zig-cache.sh `zig fetch`es every URL of build.zig.zon.txt into an
#    offline cache (deps.files.ghostty.org, plus one git dependency each on github.com and codeberg.org). Zig stores a package under its
#    CONTENT HASH and the build in --system mode only finds a package under the hash that build.zig.zon names, so a file that differs
#    from what upstream pinned is not found and the build stops (the signed tarball already fixed build.zig.zon and the URL list).
# 4. DESTDIR=<src>/.stage zig build --prefix /usr --system <cache>/p -Doptimize=ReleaseFast -Dcpu=baseline
#    -Dinstalled-exe-path=/usr/bin/ghostty (written into the desktop file, D-Bus service and systemd user service; no DESTDIR in it).
#    --system links the dependencies dynamically and makes a PIE. -fno-sys=<name> keeps a library out of the system set and builds it
#    from the cached package instead; Fedora 45 has no spirv-cross package, so that one is linked statically.
# 5. stage.sh stages the whole install tree (/usr/...), the binary, the licenses, SOURCE and BUILDINFO and runs `ghostty --version`.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
envfile="${1:?upstream.env}"
srcdir="${2:?source dir}"
out="${3:?out dir}"
stage="${STAGE_SH:-${here}/../lib/stage.sh}"
cache="${ZIG_OFFLINE_CACHE:-/tmp/offline-cache}"
# shellcheck source=../lib/upstream-env.sh
source "${here}/../lib/upstream-env.sh"
# shellcheck source=zig-version.sh
source "${here}/zig-version.sh"
upstream_env_load "${envfile}"
version=${UPSTREAM_TAG#v}
[[ -n "${version}" ]] || { echo "build.sh: UPSTREAM_TAG is empty" >&2; exit 1; }

# 1. the toolchain
zig_have=$(zig version)
zig_need=$(zig_required_of "${srcdir}/build.zig.zon")
[[ "${zig_have}" == "${ZIG_VERSION}" ]] || { echo "::error::zig is ${zig_have}, upstream.env pins ${ZIG_VERSION}" >&2; exit 1; }
zig_satisfies "${zig_need}" "${zig_have}" || { echo "::error::Ghostty ${version} needs Zig ${zig_need} (same major and minor, patch at least), the pinned toolchain is ${zig_have}: change ZIG_* in upstream.env" >&2; exit 1; }
echo "zig ${zig_have} satisfies minimum_zig_version ${zig_need}"

# 2. system libraries: `<zig option>=<pkg-config modules>`; the second list is what stays out of the system set
system_libs=(
    "freetype=freetype2 bzip2"
    "harfbuzz=harfbuzz"
    "fontconfig=fontconfig"
    "oniguruma=oniguruma"
    "glslang=glslang glslang-default-resource-limits"
    "simdutf=simdutf"
    "gtk4-layer-shell=gtk4-layer-shell-0"
)
no_system=(spirv-cross)
other_modules=(gtk4 libadwaita-1 wayland-client egl x11 glib-2.0 gio-2.0)
missing=()
for entry in "${system_libs[@]}"; do
    for m in ${entry#*=}; do pkg-config --exists "${m}" || missing+=("${m}"); done
done
for m in "${other_modules[@]}"; do pkg-config --exists "${m}" || missing+=("${m}"); done
[[ ${#missing[@]} -eq 0 ]] || { echo "::error::pkg-config cannot find: ${missing[*]} (a -devel package missing from the builder, or a renamed module)" >&2; exit 1; }
sysflags=()
for n in "${no_system[@]}"; do sysflags+=("-fno-sys=${n}"); done

# 3. the dependency cache (network)
for f in nix/build-support/fetch-zig-cache.sh build.zig.zon.txt; do
    [[ -e "${srcdir}/${f}" ]] || { echo "::error::the source tarball has no ${f}" >&2; exit 1; }
done
(cd "${srcdir}" && ZIG_GLOBAL_CACHE_DIR="${cache}" ./nix/build-support/fetch-zig-cache.sh)

# 4. the build (no network: --system)
rm -rf "${srcdir}/.stage"
(cd "${srcdir}" && DESTDIR="${srcdir}/.stage" ZIG_GLOBAL_CACHE_DIR="${cache}-build" zig build \
    --prefix /usr --system "${cache}/p" \
    -Doptimize=ReleaseFast -Dcpu=baseline \
    -Dversion-string="${version}" \
    -Dinstalled-exe-path=/usr/bin/ghostty \
    "${sysflags[@]}")
[[ -x "${srcdir}/.stage/usr/bin/ghostty" ]] || { echo "::error::the build did not install .stage/usr/bin/ghostty" >&2; exit 1; }
# none of the generated files may name the staging directory
if grep -rIlF "${srcdir}/.stage" "${srcdir}/.stage" > /dev/null 2>&1; then
    echo "::error::files under .stage contain the staging path (installed-exe-path must not include DESTDIR)" >&2
    grep -rIlF "${srcdir}/.stage" "${srcdir}/.stage" >&2
    exit 1
fi

# 5. licenses: the Ghostty license, and the license files that come with the fonts that are compiled into the binary
mkdir -p "${srcdir}/.licenses"
lics=(--license LICENSE:ghostty-LICENSE)
if [[ -d "${cache}/p" ]]; then
    while IFS= read -r f; do
        name="ghostty-font-$(basename "$(dirname "${f}")")-$(basename "${f}")"
        cp "${f}" "${srcdir}/.licenses/${name}"
        lics+=(--license ".licenses/${name}:${name}")
    done < <(find "${cache}/p" -maxdepth 2 -type f \( -iname 'OFL*' -o -iname 'LICENSE*' \) \( -ipath '*jetbrains*' -o -ipath '*nerdfont*' -o -ipath '*nerd-font*' \) | sort)
fi

"${stage}" --out "${out}" --env "${envfile}" --src "${srcdir}" \
    --tree .stage/usr:usr \
    --bin .stage/usr/bin/ghostty:usr/bin/ghostty \
    "${lics[@]}" \
    --smoke usr/bin/ghostty:--version \
    --elf-x86-64 usr/bin/ghostty \
    --info "zig: ${zig_have} (minimum_zig_version of the source: ${zig_need})" \
    --info "zig build: --prefix /usr --system -Doptimize=ReleaseFast -Dcpu=baseline -Dinstalled-exe-path=/usr/bin/ghostty ${sysflags[*]}" \
    --info "system libraries (dynamic): $(printf '%s ' "${system_libs[@]%%=*}")gtk4 libadwaita gtk4-layer-shell wayland glib" \
    --info "built from the package, linked statically: ${no_system[*]} highway and the rest of the Zig packages" \
    --info "pkg-config versions: $(for m in gtk4 libadwaita-1 gtk4-layer-shell-0 harfbuzz freetype2 fontconfig oniguruma glslang simdutf; do printf '%s=%s ' "${m}" "$(pkg-config --modversion "${m}")"; done)"
