#!/usr/bin/env bash
# Makes the checks of a bump pull request count. The `Test` workflow that bump-pr.sh dispatches on a bump branch runs and passes, but a workflow_dispatch
# run is NOT part of the pull request's status rollup, so the ruleset's required `test` and `secrets` stay missing and the PR stays BLOCKED (found
# 2026-11-15 on #137: check runs existed on the head commit, `gh pr checks` reported nothing, GraphQL statusCheckRollup was null; also with a dispatch made by a
# person on a plain branch; check runs posted through the API into the dispatch run's own suite are not counted either). What IS counted: check runs of the
# GitHub Actions app in a suite that no dispatch run owns, which is what this script makes: it waits for the dispatched Test run of the branch tip and
# posts check runs named `test` and `secrets` from the bump workflow's own run (a different commit, so a suite of its own on the bump commit), with the
# real conclusions of those two jobs. No token beyond GITHUB_TOKEN (permission checks: write on the job); a run that did not finish posts nothing (the PR stays blocked).
#
#   bump-checks.sh <branch> [--dispatch-if-missing]      env: GH_TOKEN, GITHUB_REPOSITORY
#
# Idempotent: nothing is posted when this commit already has a check run `test` with the marker title. --dispatch-if-missing (the "PR already open"
# path of bump-pr.sh) also dispatches Test when no run of the tip exists. Always exits 0 (a warning line says what is missing); tuned by
# BUMP_CHECKS_WAIT (seconds to wait for the dispatched run to appear, default 90; 0 = do not wait), BUMP_CHECKS_POLL (5), BUMP_CHECKS_RUN_MAX (seconds to watch the run, 900).
set -uo pipefail
branch=${1:?branch}
dispatch=${2:-}
repo=${GITHUB_REPOSITORY:?GITHUB_REPOSITORY}
wait_s=${BUMP_CHECKS_WAIT:-90}; poll=${BUMP_CHECKS_POLL:-5}; run_max=${BUMP_CHECKS_RUN_MAX:-900}
marker="Reported by bump-checks.sh"
warn() { echo "::warning::bump checks for ${branch}: $*"; [[ -z "${GITHUB_STEP_SUMMARY:-}" ]] || echo "- bump checks for \`${branch}\`: $*" >> "${GITHUB_STEP_SUMMARY}" || true; }
sha=$(gh api "repos/${repo}/branches/${branch}" --jq .commit.sha 2> /dev/null || true)
[[ "${sha}" =~ ^[0-9a-f]{40}$ ]] || { warn "cannot read the tip of the branch, nothing posted"; exit 0; }
done_n=$(gh api "repos/${repo}/commits/${sha}/check-runs?per_page=100" --jq "[.check_runs[]|select(.name==\"test\" and .output.title==\"${marker}\")]|length" 2> /dev/null || echo 0)
if [[ "${done_n}" =~ ^[0-9]+$ && "${done_n}" -gt 0 ]]; then echo "${sha:0:7} already has its reported checks"; exit 0; fi
find_run() { gh run list --workflow test.yml --branch "${branch}" --event workflow_dispatch --limit 20 --json databaseId,headSha --jq "[.[]|select(.headSha==\"${sha}\")][0].databaseId // empty" 2> /dev/null || true; }
id=$(find_run)
if [[ -z "${id}" && "${dispatch}" == --dispatch-if-missing ]]; then
    gh workflow run test.yml --ref "${branch}" > /dev/null 2>&1 || { warn "could not dispatch Test"; exit 0; }
fi
waited=0
while [[ -z "${id}" && "${waited}" -lt "${wait_s}" ]]; do sleep "${poll}"; waited=$((waited + poll)); id=$(find_run); done
[[ -n "${id}" ]] || { warn "no Test run of ${sha:0:7} found, nothing posted (start it with: gh workflow run test.yml --ref ${branch})"; exit 0; }
timeout "${run_max}" gh run watch "${id}" -R "${repo}" --interval 20 > /dev/null 2>&1 || true
info=$(gh run view "${id}" -R "${repo}" --json status,url,jobs 2> /dev/null || true)
[[ "$(jq -r '.status // empty' <<<"${info}" 2> /dev/null)" == completed ]] || { warn "the Test run ${id} did not finish, nothing posted"; exit 0; }
url=$(jq -r .url <<<"${info}")
for name in test secrets; do
    concl=$(jq -r --arg n "${name}" '[.jobs[]|select(.name==$n)][0].conclusion // "missing"' <<<"${info}")
    [[ "${concl}" == success ]] || concl=failure
    if gh api -X POST "repos/${repo}/check-runs" -f name="${name}" -f head_sha="${sha}" -f status=completed -f conclusion="${concl}" -f details_url="${url}" \
        -f "output[title]=${marker}" -f "output[summary]=The job \`${name}\` of the dispatched Test run ${url} finished with ${concl}." > /dev/null; then
        echo "posted check run ${name}=${concl} on ${sha:0:7}"
    else
        warn "could not post the check run ${name}"
    fi
done
exit 0
