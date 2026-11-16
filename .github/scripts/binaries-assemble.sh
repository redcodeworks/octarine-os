#!/usr/bin/env bash
# The decision of the assemble job: from the per-component result lines (binaries-decide.sh) to what the assembled image holds.
#
#   binaries-assemble.sh <components.tsv> <results dir> <output dir>
#
# Writes <output dir>/COMPONENTS (tab separated, no header, one line per component that is IN the image:
# name, required|optional, key, origin built|reused, digest) and prints key=value lines (also to GITHUB_OUTPUT when set):
#   action     assemble   every included component has a digest: the image can be assembled (or reused)
#              validated  a component was only built for validation (no digest): nothing can be assembled or published
#              failed     a required component is failed or has no result line (exit 1)
#   key        the assembled key over the included components (binaries-key.sh --assembled), the tag of the assembled image
#   degraded   optional components that are left out, e.g. "ghostty:absent" (empty when none)
#   components "name=key" pairs of the included components
# A missing result line of an optional component counts as absent, of a required one as failed.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
list=${1:?components.tsv}
res=${2:?results dir}
outdir=${3:?output dir}
mkdir -p "${outdir}"
: > "${outdir}/COMPONENTS"
pairs=() degraded=() action=assemble status=0
while IFS=$'\t' read -r name req _; do
    [[ -n "${name}" && "${name}" != \#* ]] || continue
    line=""; [[ ! -s "${res}/${name}.tsv" ]] || line=$(head -n1 "${res}/${name}.tsv")
    if [[ -z "${line}" ]]; then
        if [[ "${req}" == optional ]]; then line="${name}"$'\t'absent$'\t\t\t'"no result line"; else echo "::error::component ${name} (required) has no result line: its leg did not finish"; status=1; continue; fi
    fi
    IFS=$'\t' read -r _ st digest key _ <<<"${line}"
    case "${st}" in
        reused | built)
            [[ "${digest}" =~ ^sha256:[0-9a-f]{64}$ && "${key}" =~ ^[0-9a-f]{40}$ ]] || { echo "::error::component ${name}: result ${st} without a valid digest or key"; status=1; continue; }
            printf '%s\t%s\t%s\t%s\t%s\n' "${name}" "${req}" "${key}" "${st}" "${digest}" >> "${outdir}/COMPONENTS"
            pairs+=("${name}=${key}") ;;
        absent)
            if [[ "${req}" == optional ]]; then degraded+=("${name}:absent"); else echo "::error::component ${name} is required and absent"; status=1; fi ;;
        validated) [[ "${action}" == failed ]] || action=validated ;;
        *) echo "::error::component ${name} (${req}) ended as '${st}'"; if [[ "${req}" == optional && "${st}" != failed ]]; then degraded+=("${name}:absent"); else status=1; fi ;;
    esac
done < "${list}"
[[ "${status}" == 0 ]] || action=failed
key=""
if [[ "${action}" == assemble ]]; then
    [[ ${#pairs[@]} -gt 0 ]] || { echo "::error::no component is left to assemble"; exit 1; }
    key=$("${here}/binaries-key.sh" --assembled "${pairs[@]}")
fi
emit() { echo "$1=$2"; [[ -z "${GITHUB_OUTPUT:-}" ]] || echo "$1=$2" >> "${GITHUB_OUTPUT}"; }
emit action "${action}"; emit key "${key}"; emit degraded "${degraded[*]:-}"; emit components "${pairs[*]:-}"
[[ "${action}" != failed ]]
