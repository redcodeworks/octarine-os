#!/usr/bin/env bash
# Ask upstream whether a prebuilt component (binaries/<name>) has something newer than its pin, and print ONE decision line:
#
#   upstream-check.sh <component dir, for example binaries/scx>
#
#   current <what>             nothing newer (pinned tag is the latest release, or the pin is ahead of it)
#   bump <tag> <commit>        a newer release exists: <tag> and the commit it resolves to (peeled for annotated tags)
#   report <text>              commit-pinned project without a release or tag ahead of the pin: nothing to open
#   forkbehind <tag> <commit>  upstream has a newer release but our fork (UPSTREAM_REPO) does not contain its commit yet:
#                              no bump PR; Kevin syncs the fork (`gh repo sync <fork>`) and the next run opens it
#   unreachable <text>         upstream could not be asked; fail soft (exit 0), the next weekly run tries again
#
# Reads upstream.env (UPSTREAM_REPO, UPSTREAM_WATCH, UPSTREAM_TAG, UPSTREAM_COMMIT). Releases are asked of UPSTREAM_WATCH
# (the real project); when that differs from UPSTREAM_REPO the build source is our fork, the pin is a commit and a bump needs
# the fork to contain the new commit. Tag pin: the latest release (not a draft or
# pre-release) is newer when it sorts above the pinned tag by version. Commit pin (empty UPSTREAM_TAG): the latest
# release, else the newest tag, counts only when it is NOT an ancestor of (or equal to) the pinned commit (compare API status ahead or
# diverged), so a release behind the pin, such as the one extest's pin sits one commit after, is never "newer". Only `gh api` reads; nothing is written.
# shellcheck disable=SC2015  # the `A && B || C` form is used on purpose: C is the fail-soft answer
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../binaries/lib/upstream-env.sh
source "${here}/../../binaries/lib/upstream-env.sh"
root="${REPO_ROOT:-$(cd "${here}/../.." && pwd)}"

dir="${1:?component directory}"
upstream_env_load "${root}/${dir}/upstream.env" || { echo "unreachable invalid ${dir}/upstream.env"; exit 0; }
repo="${UPSTREAM_WATCH}"   # where releases are looked up
fork="${UPSTREAM_REPO}"     # where the build clones from (the same unless it is a fork)

latest=$(gh api "repos/${repo}/releases/latest" --jq .tag_name 2> /dev/null) || latest=""
if [[ -z "${latest}" && ( -z "${UPSTREAM_TAG}" || "${repo}" != "${fork}" ) ]]; then
    # a commit-pinned project may have tags but no release object
    if ! tags=$(gh api "repos/${repo}/tags" --jq '.[0].name // ""' 2> /dev/null); then
        echo "unreachable cannot read releases or tags of ${repo}"
        exit 0
    fi
    latest=${tags}
fi
if [[ -z "${latest}" ]]; then
    if [[ -n "${UPSTREAM_TAG}" && "${repo}" == "${fork}" ]]; then echo "unreachable cannot read the latest release of ${repo}"; else echo "report ${repo} has no release or tag; pinned at ${UPSTREAM_COMMIT:0:7}"; fi
    exit 0
fi

commit_of() { gh api "repos/${repo}/commits/$1" --jq .sha 2> /dev/null; }

if [[ -n "${UPSTREAM_TAG}" && "${repo}" == "${fork}" ]]; then
    if [[ "${latest}" == "${UPSTREAM_TAG}" ]]; then echo "current ${UPSTREAM_TAG} is the latest release"; exit 0; fi
    top=$(printf '%s\n%s\n' "${UPSTREAM_TAG}" "${latest}" | sort -V | tail -n1)
    if [[ "${top}" != "${latest}" ]]; then echo "current pinned ${UPSTREAM_TAG} is ahead of the latest release ${latest}"; exit 0; fi
    commit=$(commit_of "${latest}") && [[ "${commit}" =~ ^[0-9a-f]{40}$ ]] || { echo "unreachable cannot resolve ${repo} ${latest} to a commit"; exit 0; }
    echo "bump ${latest} ${commit}"
    exit 0
fi

if [[ "${repo}" != "${fork}" && "${latest}" == "${UPSTREAM_TAG}" ]]; then echo "current ${UPSTREAM_TAG} is the latest release"; exit 0; fi
commit=$(commit_of "${latest}") && [[ "${commit}" =~ ^[0-9a-f]{40}$ ]] || { echo "unreachable cannot resolve ${repo} ${latest} to a commit"; exit 0; }
status=$(gh api "repos/${repo}/compare/${UPSTREAM_COMMIT}...${commit}" --jq .status 2> /dev/null) || { echo "unreachable cannot compare ${repo} ${UPSTREAM_COMMIT:0:7} with ${latest}"; exit 0; }
case "${status}" in
    ahead | diverged)
        if [[ "${repo}" == "${fork}" ]]; then echo "bump ${latest} ${commit}"; exit 0; fi
        # a fork: only bump when it already contains the commit (compare the new commit with the fork's default branch;
        # asking the commits API would also find commits that only exist elsewhere in the fork network)
        branch=$(gh api "repos/${fork}" --jq .default_branch 2> /dev/null) || { echo "unreachable cannot read ${fork}"; exit 0; }
        fstatus=$(gh api "repos/${fork}/compare/${commit}...${branch}" --jq .status 2> /dev/null) || fstatus=missing
        case "${fstatus}" in
            ahead | identical) echo "bump ${latest} ${commit}" ;;
            *) echo "forkbehind ${latest} ${commit} the fork ${fork} is behind ${repo}: ${latest} is not in ${fork}/${branch}" ;;
        esac
        ;;
    identical) echo "current the pinned commit is ${latest}" ;;
    *) echo "report latest release ${latest} is ${status} of the pinned commit ${UPSTREAM_COMMIT:0:7}; nothing to bump" ;;
esac
