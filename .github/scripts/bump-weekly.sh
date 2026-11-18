#!/usr/bin/env bash
# The weekly pin bump: ONE INDEPENDENT pull request into testing PER PIN that moved (2026-11-16, Kevin: so any subset can be merged in any order and the
# rest closed). Every pin starts from current testing on its own branch bump/<pin>-YYYYMMDD with ONE commit (the pin change, made by bump-run.sh), so
# the PRs are not a chain and touch different pin lines. Rules:
#   - the pin already equals upstream (testing has it): nothing is opened; an open bump PR of that pin is closed with a comment (stale);
#   - an open bump PR of the pin already carries the value upstream has now: it stays as it is, nothing new (idempotent reruns);
#   - an open bump PR of the pin carries an OLDER value (upstream moved again): a new branch (bump/<pin>-YYYYMMDD-2 ...: a new name, no force-push is ever used)
#     and a new PR are made, and the older one is closed with a comment pointing at the new one, so at most one bump PR per pin stays open;
#   - a failing pin changes nothing, turns the run red (scripts/scheduled-runs.sh reports it) and does not stop the other pins.
# Every new PR gets the required `test` and `secrets` check runs from bump-checks.sh (keyed by its commit sha, so parallel PRs do not collide).
# DRY_RUN=1 (a manual run with dry_run on) does every decision locally and prints what it would open, keep or close, pushing and opening nothing.
# A real run needs HEAD to be origin/testing (the workflow checks testing out). Needs git, gh with GH_TOKEN, GITHUB_REPOSITORY; BUMP_BASE (testing) for the tests.
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "${REPO_ROOT:-${here}/../..}" || exit 1
base="${BUMP_BASE:-testing}"
# BUMP_PINS: the pins to bump, space separated. No default: the matrix of bump-pins.yml is the only list of pins (one job per pin sets it to its own pin).
read -ra pins <<<"${BUMP_PINS:-}"
[[ ${#pins[@]} -gt 0 ]] || { echo "::error::BUMP_PINS is empty (the pins to bump, e.g. BUMP_PINS=\"bins brew\")"; exit 1; }
summary() { echo "$*"; [[ -z "${GITHUB_STEP_SUMMARY:-}" ]] || echo "$*" >> "${GITHUB_STEP_SUMMARY}" || true; }

git fetch -q origin "${base}" || { echo "::error::cannot fetch ${base}"; exit 1; }
start=$(git rev-parse HEAD)
if [[ -z "${DRY_RUN:-}" && "${start}" != "$(git rev-parse "origin/${base}")" ]]; then
    echo "::error::a real run must start from origin/${base} (this checkout is not it); use dry_run to try another ref"; exit 1
fi
day=$(date -u +%Y%m%d)
summary "## Pin bump: ${pins[*]}"
failed=0

open_prs() { # <pin>: "<number> <branch>" of every open PR into the base whose branch is bump/<pin>-...
    gh pr list --base "${base}" --state open --json number,headRefName 2> /dev/null \
        | jq -r --arg p "bump/$1-" '.[]|select(.headRefName|startswith($p))|"\(.number) \(.headRefName)"' 2> /dev/null || true
}
row_of() { git log -1 --format=%b "$1" | sed -n 1p; } # the pin row of a commit: pin | from | to | what changed upstream | days
to_of() { local r; r=$(row_of "$1"); r=${r#*| }; r=${r#*| }; echo "${r%% |*}"; } # the `to` field
close_pr() { # <number> <comment>
    gh pr close "$1" --delete-branch --comment "$2" || echo "::warning::could not close #$1"
}

for p in "${pins[@]}"; do
    git checkout -q --detach "${start}" || { failed=1; continue; }
    branch="bump/${p}-${day}"; n=1
    while [[ -z "${DRY_RUN:-}" ]] && git ls-remote --exit-code --heads origin "${branch}" > /dev/null 2>&1; do n=$((n + 1)); branch="bump/${p}-${day}-${n}"; done
    git checkout -q -B "${branch}" || { failed=1; continue; }
    "${here}/bump-run.sh" "${p}" || { failed=1; continue; }
    mapfile -t pending < <(open_prs "${p}")
    if [[ -z "$(git rev-list "${start}..HEAD")" ]]; then
        for pr in ${pending[@]+"${pending[@]}"}; do
            if [[ -n "${DRY_RUN:-}" ]]; then summary "Dry run: would close #${pr%% *} (${p}: testing already has the upstream value)"
            else close_pr "${pr%% *}" "Closing: \`${p}\` already equals upstream on \`${base}\`, so this bump is not needed any more."; fi
        done
        continue
    fi
    c=$(git rev-parse HEAD); row=$(row_of "${c}"); to=$(to_of "${c}")
    [[ "${row}" == *" | "* ]] || { echo "::error::${p}: the bump commit has no table row"; failed=1; continue; }
    keep=""
    for pr in ${pending[@]+"${pending[@]}"}; do
        git fetch -q origin "${pr#* }" 2> /dev/null && [[ "$(to_of FETCH_HEAD)" == "${to}" ]] && keep=${pr%% *}
    done
    if [[ -n "${keep}" ]]; then summary "\`${p}\`: #${keep} already proposes ${to}; nothing new"; continue; fi
    title="Bump ${p}: $(cut -d'|' -f2,3 <<<"${row}" | sed 's/ | / to /; s/^ *//; s/ *$//')"; title=${title:0:140}
    note=""
    [[ "${p}" != bins ]] || note=" The new octarine-bins digest (the prebuilt binaries) was verified with \`keys/octarine-bins.pub\`; the testing build after the merge is the first OS build with those binaries (its ldd, 32-bit, terminfo and file-conflict checks run there). Check the scheduler READMEs when the schedulers change."
    body="One commit, one pin; this pull request is independent of the other bump pull requests (merge any subset, in any order, and close the rest).

| pin | from | to | what changed upstream | days the new value has existed |
|---|---|---|---|---|
| ${row} |

Only the pin lines change.${note} Not verified: nothing was built or booted by the bump; the image build after the merge into \`${base}\` is the first build with this pin. The owner merges this pull request.

Checks: this commit is tested by the \`Test\` workflow (dispatched on \`${base}\` for it, because a pull request opened with the workflow token starts no workflow itself) and its \`test\` and \`secrets\` results are reported here as check runs. If they are missing, run the bump workflow again (\`gh workflow run bump-pins.yml --ref ${base}\`): it makes a new branch and pull request and closes this one.

🤖 Generated with [Claude Code](https://claude.com/claude-code)"
    if [[ -n "${DRY_RUN:-}" ]]; then
        summary "Dry run: would open ${branch} (${c:0:7}), title: ${title}"
        for pr in ${pending[@]+"${pending[@]}"}; do summary "Dry run: would close the older #${pr%% *} (${pr#* }), superseded"; done
        summary "${body}"
        continue
    fi
    git push -q origin "refs/heads/${branch}:refs/heads/${branch}" || { echo "::error::cannot push ${branch}"; failed=1; continue; }
    if ! url=$(gh pr create --base "${base}" --head "${branch}" --title "${title}" --body "${body}"); then
        echo "::error::Could not open the pull request for ${p}. Is Settings, Actions, General, Allow GitHub Actions to create and approve pull requests, on?"; failed=1; continue
    fi
    summary "\`${p}\`: opened ${url}"
    for pr in ${pending[@]+"${pending[@]}"}; do close_pr "${pr%% *}" "Superseded by ${url}: upstream moved again, so \`${p}\` has a newer bump pull request."; done
    "${here}/bump-checks.sh" "${branch}" "${c}" || true
done
git checkout -q --detach "${start}" 2> /dev/null || true
exit "${failed}"
