#!/usr/bin/env bash
# The decision of the assemble job: from the per-component result lines (binaries-decide.sh) to what the assembled image holds.
#
#   binaries-assemble.sh <components.tsv> <results dir> <output dir>
#
# Writes <output dir>/COMPONENTS (tab separated, no header, one line per component that is IN the image:
# name, digest; the keys stay in the `components` output and the image label, nothing reads them from this file) and prints key=value lines (also to GITHUB_OUTPUT when set):
#   action     assemble   every included component has a digest: the image can be assembled (or reused)
#              validated  a component was only built for validation (no digest): nothing can be assembled or published
#              failed     a component is failed or has no result line (exit 1)
#   key        the assembled key over the included components (binaries-key.sh --assembled), the tag of the assembled image
#   components "name=key" pairs of the included components
# A missing result line counts as failed: every component is required.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
list=${1:?components.tsv}
res=${2:?results dir}
outdir=${3:?output dir}
mkdir -p "${outdir}"
: > "${outdir}/COMPONENTS"
pairs=() action=assemble status=0
while IFS=$'\t' read -r name _; do
    [[ -n "${name}" && "${name}" != \#* ]] || continue
    line=""; [[ ! -s "${res}/${name}.tsv" ]] || line=$(head -n1 "${res}/${name}.tsv")
    if [[ -z "${line}" ]]; then
        echo "::error::component ${name} has no result line: its leg did not finish"; status=1; continue
    fi
    IFS=$'\t' read -r _ st digest key _ <<<"${line}"
    case "${st}" in
        reused | built)
            [[ "${digest}" =~ ^sha256:[0-9a-f]{64}$ && "${key}" =~ ^[0-9a-f]{40}$ ]] || { echo "::error::component ${name}: result ${st} without a valid digest or key"; status=1; continue; }
            printf '%s\t%s\n' "${name}" "${digest}" >> "${outdir}/COMPONENTS"
            pairs+=("${name}=${key}") ;;
        validated) [[ "${action}" == failed ]] || action=validated ;;
        *) echo "::error::component ${name} ended as '${st}'"; status=1 ;;
    esac
done < "${list}"
[[ "${status}" == 0 ]] || action=failed
key=""
if [[ "${action}" == assemble ]]; then
    [[ ${#pairs[@]} -gt 0 ]] || { echo "::error::no component is left to assemble"; exit 1; }
    key=$("${here}/binaries-key.sh" --assembled "${pairs[@]}")
fi
emit() { echo "$1=$2"; [[ -z "${GITHUB_OUTPUT:-}" ]] || echo "$1=$2" >> "${GITHUB_OUTPUT}"; }
emit action "${action}"; emit key "${key}"; emit components "${pairs[*]:-}"
[[ "${action}" != failed ]]
