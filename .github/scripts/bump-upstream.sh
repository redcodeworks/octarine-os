#!/usr/bin/env bash
# Open or update the ONE bump pull request of a prebuilt component: branch bump/<name>, into testing.
#
#   bump-upstream.sh <component dir, for example binaries/scx> <new-tag> <new-commit>
#
# Changes only UPSTREAM_TAG and UPSTREAM_COMMIT in <dir>/upstream.env. If a PR for exactly this version is already
# open nothing happens. If one for an older version is open, the branch gets one more commit (never a force-push) and
# the PR title and body are updated. Never publishes anything: the merge into testing changes the tree hash of binaries/ and the build after it builds and signs the new binaries. Needs git (origin = this repository), gh and GH_TOKEN.
# Everything is done with the default GITHUB_TOKEN. Pushes and PRs made with it start no push or pull_request workflow, but
# workflow_dispatch is allowed, so after the push and the PR the `Test` workflow is dispatched on the bump branch
# (gh workflow run test.yml --ref bump/<name>); its checks `test` and `secrets` attach to the branch tip and so to the PR.
# UNVERIFIED on GitHub until the first real bump: whether a dispatched run satisfies the required checks on the PR.
# A failed dispatch is a warning, not a failure (the PR body says how to start the checks by hand).
# Committer identity comes from the environment (the workflow sets it); no commit trailers are added.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root="${REPO_ROOT:-$(cd "${here}/../.." && pwd)}"
# shellcheck source=../../binaries/lib/upstream-env.sh
source "${root}/binaries/lib/upstream-env.sh"

dir="${1:?component directory}"
new_tag="${2:?new tag}"
new_commit="${3:?new commit}"
base="${BUMP_BASE:-testing}"
name=$(basename "${dir}")
branch="bump/${name}"
file="${dir}/upstream.env"

cd "${root}"
upstream_env_load "${file}"
repo="${UPSTREAM_WATCH}"   # release notes and compare links point at the project that was followed
fork="${UPSTREAM_REPO}"
old_tag="${UPSTREAM_TAG}"
old_commit="${UPSTREAM_COMMIT}"
title="Bump ${name} to ${new_tag}"
fork_note=""
if [[ "${repo}" != "${fork}" ]]; then fork_note=" The build source is the fork \`${fork}\`: the pin is its commit \`${new_commit:0:7}\`, \`${new_tag}\` is only a label."; fi

open=$(gh pr list --head "${branch}" --base "${base}" --state open --json number,title --jq '.[0] // empty')
if [[ -n "${open}" && "$(jq -r .title <<<"${open}")" == "${title}" ]]; then
    echo "A bump PR for ${name} ${new_tag} is already open (#$(jq -r .number <<<"${open}")): nothing to do"
    exit 0
fi

git fetch -q origin
if git rev-parse -q --verify "origin/${branch}" > /dev/null; then
    git checkout -q -B "${branch}" "origin/${branch}"
    # testing may have moved on (even in upstream.env): take its content on conflicts, the bump is applied again below
    git merge -q --no-edit -X theirs "origin/${base}" || { echo "::error::cannot merge ${base} into ${branch}"; exit 1; }
else
    git checkout -q -B "${branch}" "origin/${base}"
fi
upstream_env_set "${file}" "${new_tag}" "${new_commit}"
git add -- "${file}"
if git diff --cached --quiet; then echo "${branch} already carries this pin"; else
    git commit -q -m "Bump ${name} to ${new_tag}: upstream released it; the build checks the tag still resolves to ${new_commit:0:7}"
fi
git push -q origin "refs/heads/${branch}:refs/heads/${branch}"

from=${old_tag:-${old_commit}}
body="Upstream ${repo} has a newer release than the pin of \`${name}\`.

- Pin: \`${old_tag:-commit ${old_commit:0:7}}\` to \`${new_tag}\` (commit \`${new_commit}\`)
- Release notes: https://github.com/${repo}/releases/tag/${new_tag}
- Changes: https://github.com/${repo}/compare/${from}...${new_tag}

Only \`${file}\` changes.${fork_note} The merge into \`${base}\` changes the tree hash of \`binaries/\`, so the build after it builds, signs and publishes the new binaries image; the build fails if the source does not resolve to the pinned commit. Check the scheduler READMEs when the scx pin moves (\`binaries/scx/schedulers.tsv\`). Not verified: nothing is built or run by this PR; a BPF scheduler can only be loaded on a real machine."
body+="

Checks: the upstream-check workflow dispatches the \`Test\` workflow on the branch \`${branch}\`, so \`test\` and \`secrets\` run on this PR's head commit. If they do not appear, start them by hand: \`gh workflow run test.yml --ref ${branch}\`. (Unverified until the first real bump: whether a dispatched run satisfies the required checks.)"

if [[ -n "${open}" ]]; then
    gh pr edit "$(jq -r .number <<<"${open}")" --title "${title}" --body "${body}"
    echo "Updated the open bump PR #$(jq -r .number <<<"${open}") to ${new_tag}"
else
    gh pr create --base "${base}" --head "${branch}" --title "${title}" --body "${body}"
fi

# start the required checks on the branch tip (events made with GITHUB_TOKEN start none by themselves)
if gh workflow run test.yml --ref "${branch}"; then
    echo "Dispatched the Test workflow on ${branch}"
else
    msg="Could not dispatch the Test workflow on ${branch}: start it by hand with: gh workflow run test.yml --ref ${branch}"
    echo "::warning::${msg}"
    [[ -z "${GITHUB_STEP_SUMMARY:-}" ]] || echo "- ${msg}" >> "${GITHUB_STEP_SUMMARY}"
fi
