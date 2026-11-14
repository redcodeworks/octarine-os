#!/usr/bin/env bash
# Start the dx workflow for a commit the pipeline just built, and FAIL if no run appears.
#   dispatch-dx.sh <channel> <sha>
# Environment: REF (the branch to dispatch on, main or testing), GITHUB_REPOSITORY, GH_TOKEN (the default token with
# `actions: write`), POLL_TRIES (default 12), POLL_WAIT seconds between tries (default 10), WORKFLOW (default build-dx.yml).
# `gh workflow run` answers 204 before a run exists, so the run is looked up by its title (`dx <channel> <sha>`, the run-name of
# build-dx.yml) among runs created after this script started; no such run within the time fails the step (the base build stays
# green, the final job is red, and re-running that job alone dispatches again). The dx run itself is not waited for.
set -euo pipefail
channel="${1:?channel}"
sha="${2:?sha}"
ref="${REF:?REF}"
repo="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY}"
workflow="${WORKFLOW:-build-dx.yml}"
[[ "${channel}" =~ ^(testing|latest|beta)$ ]] || { echo "::error::unknown channel '${channel}'"; exit 2; }
[[ "${sha}" =~ ^[0-9a-f]{40}$ ]] || { echo "::error::'${sha}' is not a full commit sha"; exit 2; }
[[ "${ref}" =~ ^(main|testing)$ ]] || { echo "::error::refusing to dispatch on '${ref}'"; exit 2; }
start=$(date -u +%Y-%m-%dT%H:%M:%SZ)
gh workflow run "${workflow}" -R "${repo}" --ref "${ref}" -f "channel=${channel}" -f "sha=${sha}" \
    || { echo "::error::could not dispatch ${workflow} on ${ref} (channel ${channel}, ${sha})"; exit 1; }
title="dx ${channel} ${sha}"
tries="${POLL_TRIES:-12}"
for ((i = 1; i <= tries; i++)); do
    found=$(gh run list -R "${repo}" --workflow "${workflow}" --event workflow_dispatch --limit 20 \
        --json databaseId,displayTitle,createdAt,url 2> /dev/null \
        | jq -r --arg t "${title}" --arg s "${start}" '[.[] | select(.displayTitle == $t and .createdAt >= $s)] | first | .url // empty' 2> /dev/null) || found=""
    if [[ -n "${found}" ]]; then
        echo "Started: ${found}"
        [[ -z "${GITHUB_STEP_SUMMARY:-}" ]] || echo "dx ${channel} for ${sha}: ${found}" >> "${GITHUB_STEP_SUMMARY}"
        exit 0
    fi
    (( i == tries )) || sleep "${POLL_WAIT:-10}"
done
echo "::error::${workflow} was dispatched but no run titled '${title}' appeared in $((tries * ${POLL_WAIT:-10})) s; re-run this job to dispatch again"
exit 1
