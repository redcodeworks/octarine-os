#!/usr/bin/env bash
# The plumbing every bump job shares: ONE pull request per pin, on the branch bump/<name>, into testing, created or updated in place, with only the
# pin lines changed, and the Test workflow dispatched on the branch (events made with GITHUB_TOKEN start no workflow, workflow_dispatch is the exception:
# the run tests that commit from the testing ref and bump-checks.sh reports `test` and `secrets` on it, because a run dispatched on the branch does not count for the pull request). The DECISION (what is newer, signatures, tag rules) stays in the
# decision scripts, which differ per kind of pin.
#
#   bump-pr.sh --branch bump/<name> --title <title> --body-file <file> --message <commit message> --file <pin file> [--file ...] -- <writer command...>
#
# The writer command is run AFTER the branch is checked out and current, in the repository root; it writes the pin (and nothing else). The script then
# refuses to continue when a file other than the --file ones changed, commits those files, pushes (never forced), and creates or updates the PR.
#   - an open PR on that branch with exactly this title: nothing happens ("already open for this exact version");
#   - an open PR with another title (an older version): the branch gets one more commit, the title and body are updated, never a force-push;
#   - an existing branch without a PR: it is brought current (testing merged in, `-X theirs`) and a PR is opened;
#   - the writer changes nothing (the branch already carries the pin): no commit, the PR is still created or updated.
# Output (stdout, and GITHUB_OUTPUT when set): action=opened|updated|noop, pr_number, pr_url. A failed Test dispatch is a warning (the PR body says
# how to start the checks by hand). Needs: git (origin = this repository), gh with GH_TOKEN. Committer identity comes from the environment; no trailers.
# BUMP_BASE (default testing) and REPO_ROOT exist for the tests.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# This script checks out the bump branch (and its older copy of every script) while it runs, which would swap the files it and bump-checks.sh are
# executed from (found 2026-11-15: the repair path ran the old bump-checks.sh of the branch). Run from a private copy of both, with REPO_ROOT fixed.
if [[ -z "${BUMP_PR_COPY:-}" ]]; then
    export REPO_ROOT="${REPO_ROOT:-$(cd "${here}/../.." && pwd)}"
    copy=$(mktemp -d)
    cp "${here}/bump-pr.sh" "${here}/bump-checks.sh" "${copy}/"
    BUMP_PR_COPY=1 exec bash "${copy}/bump-pr.sh" "$@"
fi
root="${REPO_ROOT:-$(cd "${here}/../.." && pwd)}"
base="${BUMP_BASE:-testing}"
branch="" title="" bodyfile="" message="" files=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --branch) branch=$2; shift 2 ;;
        --title) title=$2; shift 2 ;;
        --body-file) bodyfile=$2; shift 2 ;;
        --message) message=$2; shift 2 ;;
        --file) files+=("$2"); shift 2 ;;
        --) shift; break ;;
        *) echo "bump-pr.sh: unknown argument $1" >&2; exit 2 ;;
    esac
done
[[ "${branch}" == bump/* && -n "${title}" && -f "${bodyfile}" && -n "${message}" && ${#files[@]} -gt 0 && $# -gt 0 ]] || { echo "bump-pr.sh: --branch bump/<name>, --title, --body-file, --message, --file and a writer command are required" >&2; exit 2; }
emit() { echo "$1=$2"; [[ -z "${GITHUB_OUTPUT:-}" ]] || echo "$1=$2" >> "${GITHUB_OUTPUT}" || true; }
cd "${root}"

open=$(gh pr list --head "${branch}" --base "${base}" --state open --json number,title --jq '.[0] // empty')
if [[ -n "${open}" && "$(jq -r .title <<<"${open}")" == "${title}" ]]; then
    n=$(jq -r .number <<<"${open}")
    echo "A bump PR \"${title}\" is already open (#${n}): nothing to do"
    # repair path: a PR whose required checks are missing (an earlier run was cancelled, or its commit already had a check suite of its own) gets an empty
    # commit and the checks again: only a commit WITHOUT a GitHub Actions suite can take reported checks that count
    cnt=$(gh pr view "${n}" --json statusCheckRollup --jq '[.statusCheckRollup[]?|select(.name=="test")]|length' 2> /dev/null || true)
    if [[ "${cnt}" == 0 ]]; then
        git fetch -q origin
        tip=$(git rev-parse "origin/${branch}")
        # a tip without any GitHub Actions check suite takes the reported checks as it is (an earlier repair commit); one that has a suite needs a new commit
        suites=$(gh api "repos/${GITHUB_REPOSITORY:-}/commits/${tip}/check-suites" --jq '[.check_suites[]|select(.app.slug=="github-actions")]|length' 2> /dev/null || true)
        if [[ "${suites}" != 0 ]]; then
            git checkout -q -B "${branch}" "origin/${branch}"
            git commit -q --allow-empty -m "Re-run the checks of this bump (the earlier ones did not count for the pull request)"
            git push -q origin "refs/heads/${branch}:refs/heads/${branch}"
            tip=$(git rev-parse HEAD)
        fi
        "${here}/bump-checks.sh" "${branch}" "${tip}" || true
    fi
    emit action noop; emit pr_number "${n}"; emit pr_url ""
    exit 0
fi

git fetch -q origin
if git rev-parse -q --verify "origin/${branch}" > /dev/null; then
    git checkout -q -B "${branch}" "origin/${branch}"
    # testing may have moved on (even in a pin file): take its content on conflicts, the writer applies the pin again
    git merge -q --no-edit -X theirs "origin/${base}" || { echo "::error::cannot merge ${base} into ${branch}"; exit 1; }
else
    git checkout -q -B "${branch}" "origin/${base}"
fi
"$@"
changed=$(git diff --name-only | sort -u)
for f in ${changed}; do
    ok=0; for a in "${files[@]}"; do [[ "${f}" == "${a}" ]] && ok=1; done
    [[ "${ok}" == 1 ]] || { echo "::error::the writer changed ${f}, which is not one of the pin files (${files[*]})"; git checkout -q -- .; exit 1; }
done
git add -- "${files[@]}"
pushed=false
if git diff --cached --quiet; then
    echo "${branch} already carries this pin"
else
    git commit -q -m "${message}"
    pushed=true
fi
git push -q origin "refs/heads/${branch}:refs/heads/${branch}"

body=$(cat "${bodyfile}")
body+="

Checks: the bump workflow tests this commit (the \`Test\` workflow, dispatched on \`testing\` for it), waits for the run and reports its \`test\` and \`secrets\` results to this PR as check runs (a run dispatched on the branch itself would not count for the required checks). If they do not appear, run the bump workflow again (\`gh workflow run bump-pins.yml --ref testing\`: an open bump PR without its checks gets a new commit and the checks then); the tests alone can be started with: \`gh workflow run test.yml --ref testing -f ref=<the head commit sha>\`."
if [[ -n "${open}" ]]; then
    n=$(jq -r .number <<<"${open}")
    gh pr edit "${n}" --title "${title}" --body "${body}"
    url=$(gh pr view "${n}" --json url --jq .url 2> /dev/null || true)
    echo "Updated the open bump PR #${n}"
    emit action updated; emit pr_number "${n}"; emit pr_url "${url}"
else
    if ! url=$(gh pr create --base "${base}" --head "${branch}" --title "${title}" --body "${body}"); then
        echo "::error::Could not open the pull request. Is Settings, Actions, General, Allow GitHub Actions to create and approve pull requests, on?"
        exit 1
    fi
    echo "${url}"
    emit action opened; emit pr_number "${url##*/}"; emit pr_url "${url}"
fi
# the Test run of this commit and its reported checks (a dispatched run on the branch alone is not counted by the PR; bump-checks.sh explains)
"${here}/bump-checks.sh" "${branch}" "$(git rev-parse HEAD)" || true
