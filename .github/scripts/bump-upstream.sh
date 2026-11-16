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

body="Upstream ${repo} has a newer release than the pin of \`${name}\`.

- Pin: \`${old_tag:-commit ${old_commit:0:7}}\` to \`${new_tag}\` (commit \`${new_commit}\`)
- Release notes: https://github.com/${repo}/releases/tag/${new_tag}
- Changes: https://github.com/${repo}/compare/${old_tag:-${old_commit}}...${new_tag}

Only \`${file}\` changes.${fork_note} The merge into \`${base}\` changes the content key of this component, so the build after it builds, signs and publishes the new component image and the binaries image assembled from it; the build fails if the source does not resolve to the pinned commit. Check the scheduler READMEs when the scx pin moves (\`binaries/scx/schedulers.tsv\`). Not verified: nothing is built or run by this PR; a BPF scheduler can only be loaded on a real machine."
bodyfile=$(mktemp); trap 'rm -f "${bodyfile}"' EXIT
printf '%s\n' "${body}" > "${bodyfile}"
BUMP_BASE="${base}" REPO_ROOT="${root}" "${here}/bump-pr.sh" --branch "${branch}" --title "${title}" --body-file "${bodyfile}" \
    --message "Bump ${name} to ${new_tag}: upstream released it; the build checks the tag still resolves to ${new_commit:0:7}" --file "${file}" -- bash -c "source '${root}/binaries/lib/upstream-env.sh'; upstream_env_set '${file}' '${new_tag}' '${new_commit}'"
