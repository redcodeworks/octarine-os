#!/usr/bin/env bash
# The weekly pin bump: ONE branch, ONE pull request into testing, ONE commit per pin that moved. Runs every pin through bump-run.sh (a failing pin does not stop the
# others; the exit status is non-zero when any failed, which scripts/scheduled-runs.sh reports), then:
#   - nothing moved: no branch, no pull request;
#   - something moved: the branch bump/weekly-YYYYMMDD (bump/weekly-YYYYMMDD-2 and so on when a run of the same day already made one: a new name instead of a
#     force-push) starts from current testing and carries a commit per pin, pending pins that an older unmerged weekly PR also had included (the decisions compare with
#     testing, so nothing pending is lost); the pull request is opened, its Test run is dispatched and reported (bump-checks.sh), and every OLDER open weekly PR is
#     closed with a comment pointing at the new one. A pin is dropped by reverting its commit.
# DRY_RUN=1 (a manual run with dry_run on) does all decisions and commits locally and prints the would-be pull request, pushing and opening nothing.
# A real run needs HEAD to be origin/testing (the workflow checks testing out). Needs git, gh with GH_TOKEN, GITHUB_REPOSITORY; BUMP_BASE (testing) for the tests.
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "${REPO_ROOT:-${here}/../..}" || exit 1
base="${BUMP_BASE:-testing}"
read -ra pins <<<"${BUMP_PINS:-scx extest ghostty chunkah brew builder}"  # BUMP_PINS: a subset, by hand or for the tests
summary() { echo "$*"; [[ -z "${GITHUB_STEP_SUMMARY:-}" ]] || echo "$*" >> "${GITHUB_STEP_SUMMARY}" || true; }

git fetch -q origin "${base}" || { echo "::error::cannot fetch ${base}"; exit 1; }
if [[ -z "${DRY_RUN:-}" && "$(git rev-parse HEAD)" != "$(git rev-parse "origin/${base}")" ]]; then
    echo "::error::a real run must start from origin/${base} (this checkout is not it); use dry_run to try another ref"; exit 1
fi
day=$(date -u +%Y%m%d); branch="bump/weekly-${day}"; n=1
while [[ -z "${DRY_RUN:-}" ]] && git ls-remote --exit-code --heads origin "${branch}" > /dev/null 2>&1; do n=$((n + 1)); branch="bump/weekly-${day}-${n}"; done
git checkout -q -b "${branch}" || exit 1

summary "## Pin bumps"
failed=0
for p in "${pins[@]}"; do "${here}/bump-run.sh" "${p}" || failed=1; done

supersede() { # a comment for every other open weekly PR, which is closed with its branch
    local num head
    gh pr list --base "${base}" --state open --json number,headRefName --jq '.[]|select(.headRefName|startswith("bump/weekly-"))|"\(.number) \(.headRefName)"' 2> /dev/null \
        | while read -r num head; do
            [[ "${head}" != "${branch}" ]] || continue
            gh pr close "${num}" --delete-branch --comment "$1" || echo "::warning::could not close #${num}"
        done
}
# the pin commits: those whose message ends with a table row (anything else on the branch, as on a dry run from a feature branch, is not a pin)
rows="" names="" list=""
for c in $(git rev-list --reverse --no-merges "origin/${base}..HEAD"); do
    row=$(git log -1 --format=%b "${c}" | sed -n 1p); [[ "${row}" == *" | "* ]] || continue
    names+="${names:+, }${row%% |*}"; rows+="| ${row} |"$'\n'; list+="- ${c:0:7} $(git log -1 --format=%s "${c}")"$'\n'
done
if [[ -z "${rows}" ]]; then
    summary "Nothing moved: no branch, no pull request."
    [[ -n "${DRY_RUN:-}" || "${failed}" != 0 ]] || supersede "No pin is pending any more (testing has them all): closing this weekly bump pull request."
    exit "${failed}"
fi
title="Weekly pin bumps $(date -u +%F): ${names}"
body="One commit per pin that moved. To drop a pin, revert its commit (\`git revert <commit>\`) or edit the pin; the other pins stay.

| pin | from | to | what changed upstream | days the new value has existed |
|---|---|---|---|---|
${rows}
Only pin lines change. Zig moves only inside the Ghostty commit (a Ghostty tag needs its Zig minor), never on its own. A builder bump rebuilds every binaries component once after the merge. Check the scheduler READMEs when scx moves. Not verified: nothing was built or booted by the bump; the checks below run the test suite on the branch tip, and the image build after the merge into \`${base}\` is the first build with these pins. The owner merges this pull request.

Checks: this commit is tested by the \`Test\` workflow (dispatched on \`${base}\` for it, because a pull request opened with the workflow token starts no workflow itself) and its \`test\` and \`secrets\` results are reported here as check runs. If they are missing, run the bump workflow again (\`gh workflow run bump-pins.yml --ref ${base}\`): it makes a new branch and pull request and closes this one."

if [[ -n "${DRY_RUN:-}" ]]; then
    summary "Dry run, nothing pushed. Branch ${branch}, title: ${title}"
    summary "Commits:"; summary "${list}"
    summary "${body}"
    exit "${failed}"
fi

git push -q origin "refs/heads/${branch}:refs/heads/${branch}" || { echo "::error::cannot push ${branch}"; exit 1; }
if ! url=$(gh pr create --base "${base}" --head "${branch}" --title "${title}" --body "${body}"); then
    echo "::error::Could not open the pull request. Is Settings, Actions, General, Allow GitHub Actions to create and approve pull requests, on?"; exit 1
fi
summary "Opened ${url}"
supersede "Superseded by ${url}: a newer weekly run started from current ${base} and re-applied every pending pin, so nothing here is lost."
"${here}/bump-checks.sh" "${branch}" "$(git rev-parse HEAD)" || true
exit "${failed}"
