#!/usr/bin/env bash
# The `assemble` stage of binaries/Containerfile: put the built components together into the content of the published image.
#
#   assemble.sh <dir> <components.tsv>     <dir> holds one directory per component (scx, extest, ghostty), each with LICENSES/, SOURCE and BUILDINFO from stage.sh
#
# Each component directory stays as it is (the image installer reads them). On top, /LICENSES/ is the union of the license directories, /SOURCE and
# /BUILDINFO are the components' files one after the other, each under a [name] heading, and /COMPONENTS lists the component names, one per line (what the
# installer expects to find: build_files/install-binaries.sh).
set -euo pipefail
dir="${1:?directory}"
tsv="${2:?components.tsv}"
comps=()
while IFS=$'\t' read -r name _; do
    [[ -n "${name}" && "${name}" != \#* ]] && comps+=("${name}")
done < "${tsv}"
[[ ${#comps[@]} -gt 0 ]] || { echo "assemble.sh: no component in ${tsv}" >&2; exit 1; }
for c in "${comps[@]}"; do
    for f in LICENSES SOURCE BUILDINFO; do
        [[ -e "${dir}/${c}/${f}" ]] || { echo "assemble.sh: ${dir}/${c}/${f} is missing" >&2; exit 1; }
    done
done
for d in "${dir}"/*/; do
    [[ " ${comps[*]} " == *" $(basename "${d}") "* ]] || { echo "assemble.sh: ${d} is not listed in ${tsv}" >&2; exit 1; }
done
mkdir -p "${dir}/LICENSES"
for c in "${comps[@]}"; do cp -a "${dir}/${c}/LICENSES/." "${dir}/LICENSES/"; done
for f in SOURCE BUILDINFO; do
    : > "${dir}/${f}"
    for c in "${comps[@]}"; do
        { echo "[${c}]"; cat "${dir}/${c}/${f}"; echo; } >> "${dir}/${f}"
    done
done
printf '%s\n' "${comps[@]}" > "${dir}/COMPONENTS"
echo "assembled: ${comps[*]}"
