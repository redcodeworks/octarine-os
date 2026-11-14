#!/usr/bin/env bash
# Start the dx workflow for a commit the pipeline just built, and FAIL if no run appears.
#   dispatch-dx.sh <channel> <sha> [<base_digest>]
# Environment: REF (the branch to dispatch on, main or testing), GITHUB_REPOSITORY, GH_TOKEN (the default token with
# `actions: write`), POLL_TRIES (default 12), POLL_WAIT seconds between tries (default 10), WORKFLOW (default build-dx.yml),
# GITHUB_STEP_SUMMARY (optional; a failure to write to it never fails the step).
#
# Finding the run. The dispatch API answers 204 unless the request carries `return_run_details: true`; `gh` 2.87.0 and later sends it and
# prints the run URL when stdout is not a terminal. So: the URL printed by `gh workflow run` is used when there is one (its trailing
# number is the run id; the run is then checked for event and branch). A `gh` that prints no URL (an older one on the runner) gets
# the snapshot approach: the ids of the runs of this workflow on this branch are listed BEFORE the dispatch, and the run is the first id that is
# not in that list, on this branch, with the run-name (`dx <channel> <sha>`) or the workflow name as its title (a fresh run has the workflow name until the run-name applies; the title is informational, never a reason to fail). No clock is used anywhere. Either
# way, no run found within the time fails the step (the base build stays green, this job is red, and re-running it dispatches again).
# The dx run itself is not waited for.
set -euo pipefail
channel="${1:?channel}"
sha="${2:?sha}"
base_digest="${3-}"
ref="${REF:?REF}"
repo="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY}"
workflow="${WORKFLOW:-build-dx.yml}"
[[ "${channel}" =~ ^(testing|latest|beta)$ ]] || { echo "::error::unknown channel '${channel}'"; exit 2; }
[[ "${sha}" =~ ^[0-9a-f]{40}$ ]] || { echo "::error::'${sha}' is not a full commit sha"; exit 2; }
[[ -z "${base_digest}" || "${base_digest}" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "::error::'${base_digest}' is not a sha256 digest"; exit 2; }
[[ "${ref}" =~ ^(main|testing)$ ]] || { echo "::error::refusing to dispatch on '${ref}'"; exit 2; }
echo "gh: $(gh --version 2> /dev/null | head -n1)"
title="dx ${channel} ${sha}"

list_runs() {
    gh run list -R "${repo}" --workflow "${workflow}" --branch "${ref}" --event workflow_dispatch --limit 50 \
        --json databaseId,displayTitle,headBranch,url 2> /dev/null || echo '[]'
}
before=$(list_runs | jq -r '[.[].databaseId] | map(tostring) | join(" ")' 2> /dev/null) || before=""

args=(-f "channel=${channel}" -f "sha=${sha}")
[[ -z "${base_digest}" ]] || args+=(-f "base_digest=${base_digest}")
out=$(gh workflow run "${workflow}" -R "${repo}" --ref "${ref}" "${args[@]}" 2>&1) \
    || { echo "${out}"; echo "::error::could not dispatch ${workflow} on ${ref} (channel ${channel}, ${sha})"; exit 1; }
echo "${out}"

started() {
    echo "Started: $1"
    [[ -z "${GITHUB_STEP_SUMMARY:-}" ]] || echo "dx ${channel} for ${sha}: $1" >> "${GITHUB_STEP_SUMMARY}" 2> /dev/null || true
    exit 0
}

# 1. the URL that gh printed (the API returned the run id). The run is checked by branch and event only: its title is the workflow name
# ("Build dx image") for the first seconds and becomes the run-name (`dx <channel> <sha>`) later, so a title check would race (it did, on the
# first real run: gh 2.103.3 on the runner printed the right URL and the old check rejected the title of a run that had just been created).
url=$(grep -oE "https://[^ ]+/actions/runs/[0-9]+" <<< "${out}" | tail -n1 || true)
if [[ -n "${url}" ]]; then
    id=${url##*/}
    for ((i = 1; i <= 3; i++)); do
        if info=$(gh run view "${id}" -R "${repo}" --json event,headBranch 2> /dev/null); then
            e=$(jq -r .event <<< "${info}"); b=$(jq -r .headBranch <<< "${info}")
            if [[ "${e}" == workflow_dispatch && "${b}" == "${ref}" ]]; then started "${url}"; fi
            echo "::error::run ${id} (from the dispatch) is a '${e}' run on '${b}', expected a workflow_dispatch run on '${ref}'"
            exit 1
        fi
        sleep "${POLL_WAIT:-10}"
    done
    echo "::error::run ${id} (${url}) was returned by the dispatch but cannot be read"
    exit 1
fi

# 2. no URL printed: the snapshot approach
echo "gh printed no run URL: looking for a run that was not there before the dispatch"
tries="${POLL_TRIES:-12}"
for ((i = 1; i <= tries; i++)); do
    # a run that was not listed before the dispatch, on this branch, titled with the run-name or (for the first seconds, or for good when the
    # run-name never applies) the workflow name; the exact run-name wins when both exist
    found=$(list_runs | jq -r --arg t "${title}" --arg w "Build dx image" --arg b "${ref}" --arg before " ${before} " \
        '[.[] | select((.displayTitle == $t or .displayTitle == $w) and .headBranch == $b and (((.databaseId | tostring) as $i | $before | contains(" " + $i + " ")) | not))]
         | (map(select(.displayTitle == $t)) + .) | first | .url // empty' 2> /dev/null) || found=""
    if [[ -n "${found}" ]]; then started "${found}"; fi
    (( i == tries )) || sleep "${POLL_WAIT:-10}"
done
echo "::error::${workflow} was dispatched but no new run titled '${title}' appeared on ${ref} in $((tries * ${POLL_WAIT:-10})) s; re-run this job to dispatch again"
exit 1
