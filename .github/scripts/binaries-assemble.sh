#!/usr/bin/env bash
# The decision of the assemble job: from the per-component result files (binaries-decide.sh) to what the assembled image holds.
#
#   binaries-assemble.sh <components.tsv> <results dir (<component>.json, written by binaries-decide.sh)> <output dir>
#
# Writes <output dir>/COMPONENTS (JSON, one object per line with the fields name and digest for each component that is IN the image; the keys stay in the `components` output and the image label, nothing reads them from this file) and prints key=value lines (also to GITHUB_OUTPUT when set):
#   action     assemble   every included component has a digest: the image can be assembled (or reused)
#              validated  a component was only built for validation (no digest): nothing can be assembled or published
#              failed     a component is failed or has no result (exit 1)
#   key        the assembled key over the included components (binaries-key.sh --assembled), the tag of the assembled image
#   components "name=key" pairs of the included components
# A missing result counts as failed: every component is required.
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
    if [[ ! -s "${res}/${name}.json" ]]; then
        echo "::error::component ${name} has no result: its leg did not finish"; status=1; continue
    fi
    st=$(jq -r .status "${res}/${name}.json"); digest=$(jq -r .digest "${res}/${name}.json"); key=$(jq -r .key "${res}/${name}.json")
    case "${st}" in
        reused | built)
            [[ "${digest}" =~ ^sha256:[0-9a-f]{64}$ && "${key}" =~ ^[0-9a-f]{40}$ ]] || { echo "::error::component ${name}: result ${st} without a valid digest or key"; status=1; continue; }
            jq -nc --arg name "${name}" --arg digest "${digest}" '$ARGS.named' >> "${outdir}/COMPONENTS"
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
