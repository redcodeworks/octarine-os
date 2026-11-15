#!/usr/bin/env bash
# The one table of a weekly bump run: pin | current | proposed | PR | status, built from the rows bump-run.sh wrote (tab separated: pin, current,
# proposed, pr, status, note) in a directory, in the order of the pin list. A pin without a row (its job did not run to the end) is a failed one. Prints the
# markdown table (also to GITHUB_STEP_SUMMARY when set) and exits 1 when any pin failed, so the run is red and scripts/scheduled-runs.sh reports it.
#
#   bump-summary.sh <rows dir> <pin>...
set -uo pipefail
dir=${1:?rows dir}; shift
failed=0
table=$(mktemp); trap 'rm -f "${table}"' EXIT
{
    echo "## Pin bumps"
    echo
    echo "| pin | current | proposed | PR | status |"
    echo "|---|---|---|---|---|"
    for p in "$@"; do
        row=""; [[ -s "${dir}/${p}.tsv" ]] && row=$(head -n1 "${dir}/${p}.tsv")
        if [[ -z "${row}" ]]; then echo "| ${p} | - | - | - | failed: no result (the job did not finish) |"; failed=1; continue; fi
        IFS=$'\t' read -r _ cur prop pr st note <<<"${row}"
        [[ "${st}" == ok ]] || failed=1
        echo "| ${p} | ${cur} | ${prop} | ${pr} | ${st}${note:+: ${note}} |"
    done
} > "${table}"
tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}" < "${table}"
exit "${failed}"
