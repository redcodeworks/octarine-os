#!/usr/bin/env bash
# Put the staged components together into the content of the published image:
#
#   assemble.sh <dir>        <dir> holds COMPONENTS (written by binaries-assemble.sh: name, required|optional, key, origin, created,
#                            digest per component that is in the image) and one directory per listed component, each with LICENSES/,
#                            SOURCE and BUILDINFO from stage.sh
#
# Each component directory stays as it is (the image installer reads them). On top, /LICENSES/ is the union of the license
# directories and /SOURCE and /BUILDINFO are the components' files one after the other, each under a [name] heading, so a reader of
# the bare image sees everything in one place. COMPONENTS stays in the image: it tells the installer what is present and where each
# component came from (built, reused or fallback).
set -euo pipefail
dir="${1:?directory}"
[[ -s "${dir}/COMPONENTS" ]] || { echo "assemble.sh: ${dir}/COMPONENTS is missing or empty" >&2; exit 1; }
comps=()
while IFS=$'\t' read -r name _; do [[ -z "${name}" || "${name}" == \#* ]] || comps+=("${name}"); done < "${dir}/COMPONENTS"
for c in "${comps[@]}"; do
    for f in LICENSES SOURCE BUILDINFO; do
        [[ -e "${dir}/${c}/${f}" ]] || { echo "assemble.sh: ${dir}/${c}/${f} is missing" >&2; exit 1; }
    done
done
for d in "${dir}"/*/; do
    [[ " ${comps[*]} " == *" $(basename "${d}") "* ]] || { echo "assemble.sh: ${d} is not listed in COMPONENTS" >&2; exit 1; }
done
mkdir -p "${dir}/LICENSES"
for c in "${comps[@]}"; do cp -a "${dir}/${c}/LICENSES/." "${dir}/LICENSES/"; done
for f in SOURCE BUILDINFO; do
    : > "${dir}/${f}"
    for c in "${comps[@]}"; do
        { echo "[${c}]"; cat "${dir}/${c}/${f}"; echo; } >> "${dir}/${f}"
    done
done
echo "assembled: ${comps[*]}"
