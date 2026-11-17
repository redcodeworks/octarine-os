#!/usr/bin/env bash
# Installs the prebuilt binaries into the image tree. Run by build.sh; the Containerfile bind-mounts the published
# octarine-bins image (built and signed by the octarine-bins repository, pinned by digest in the Containerfile) at /binaries (BINARIES_ROOT
# overrides the source, DESTDIR the target; both only for the tests). The layout below is a contract with octarine-bins (its CLAUDE.md, "The image
# layout"): a change goes reader first, so this installer accepts the new layout before octarine-bins writes it. tests/install-binaries.sh feeds it a fixture.
#   scx     bin/scx_*, schedulers.tsv (name, path, minimum kernel, description; tab separated, no header),
#           LICENSES/, SOURCE, BUILDINFO  ->  /usr/bin, /usr/share/octarine-os/schedulers.tsv
#   extest  lib/libextest.so (32-bit), lib64/libextest.so (64-bit), LICENSES/, SOURCE, BUILDINFO  ->  /usr/lib/extest
#   ghostty root/usr/... (the whole tree Ghostty's `zig build --prefix /usr` installed, listed in FILES), LICENSES/, SOURCE,
#           BUILDINFO  ->  /usr (never over a file the image already has: a conflict fails the build)
# The license texts, source and build records go to /usr/share/licenses/octarine-binaries/<component>/ (the GPL-2.0 and MIT
# texts must ship with the binaries). Nothing is enabled or started.
#
# Which components are present is told by /binaries/COMPONENTS (the component names, one per line). Every component is required: the `required` list below
# must match the components octarine-bins builds, and a component that is missing, unknown or cannot be installed fails the build.
# The list is PER IMAGE: the default image installs the base octarine-bins image (BINARIES_REQUIRED unset: `scx extest ghostty`); the dx and gx layers call this
# script on their own octarine-bins-dx / -gx image with BINARIES_REQUIRED="" (no component yet: COMPONENTS exists and is EMPTY, which is valid only for an empty
# list). A component those images get later is unknown here until this reader learns it (reader first). A top-level `packages/` directory (the package lists and
# their installer, run by the build scripts, see octarine-bins's CLAUDE.md) is not a component and is allowed in every image.
#
# Runtime libraries: build dependencies never travel (the binaries image is FROM scratch), so after installing, every ELF file must
# find its shared libraries in THIS image: a 64-bit file must resolve with ldd (no "not found"), a 32-bit one (extest, loaded into
# 32-bit Steam processes that bring their own libraries) may need only the libraries every process brings. A component that
# fails this check FAILS the build. Only a real
# image build checks (DESTDIR empty); BINARIES_CHECK_NEEDED=1 forces it (tests; BINARIES_LDD replaces ldd).
set -euo pipefail
# Log group (folded in the GitHub Actions build log, plain text elsewhere); the trap closes it however the script ends and prints an
# "::error::" line outside it on failure. Exit status unchanged.
echo "::group::install-binaries.sh"
trap 'rc=$?; echo "::endgroup::"; if (( rc != 0 )); then echo "::error::install-binaries.sh failed (exit ${rc})"; fi' EXIT
root=${BINARIES_ROOT:-/binaries}
dest=${DESTDIR:-}
required=${BINARIES_REQUIRED-scx extest ghostty}
lic=${dest}/usr/share/licenses/octarine-binaries
err() { echo "ERROR: $*" >&2; exit 1; }
warn() { echo "WARNING: $*"; echo "::warning::$*"; }

declare -A tracked elfs
track() { local c=$1; shift; tracked[$c]+=" $*"; }

install_scx() {
    local scx=${root}/scx n f listed
    test -s "${scx}/schedulers.tsv" || err "${scx}/schedulers.tsv is missing or empty"
    # The manifest and the files must agree both ways: every line has four fields and a path of bin/<name>, every listed
    # scheduler exists, every file under bin/ is listed. awk and cut, not `read` with a tab IFS: the minimum-kernel field is
    # empty today and `read` would collapse it.
    awk -F'\t' 'NF != 4 || $1 == "" || $2 != "bin/" $1 { bad = 1 } END { exit bad }' "${scx}/schedulers.tsv" \
        || err "schedulers.tsv lines must be name, bin/name, minimum kernel, description (tab separated)"
    listed=$(cut -f1 "${scx}/schedulers.tsv")
    for n in ${listed}; do
        test -f "${scx}/bin/${n}" || err "${n} is listed in schedulers.tsv but missing from bin/"
        install -Dm0755 "${scx}/bin/${n}" "${dest}/usr/bin/${n}"
        track scx "${dest}/usr/bin/${n}"; elfs[scx]+=" ${dest}/usr/bin/${n}"
    done
    for f in "${scx}"/bin/*; do
        grep -qxF "$(basename "${f}")" <<<"${listed}" || err "${f} is not listed in schedulers.tsv"
    done
    install -Dm0644 "${scx}/schedulers.tsv" "${dest}/usr/share/octarine-os/schedulers.tsv"
    track scx "${dest}/usr/share/octarine-os/schedulers.tsv"
    installed_note[scx]=$(tr '\n' ' ' <<<"${listed}")
}
install_extest() {
    local ext=${root}/extest
    test -f "${ext}/lib/libextest.so" && test -f "${ext}/lib64/libextest.so" || err "extest lacks lib/ or lib64/ libextest.so"
    install -Dm0755 "${ext}/lib/libextest.so" "${dest}/usr/lib/extest/lib/libextest.so"
    install -Dm0755 "${ext}/lib64/libextest.so" "${dest}/usr/lib/extest/lib64/libextest.so"
    track extest "${dest}/usr/lib/extest"
    elfs[extest]+=" ${dest}/usr/lib/extest/lib/libextest.so ${dest}/usr/lib/extest/lib64/libextest.so"
    installed_note[extest]="libextest.so (32-bit and 64-bit)"
}
install_ghostty() {
    local g=${root}/ghostty f list=() skipped=()
    test -x "${g}/root/usr/bin/ghostty" && test -s "${g}/FILES" || { echo "ghostty lacks root/usr/bin/ghostty or FILES" >&2; return 1; }
    while IFS= read -r f; do
        [[ "${f}" == usr/* && "${f}" != *..* ]] || { echo "ghostty FILES holds a path outside usr/: ${f}" >&2; return 1; }
        test -e "${g}/root/${f}" || test -L "${g}/root/${f}" || { echo "ghostty FILES lists ${f}, which is not in the image" >&2; return 1; }
        if test -e "${dest}/${f}" || test -L "${dest}/${f}"; then
            # the terminfo entries ghostty and xterm-ghostty are already in the base (ncurses-term): the image's own file stays, it is the same
            # terminal description; any other file the image already has is a real conflict
            if [[ "${f}" == usr/share/terminfo/* ]]; then skipped+=("${f}"); continue; fi
            echo "ghostty would overwrite ${f}, which the image already has" >&2; return 1
        fi
        list+=("${f}")
    done < "${g}/FILES"
    [[ ${#skipped[@]} -eq 0 ]] || echo "ghostty: kept the image's own terminfo: ${skipped[*]}"
    printf '%s\n' "${list[@]}" | tar -C "${g}/root" -cf - -T - | tar -C "${dest:-/}" -xf -
    for f in "${list[@]}"; do track ghostty "${dest}/${f}"; done
    elfs[ghostty]+=" ${dest}/usr/bin/ghostty"
    installed_note[ghostty]="${#list[@]} files under /usr (${#skipped[@]} terminfo files of the image kept)"
}
declare -A installed_note

# ---- which components
want=()
if [[ -n "${required}" ]]; then
    test -s "${root}/COMPONENTS" || err "${root}/COMPONENTS is missing or empty (not an assembled binaries image)"
else
    test -f "${root}/COMPONENTS" || err "${root}/COMPONENTS is missing (not an assembled binaries image)"
fi
while read -r name; do
    [[ " ${required} " == *" ${name} "* ]] || err "the binaries image holds the component '${name}', which this installer does not know"
    test -d "${root}/${name}" || err "COMPONENTS lists ${name} but ${root}/${name} is missing"
    want+=("${name}")
done < "${root}/COMPONENTS"
for d in "${root}"/*/; do
    # LICENSES/ is the union of the component license directories that assemble.sh adds at the top level (SOURCE and BUILDINFO are files); packages/ is the package lists
    [[ "$(basename "${d}")" == LICENSES || "$(basename "${d}")" == packages || " ${want[*]:-} " == *" $(basename "${d}") "* ]] || err "${d} is in the binaries image but not in COMPONENTS"
done
for c in ${required}; do [[ " ${want[*]} " == *" ${c} "* ]] || err "the required component ${c} is not in the binaries image"; done

# ---- install
for c in ${required}; do
    "install_${c}" || err "the component ${c} could not be installed (see above)"
    d=${lic}/${c}
    install -d "${d}"
    cp -a "${root}/${c}/LICENSES/." "${d}/"
    install -m0644 "${root}/${c}/SOURCE" "${root}/${c}/BUILDINFO" "${d}/"
    track "${c}" "${d}"
done
grep -rqF 'GNU GENERAL PUBLIC LICENSE' "${lic}/scx" 2> /dev/null || [[ " ${want[*]:-} " != *" scx "* ]] || err "no GPL text shipped with scx"
grep -rqF 'MIT License' "${lic}/extest" 2> /dev/null || [[ " ${want[*]:-} " != *" extest "* ]] || err "no MIT text shipped with extest"

# ---- the runtime libraries
class_of() { readelf -h "$1" | sed -n 's/.*Class:[[:space:]]*\(ELF[0-9]*\).*/\1/p'; }
# libraries every process that loads a 32-bit file brings along (glibc and libgcc)
allowed32=" libc.so.6 libgcc_s.so.1 libm.so.6 libdl.so.2 libpthread.so.0 librt.so.1 ld-linux.so.2 "
needed_problems() { # component -> prints one line per problem
    local f cls out lib
    for f in ${elfs[$1]:-}; do
        cls=$(class_of "${f}")
        if [[ "${cls}" == ELF64 ]]; then
            out=$(${BINARIES_LDD:-ldd} "${f}" 2>&1) || true
            grep -q 'not found' <<<"${out}" && grep 'not found' <<<"${out}" | sed "s#^#${f#"${dest}"}: #"
        else
            for lib in $(readelf -d "${f}" | sed -n 's/.*(NEEDED)[[:space:]]*Shared library: \[\(.*\)\]/\1/p'); do
                [[ "${allowed32}" == *" ${lib} "* ]] || echo "${f#"${dest}"}: needs ${lib}, which a 32-bit process is not guaranteed to have"
            done
        fi
    done
    return 0
}
if [[ -z "${dest}" || -n "${BINARIES_CHECK_NEEDED:-}" ]]; then
    for c in ${want[@]+"${want[@]}"}; do
        probs=$(needed_problems "${c}")
        [[ -n "${probs}" ]] || { echo "runtime libraries of ${c}: all found in this image"; continue; }
        echo "${probs}" >&2
        err "the component ${c} needs shared libraries this image does not have (see above): add the package to build.sh"
    done
fi
# Files copied into /usr by hand run no package trigger: refresh the icon and desktop caches for what a component installed (ghostty: hicolor icons and a desktop file).
# Needed in an ostree image: the base's icon-theme.cache and the directory have the same normalized mtime (1970-01-01), so GTK trusts a STALE cache that does
# not list the new icons and shows the generic icon (found 2026-11-15: Ghostty's app-grid entry had no icon). Only in the real build (empty DESTDIR).
if [[ -z "${dest}" && " ${want[*]:-} " == *" ghostty "* && -e /usr/bin/ghostty ]]; then
    for tool in gtk-update-icon-cache gtk4-update-icon-cache; do
        if command -v "${tool}" > /dev/null 2>&1; then "${tool}" -f -t /usr/share/icons/hicolor && echo "${tool}: refreshed /usr/share/icons/hicolor" && break; fi
    done
    if command -v update-desktop-database > /dev/null 2>&1; then update-desktop-database -q /usr/share/applications && echo "update-desktop-database: refreshed /usr/share/applications"; fi
    # a lookup by name at 48 px through GTK's own icon theme code, with the Adwaita theme (what a window of the app asks for): reported, never fatal
    if command -v python3 > /dev/null 2>&1; then
        python3 - << 'PYEOF' || echo "icon lookup: could not run (no gi/GTK 4 here?)"
import gi
gi.require_version("Gtk", "4.0")
from gi.repository import Gtk
t = Gtk.IconTheme()
t.set_theme_name("Adwaita")
for size in (16, 32, 48, 128):
    i = t.lookup_icon("com.mitchellh.ghostty", None, size, 1, Gtk.TextDirection.NONE, 0)
    f = i.get_file()
    print("icon lookup com.mitchellh.ghostty at %d px: %s" % (size, f.get_path() if f else "NOT FOUND"))
PYEOF
    fi
    grep -aq com.mitchellh.ghostty /usr/share/icons/hicolor/icon-theme.cache 2> /dev/null || warn "the hicolor icon cache does not list com.mitchellh.ghostty (no cache tool found?): Ghostty may show a generic icon"
fi
if [[ ${#want[@]} -eq 0 ]]; then echo "No binary component in ${root} (an image without components): nothing to install"; exit 0; fi
echo "Installed the prebuilt binaries: $(for c in ${want[@]+"${want[@]}"}; do echo -n "${c} (${installed_note[${c}]:-}) "; done)"
