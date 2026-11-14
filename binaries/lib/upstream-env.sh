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
# Optional keys, used by a project that publishes no GitHub releases and signs a source tarball (ghostty):
#   UPSTREAM_TAG_REGEX       extended regex the weekly check applies to the tag names of UPSTREAM_WATCH (instead of asking for the
#                            latest release); the highest match by version is the newest release (`^v[0-9]+\.[0-9]+\.[0-9]+$`
#                            skips pre-release, `vt-*` and `tip` tags)
#   UPSTREAM_TARBALL_URL     where the signed source tarball is; `@VERSION@` stands for UPSTREAM_TAG without its leading `v`.
#                            Set: the build takes the source from it (fetch-source.sh) and `<url>.minisig` must verify
#   UPSTREAM_TARBALL_SHA256  the 64-hex sha256 the tarball must have (empty means not pinned yet: the build fails)
#   UPSTREAM_MINISIGN_KEY    the minisign public key (base64, starts with RW) the signature must verify against
#   ZIG_VERSION, ZIG_URL, ZIG_SHA256, ZIG_MINISIGN_KEY   the same three facts for the Zig toolchain the build needs
#                            (`@VERSION@` in ZIG_URL stands for ZIG_VERSION)

upstream_env_load() {
    local file=$1 line key val seen=" "
    UPSTREAM_REPO="" UPSTREAM_WATCH="" UPSTREAM_TAG="" UPSTREAM_COMMIT=""
    UPSTREAM_TAG_REGEX="" UPSTREAM_TARBALL_URL="" UPSTREAM_TARBALL_SHA256="" UPSTREAM_MINISIGN_KEY=""
    ZIG_VERSION="" ZIG_URL="" ZIG_SHA256="" ZIG_MINISIGN_KEY=""
    [[ -f "${file}" ]] || { echo "upstream.env: not found: ${file}" >&2; return 1; }
    while IFS= read -r line || [[ -n "${line}" ]]; do
        line=${line%%#*}
        line=${line#"${line%%[![:space:]]*}"}
        line=${line%"${line##*[![:space:]]}"}
        [[ -n "${line}" ]] || continue
        if [[ ! "${line}" =~ ^([A-Z0-9_]+)=(.*)$ ]]; then
            echo "upstream.env: not KEY=VALUE: '${line}'" >&2
            return 1
        fi
        key=${BASH_REMATCH[1]}
        val=${BASH_REMATCH[2]}
        val=${val#[\"\']}
        val=${val%[\"\']}
        case "${key}" in
            UPSTREAM_REPO | UPSTREAM_WATCH | UPSTREAM_TAG | UPSTREAM_COMMIT) ;;
            UPSTREAM_TAG_REGEX | UPSTREAM_TARBALL_URL | UPSTREAM_TARBALL_SHA256 | UPSTREAM_MINISIGN_KEY) ;;
            ZIG_VERSION | ZIG_URL | ZIG_SHA256 | ZIG_MINISIGN_KEY) ;;
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
    local sha_re='^[0-9a-f]{64}$' key_re='^RW[A-Za-z0-9+/]{54}$' url_re='^https://[A-Za-z0-9._/@%+~-]+$'
    [[ -z "${UPSTREAM_TARBALL_SHA256}" || "${UPSTREAM_TARBALL_SHA256}" =~ ${sha_re} ]] || { echo "upstream.env: UPSTREAM_TARBALL_SHA256 must be 64 lowercase hex characters or empty" >&2; return 1; }
    [[ -z "${ZIG_SHA256}" || "${ZIG_SHA256}" =~ ${sha_re} ]] || { echo "upstream.env: ZIG_SHA256 must be 64 lowercase hex characters or empty" >&2; return 1; }
    [[ -z "${UPSTREAM_MINISIGN_KEY}" || "${UPSTREAM_MINISIGN_KEY}" =~ ${key_re} ]] || { echo "upstream.env: UPSTREAM_MINISIGN_KEY is not a minisign public key" >&2; return 1; }
    [[ -z "${ZIG_MINISIGN_KEY}" || "${ZIG_MINISIGN_KEY}" =~ ${key_re} ]] || { echo "upstream.env: ZIG_MINISIGN_KEY is not a minisign public key" >&2; return 1; }
    [[ -z "${UPSTREAM_TARBALL_URL}" || "${UPSTREAM_TARBALL_URL}" =~ ${url_re} ]] || { echo "upstream.env: UPSTREAM_TARBALL_URL must be an https URL" >&2; return 1; }
    [[ -z "${ZIG_URL}" || "${ZIG_URL}" =~ ${url_re} ]] || { echo "upstream.env: ZIG_URL must be an https URL" >&2; return 1; }
    [[ -z "${ZIG_VERSION}" || "${ZIG_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "upstream.env: ZIG_VERSION must be MAJOR.MINOR.PATCH" >&2; return 1; }
    [[ -z "${UPSTREAM_TAG_REGEX}" || "${UPSTREAM_TAG_REGEX}" =~ ^[][A-Za-z0-9.^$+*?\\|_-]+$ ]] || { echo "upstream.env: bad UPSTREAM_TAG_REGEX" >&2; return 1; }
    return 0
}

# upstream_env_set_key <file> <KEY> <value>: rewrites ONE existing KEY=VALUE line (the key must be in the file already)
upstream_env_set_key() {
    local file=$1 key=$2 val=$3
    [[ "${key}" =~ ^[A-Z0-9_]+$ && "${val}" =~ ^[A-Za-z0-9+/._@%:~-]*$ ]] || { echo "upstream_env_set_key: bad key or value" >&2; return 1; }
    grep -q "^${key}=" "${file}" || { echo "upstream_env_set_key: ${key} is not in ${file}" >&2; return 1; }
    sed -i "s|^${key}=.*|${key}=${val}|" "${file}"
    upstream_env_load "${file}" && [[ "${!key}" == "${val}" ]]
}

upstream_env_set() { # file tag commit
    local file=$1 tag=$2 commit=$3
    [[ "${tag}" =~ ^[A-Za-z0-9._+-]*$ && "${commit}" =~ ^[0-9a-f]{40}$ ]] || { echo "upstream_env_set: bad tag or commit" >&2; return 1; }
    sed -i -e "s/^UPSTREAM_TAG=.*/UPSTREAM_TAG=${tag}/" -e "s/^UPSTREAM_COMMIT=.*/UPSTREAM_COMMIT=${commit}/" "${file}"
    upstream_env_load "${file}" && [[ "${UPSTREAM_TAG}" == "${tag}" && "${UPSTREAM_COMMIT}" == "${commit}" ]]
}
