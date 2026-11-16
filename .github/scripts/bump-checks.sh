#!/usr/bin/env bash
# Makes the checks of a bump pull request count. Two facts found 2026-11-15 on #137 (check runs existed on the head commit, `gh pr checks` reported
# nothing, GraphQL statusCheckRollup was null, the PR stayed BLOCKED on the ruleset's required `test` and `secrets`):
#   1. a workflow_dispatch run on the bump branch is NOT part of the pull request's status rollup (a dispatch by a person on a plain branch is not either);
#   2. check runs that are posted through the API join the commit's GitHub Actions check suite when one exists (the dispatch run's own), and are not counted
#      there either; on a commit WITHOUT a GitHub Actions suite the API creates one, and that one counts (an experiment PR went from BLOCKED to CLEAN, the rollup
#      listed test and secrets).
# So the Test workflow is dispatched on the testing ref with `ref=<bump commit>` (it checks that commit out; its suite belongs to testing's commit, the bump
# commit stays without a suite), and this script waits for that run and posts check runs named `test` and `secrets` on the bump commit with the real conclusions of those two
# jobs. No token beyond GITHUB_TOKEN (permissions `checks: write`, `actions: write`); a run that did not finish posts nothing (the PR stays blocked: fail closed).
#
#   bump-checks.sh <branch> <commit sha>      env: GH_TOKEN, GITHUB_REPOSITORY
#
# Idempotent: nothing happens when the commit already has a check run `test` with the marker title. Always exits 0 (a warning line says what is missing). Env: BUMP_BASE (the
# ref Test is dispatched on, default testing), BUMP_CHECKS_WAIT (seconds to wait for the dispatched run to appear, default 90; 0 = do not wait), BUMP_CHECKS_POLL (5),
# BUMP_CHECKS_RUN_MAX (seconds to watch the run, 900).
set -uo pipefail
branch=${1:?branch}
sha=${2:?commit sha}
repo=${GITHUB_REPOSITORY:?GITHUB_REPOSITORY}
base="${BUMP_BASE:-testing}"
wait_s=${BUMP_CHECKS_WAIT:-90}; poll=${BUMP_CHECKS_POLL:-5}; run_max=${BUMP_CHECKS_RUN_MAX:-900}
marker="Reported by bump-checks.sh"
warn() { echo "::warning::$*"; [[ -z "${GITHUB_STEP_SUMMARY:-}" ]] || echo "- $*" >> "${GITHUB_STEP_SUMMARY}" || true; }
[[ "${sha}" =~ ^[0-9a-f]{40}$ ]] || { warn "bump checks for ${branch}: not a commit sha '${sha}', nothing posted"; exit 0; }
done_n=$(gh api "repos/${repo}/commits/${sha}/check-runs?per_page=100" --jq "[.check_runs[]|select(.name==\"test\" and .output.title==\"${marker}\")]|length" 2> /dev/null || echo 0)
if [[ "${done_n}" =~ ^[0-9]+$ && "${done_n}" -gt 0 ]]; then echo "${sha:0:7} already has its reported checks"; exit 0; fi
title="Test of ${sha}"
find_run() { gh run list --workflow test.yml --event workflow_dispatch --limit 50 --json databaseId,displayTitle --jq "[.[]|select(.displayTitle==\"${title}\")][0].databaseId // empty" 2> /dev/null || true; }
id=$(find_run)
if [[ -z "${id}" ]]; then
    if gh workflow run test.yml --ref "${base}" -f "ref=${sha}"; then
        echo "Dispatched the Test workflow on ${base} for ${sha:0:7} (${branch})"
    else
        warn "Could not dispatch the Test workflow on ${branch}: start it by hand with: gh workflow run test.yml --ref ${base} -f ref=${sha}"
        exit 0
    fi
fi
waited=0
while [[ -z "${id}" && "${waited}" -lt "${wait_s}" ]]; do sleep "${poll}"; waited=$((waited + poll)); id=$(find_run); done
[[ -n "${id}" ]] || { warn "bump checks for ${branch}: no Test run for ${sha:0:7} found, nothing posted (re-run the bump workflow)"; exit 0; }
timeout "${run_max}" gh run watch "${id}" -R "${repo}" --interval 20 > /dev/null 2>&1 || true
info=$(gh run view "${id}" -R "${repo}" --json status,url,jobs 2> /dev/null || true)
[[ "$(jq -r '.status // empty' <<<"${info}" 2> /dev/null)" == completed ]] || { warn "bump checks for ${branch}: the Test run ${id} did not finish, nothing posted"; exit 0; }
url=$(jq -r .url <<<"${info}")
for name in test secrets; do
    concl=$(jq -r --arg n "${name}" '[.jobs[]|select(.name==$n)][0].conclusion // "missing"' <<<"${info}")
    [[ "${concl}" == success ]] || concl=failure
    if gh api -X POST "repos/${repo}/check-runs" -f name="${name}" -f head_sha="${sha}" -f status=completed -f conclusion="${concl}" -f details_url="${url}" \
        -f "output[title]=${marker}" -f "output[summary]=The job \`${name}\` of the dispatched Test run ${url} finished with ${concl}." > /dev/null; then
        echo "posted check run ${name}=${concl} on ${sha:0:7}"
    else
        warn "bump checks for ${branch}: could not post the check run ${name}"
    fi
done
exit 0
