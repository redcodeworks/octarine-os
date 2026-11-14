#!/usr/bin/env bash
# Check out the pinned upstream source and FAIL unless it is exactly the pinned commit.
#
#   fetch-source.sh <upstream.env> <dest-dir>
#
# Tag pin: fetch refs/tags/<tag> and require its commit (peeled, for annotated tags) to equal UPSTREAM_COMMIT, so a
# tag that was moved upstream cannot slip in. Commit pin (UPSTREAM_TAG empty, or UPSTREAM_WATCH differs from
# UPSTREAM_REPO, i.e. a fork whose tags may be missing and where the tag is only a label): fetch that commit and require it.
# UPSTREAM_BASE_URL (default https://github.com) exists for the tests, which use local repositories.
#
# Tarball pin (UPSTREAM_TARBALL_URL set; ghostty): the source is the publisher's signed release tarball, not a git checkout. The
# build fails unless the tag still resolves to exactly UPSTREAM_COMMIT (git ls-remote, peeled), the tarball's minisign signature
# verifies against UPSTREAM_MINISIGN_KEY AND its sha256 equals UPSTREAM_TARBALL_SHA256 (fetch-tarball.sh), and the VERSION file
# inside the tarball is the tag without its `v`.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=upstream-env.sh
source "${here}/upstream-env.sh"

envfile="${1:?upstream.env}"
dest="${2:?destination directory}"
upstream_env_load "${envfile}"

url="${UPSTREAM_BASE_URL:-https://github.com}/${UPSTREAM_REPO}.git"
if [[ -n "${UPSTREAM_TARBALL_URL}" ]]; then
    [[ -n "${UPSTREAM_TAG}" ]] || { echo "::error::a tarball pin needs UPSTREAM_TAG" >&2; exit 1; }
    version=${UPSTREAM_TAG#v}
    # the tag still points where the pin says: asks for the peeled ref first (annotated tag), then the plain one
    refs=$(git ls-remote "${url}" "refs/tags/${UPSTREAM_TAG}^{}" "refs/tags/${UPSTREAM_TAG}")
    got=$(awk '$2 ~ /\^\{\}$/ {print $1; exit}' <<<"${refs}")
    [[ -n "${got}" ]] || got=$(awk 'NR == 1 {print $1}' <<<"${refs}")
    if [[ "${got}" != "${UPSTREAM_COMMIT}" ]]; then
        echo "::error::${UPSTREAM_REPO} tag ${UPSTREAM_TAG} is '${got}', upstream.env pins ${UPSTREAM_COMMIT} (a moved tag? check before changing the pin)" >&2
        exit 1
    fi
    "${here}/fetch-tarball.sh" "${UPSTREAM_TARBALL_URL//@VERSION@/${version}}" "${UPSTREAM_TARBALL_SHA256}" "${UPSTREAM_MINISIGN_KEY}" "${dest}"
    [[ "$(cat "${dest}/VERSION" 2> /dev/null)" == "${version}" ]] || { echo "::error::the tarball's VERSION file is not ${version}" >&2; exit 1; }
    echo "source: ${UPSTREAM_REPO} tag ${UPSTREAM_TAG} -> ${got}, signed release tarball verified"
    exit 0
fi
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
