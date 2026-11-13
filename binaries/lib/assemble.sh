#!/usr/bin/env bash
# Put the staged components together into the content of the published image:
#
#   assemble.sh <dir>        <dir> holds scx/ and extest/ (each with LICENSES/, SOURCE, BUILDINFO from stage.sh)
#
# Each component directory stays as it is (the image installer reads them). On top, /LICENSES/ is the union of both
# license directories and /SOURCE and /BUILDINFO are both components' files one after the other, each under a [name]
# heading, so a reader of the bare image sees everything in one place.
set -euo pipefail
dir="${1:?directory}"
comps=(scx extest)
for c in "${comps[@]}"; do
    for f in LICENSES SOURCE BUILDINFO; do
        [[ -e "${dir}/${c}/${f}" ]] || { echo "assemble.sh: ${dir}/${c}/${f} is missing" >&2; exit 1; }
    done
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
