#!/usr/bin/env bash
# Parser for binaries/<name>/upstream.env, the pin of one prebuilt component. Source this file:
#
#   source binaries/lib/upstream-env.sh
#   upstream_env_load <name>/upstream.env     sets UPSTREAM_REPO, UPSTREAM_WATCH, UPSTREAM_TAG, UPSTREAM_COMMIT or returns 1
#   upstream_env_set  <file> <tag> <commit>    rewrites the two pin lines in place (a bump)
#
# Format: KEY=VALUE lines, `#` comments and blank lines allowed, nothing else (the file is parsed, never sourced).
#   UPSTREAM_REPO    owner/name on github.com: the repository the build clones (our fork, for extest)
#   UPSTREAM_WATCH   owner/name the weekly check asks for new releases; default UPSTREAM_REPO. When it differs from
#                    UPSTREAM_REPO the build source is a fork: the pin is the commit and UPSTREAM_TAG is only a label
#   UPSTREAM_TAG     the release tag; empty for a project pinned by commit only
#   UPSTREAM_COMMIT  the 40-hex commit the pin must resolve to (for an annotated tag: the peeled commit)

upstream_env_load() {
    local file=$1 line key val seen=" "
    UPSTREAM_REPO="" UPSTREAM_WATCH="" UPSTREAM_TAG="" UPSTREAM_COMMIT=""
    [[ -f "${file}" ]] || { echo "upstream.env: not found: ${file}" >&2; return 1; }
    while IFS= read -r line || [[ -n "${line}" ]]; do
        line=${line%%#*}
        line=${line#"${line%%[![:space:]]*}"}
        line=${line%"${line##*[![:space:]]}"}
        [[ -n "${line}" ]] || continue
        if [[ ! "${line}" =~ ^([A-Z_]+)=(.*)$ ]]; then
            echo "upstream.env: not KEY=VALUE: '${line}'" >&2
            return 1
        fi
        key=${BASH_REMATCH[1]}
        val=${BASH_REMATCH[2]}
        val=${val#[\"\']}
        val=${val%[\"\']}
        case "${key}" in
            UPSTREAM_REPO | UPSTREAM_WATCH | UPSTREAM_TAG | UPSTREAM_COMMIT) ;;
            *) echo "upstream.env: unknown key ${key}" >&2; return 1 ;;
        esac
        [[ "${seen}" != *" ${key} "* ]] || { echo "upstream.env: ${key} appears twice" >&2; return 1; }
        seen+="${key} "
        printf -v "${key}" '%s' "${val}"
    done < "${file}"
    [[ "${UPSTREAM_REPO}" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || { echo "upstream.env: UPSTREAM_REPO must be owner/name (got '${UPSTREAM_REPO}')" >&2; return 1; }
    [[ -n "${UPSTREAM_WATCH}" ]] || UPSTREAM_WATCH=${UPSTREAM_REPO}
    [[ "${UPSTREAM_WATCH}" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || { echo "upstream.env: UPSTREAM_WATCH must be owner/name (got '${UPSTREAM_WATCH}')" >&2; return 1; }
    [[ -z "${UPSTREAM_TAG}" || "${UPSTREAM_TAG}" =~ ^[A-Za-z0-9._+-]+$ ]] || { echo "upstream.env: bad UPSTREAM_TAG '${UPSTREAM_TAG}'" >&2; return 1; }
    [[ "${UPSTREAM_COMMIT}" =~ ^[0-9a-f]{40}$ ]] || { echo "upstream.env: UPSTREAM_COMMIT must be 40 lowercase hex characters (got '${UPSTREAM_COMMIT}')" >&2; return 1; }
}

upstream_env_set() { # file tag commit
    local file=$1 tag=$2 commit=$3
    [[ "${tag}" =~ ^[A-Za-z0-9._+-]*$ && "${commit}" =~ ^[0-9a-f]{40}$ ]] || { echo "upstream_env_set: bad tag or commit" >&2; return 1; }
    sed -i -e "s/^UPSTREAM_TAG=.*/UPSTREAM_TAG=${tag}/" -e "s/^UPSTREAM_COMMIT=.*/UPSTREAM_COMMIT=${commit}/" "${file}"
    upstream_env_load "${file}" && [[ "${UPSTREAM_TAG}" == "${tag}" && "${UPSTREAM_COMMIT}" == "${commit}" ]]
}
