#!/usr/bin/env bash
# Installs the prebuilt binaries into the image tree. Run by build.sh; the Containerfile bind-mounts the published
# octarine-os-binaries image (assembled from the components of binaries/, see binaries.yml) at /binaries (BINARIES_ROOT overrides the
# source, DESTDIR the target; both only for the tests and the fallback check).
#   scx     bin/scx_*, schedulers.tsv (name, path, minimum kernel, description; tab separated, no header),
#           LICENSES/, SOURCE, BUILDINFO  ->  /usr/bin, /usr/share/octarine-os/schedulers.tsv
#   extest  lib/libextest.so (32-bit), lib64/libextest.so (64-bit), LICENSES/, SOURCE, BUILDINFO  ->  /usr/lib/extest
#   ghostty (OPTIONAL) root/usr/... (the whole tree Ghostty's `zig build --prefix /usr` installed, listed in FILES), LICENSES/, SOURCE,
#           BUILDINFO  ->  /usr (never over a file the image already has: a conflict leaves the component out, see below)
# The license texts, source and build records go to /usr/share/licenses/octarine-os-binaries/<component>/ (the GPL-2.0 and MIT
# texts must ship with the binaries). Nothing is enabled or started.
#
# Which components are present is told by /binaries/COMPONENTS (name, required|optional, key, origin, created, digest; origin built,
# reused or fallback). The REQUIRED list below must match binaries/components.tsv (a test checks it): a required component that is
# missing fails the build. An OPTIONAL one that is missing is NEVER skipped silently: a WARNING line and annotation, and the file
# /usr/share/licenses/octarine-os-binaries/MISSING name it. A component whose origin is fallback gets a FALLBACK note in its SOURCE
# and BUILDINFO and the file FALLBACK (BINARIES_ONLY=<name> installs just that component from a single-component directory: the
# fallback check of binaries-fallback.sh uses it).
#
# Runtime libraries: build dependencies never travel (the binaries image is FROM scratch), so after installing, every ELF file must
# find its shared libraries in THIS image: a 64-bit file must resolve with ldd (no "not found"), a 32-bit one (extest, loaded into
# 32-bit Steam processes that bring their own libraries) may need only the libraries every process brings. A required component that
# fails this check FAILS the build; an optional one is REMOVED again with a WARNING and the file REMOVED (the build goes on). Only a real
# image build checks (DESTDIR empty); BINARIES_CHECK_NEEDED=1 forces it (tests; BINARIES_LDD replaces ldd).
set -euo pipefail
# Log group (folded in the GitHub Actions build log, plain text elsewhere); the trap closes it however the script ends and prints an
# "::error::" line outside it on failure. Exit status unchanged.
echo "::group::install-binaries.sh"
trap 'rc=$?; echo "::endgroup::"; if (( rc != 0 )); then echo "::error::install-binaries.sh failed (exit ${rc})"; fi' EXIT
root=${BINARIES_ROOT:-/binaries}
dest=${DESTDIR:-}
only=${BINARIES_ONLY:-}
required="scx extest"
optional="ghostty"
lic=${dest}/usr/share/licenses/octarine-os-binaries
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
declare -A origin req
want=()
if [[ -n "${only}" ]]; then
    want=(${only})
else
    test -s "${root}/COMPONENTS" || err "${root}/COMPONENTS is missing or empty (not an assembled binaries image)"
    while IFS=$'\t' read -r name rq _ org _; do
        [[ -n "${name}" && "${name}" != \#* ]] || continue
        [[ " ${required} ${optional} " == *" ${name} "* ]] || err "the binaries image holds the component '${name}', which this installer does not know"
        test -d "${root}/${name}" || err "COMPONENTS lists ${name} but ${root}/${name} is missing"
        origin[${name}]=${org}; req[${name}]=${rq}; want+=("${name}")
    done < "${root}/COMPONENTS"
    for d in "${root}"/*/; do
        # LICENSES/ is the union of the component license directories that assemble.sh adds at the top level (SOURCE and BUILDINFO are files)
        [[ "$(basename "${d}")" == LICENSES || " ${want[*]} " == *" $(basename "${d}") "* ]] || err "${d} is in the binaries image but not in COMPONENTS"
    done
    for c in ${required}; do [[ " ${want[*]} " == *" ${c} "* ]] || err "the required component ${c} is not in the binaries image"; done
fi

# ---- install
for c in ${required} ${optional}; do
    [[ -z "${only}" || " ${only} " == *" ${c} "* ]] || continue
    if [[ " ${want[*]:-} " != *" ${c} "* ]]; then
        # an optional component that is not there: said loudly, recorded, never skipped silently
        warn "optional component ${c} is not in the binaries image: it is NOT installed"
        install -d "${lic}"
        echo "${c}: not in the binaries image (its build failed and no last good image existed)" >> "${lic}/MISSING"
        continue
    fi
    if ! "install_${c}"; then
        if [[ " ${required} " == *" ${c} "* ]]; then err "the required component ${c} could not be installed (see above)"; fi
        warn "optional component ${c} could not be installed (see above): it is LEFT OUT"
        rm -rf ${tracked[${c}]:-}
        install -d "${lic}"
        echo "${c}: could not be installed, see the build log" >> "${lic}/MISSING"
        rest=(); for w in ${want[@]+"${want[@]}"}; do [[ "${w}" == "${c}" ]] || rest+=("${w}"); done
        want=(${rest[@]+"${rest[@]}"})
        continue
    fi
    d=${lic}/${c}
    install -d "${d}"
    cp -a "${root}/${c}/LICENSES/." "${d}/"
    install -m0644 "${root}/${c}/SOURCE" "${root}/${c}/BUILDINFO" "${d}/"
    track "${c}" "${d}"
    if [[ "${origin[${c}]:-}" == fallback ]]; then
        note="FALLBACK: this component is NOT built from the binaries/ tree of this image's commit; it is the last good ${c} image, content key $(awk -F'\t' -v c="${c}" '$1 == c {print $3}' "${root}/COMPONENTS") (built $(awk -F'\t' -v c="${c}" '$1 == c {print $5}' "${root}/COMPONENTS"; true)), used because its build failed"
        printf '%s\n' "${note}" >> "${d}/SOURCE"
        printf '%s\n' "${note}" >> "${d}/BUILDINFO"
        printf '%s: %s\n' "${c}" "${note}" >> "${lic}/FALLBACK"
        warn "${note}"
    fi
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
        if [[ "${req[${c}]:-$([[ " ${required} " == *" ${c} "* ]] && echo required || echo optional)}" == required ]]; then
            err "the required component ${c} needs shared libraries this image does not have (see above): add the package to build.sh"
        fi
        warn "optional component ${c} needs shared libraries this image does not have: it is REMOVED again (see above)"
        # shellcheck disable=SC2086
        rm -rf ${tracked[$c]:-}
        install -d "${lic}"
        echo "${c}: removed, its shared libraries are missing from this image: $(tr '\n' ';' <<<"${probs}")" >> "${lic}/REMOVED"
        installed_note[${c}]="REMOVED"
    done
fi
echo "Installed the prebuilt binaries: $(for c in ${want[@]+"${want[@]}"}; do echo -n "${c} (${installed_note[${c}]:-}) "; done)"
