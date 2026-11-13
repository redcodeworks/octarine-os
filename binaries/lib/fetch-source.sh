#!/usr/bin/env bash
# Check out the pinned upstream source and FAIL unless it is exactly the pinned commit.
#
#   fetch-source.sh <upstream.env> <dest-dir>
#
# Tag pin: fetch refs/tags/<tag> and require its commit (peeled, for annotated tags) to equal UPSTREAM_COMMIT, so a
# tag that was moved upstream cannot slip in. Commit pin (UPSTREAM_TAG empty, or UPSTREAM_WATCH differs from
# UPSTREAM_REPO, i.e. a fork whose tags may be missing and where the tag is only a label): fetch that commit and require it.
# UPSTREAM_BASE_URL (default https://github.com) exists for the tests, which use local repositories.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=upstream-env.sh
source "${here}/upstream-env.sh"

envfile="${1:?upstream.env}"
dest="${2:?destination directory}"
upstream_env_load "${envfile}"

url="${UPSTREAM_BASE_URL:-https://github.com}/${UPSTREAM_REPO}.git"
git init -q "${dest}"
git -C "${dest}" remote add origin "${url}"
if [[ -n "${UPSTREAM_TAG}" && "${UPSTREAM_WATCH}" == "${UPSTREAM_REPO}" ]]; then
    git -C "${dest}" fetch -q --depth 1 origin "refs/tags/${UPSTREAM_TAG}:refs/tags/${UPSTREAM_TAG}"
    got=$(git -C "${dest}" rev-parse "refs/tags/${UPSTREAM_TAG}^{commit}")
    what="tag ${UPSTREAM_TAG}"
else
    git -C "${dest}" fetch -q --depth 1 origin "${UPSTREAM_COMMIT}"
    got=$(git -C "${dest}" rev-parse "FETCH_HEAD^{commit}")
    what="commit ${UPSTREAM_COMMIT}"
fi
if [[ "${got}" != "${UPSTREAM_COMMIT}" ]]; then
    echo "::error::${UPSTREAM_REPO} ${what} is ${got}, upstream.env pins ${UPSTREAM_COMMIT} (a moved tag? check before changing the pin)" >&2
    exit 1
fi
git -C "${dest}" checkout -q --detach "${got}"
echo "source: ${UPSTREAM_REPO} ${what} -> ${got}"
