#!/usr/bin/env bash
# Installs the package lists of ONE image kind: install-packages.sh <directory>, for example `install-packages.sh /ctx/packages`.
# The lists are plain text files in this repository (packages/default, packages/dx, packages/gx); the Containerfile of each image copies
# its directory into the build context. Moved here from the octarine-bins image on 2026-11-18 (its installer, same contract, same file names).
#
# Order: required first, then optional; inside a tier fedora, negativo17, copr. A missing file is skipped.
#   required-*.txt   STRICT: one dnf5 transaction per file (one install per entry for copr), any failure fails the build
#   optional-*.txt   BEST EFFORT: one transaction per file, retried once as a whole, then package by package; what still cannot be
#                    installed is printed as `OPTIONAL PACKAGE MISSING: <name>` and appended to MISSING_FILE (the smoke test warns for each)
# Sources: fedora = Fedora's own repositories; negativo17 = repository id fedora-multimedia, enabled for that call only;
#          copr (required only) = entries are `owner/project:name-version-release` (an exact version), enabled for that one install and disabled again.
# Entries: one token per line, blank lines and #-comments ignored; `name`, `name.arch`, `@group-id`, or `a|b` alternatives (the first
# one the repositories have is installed; none at all fails a required file and reports an optional one).
#
# Environment: MISSING_FILE=<path> (appended to, never truncated, so several runs add up), NO_CLEANUP=1 (skip the cache cleanup at the end).
set -eoux pipefail

echo "::group:: ===$(basename "$0")==="

dir=${1:?usage: install-packages.sh <directory with the lists>}
missing_file=${MISSING_FILE:-/dev/null}

# an entry without its comments and blanks
entries() { sed -e 's/[[:space:]]*#.*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e '/^$/d' "$1"; }

# true when a repository enabled for this call has the package (exact name)
exists() { # <name> <repo arg>... (the output is captured first: grep -q ending the pipe early would fail it under pipefail)
    local out; out=$(dnf5 -q repoquery "${@:2}" --available --latest-limit=1 --queryformat '%{name}\n' "$1") || return 1
    grep -Fxq -- "$1" <<< "${out}"
}

report_missing() { echo "OPTIONAL PACKAGE MISSING: $1"; echo "$1" >> "${missing_file}"; }

# resolve <required|optional> <repo arg>... : entries on stdin, the names to install on stdout. The alternatives `a|b` become the first that exists.
# (read into an array first: dnf5 inside a `while read` loop would eat the rest of stdin)
resolve() {
    local tier=$1 entry pick alt list alts; shift
    mapfile -t list
    for entry in "${list[@]}"; do
        IFS='|' read -r -a alts <<< "${entry}"
        pick=""
        if [[ "${#alts[@]}" -eq 1 ]]; then
            pick=${entry}
        else
            for alt in "${alts[@]}"; do if exists "${alt}" "$@"; then pick=${alt}; break; fi; done
        fi
        if [[ -n "${pick}" ]]; then echo "${pick}"
        elif [[ "${tier}" == required ]]; then echo "ERROR: none of the alternatives exists: ${entry}" >&2; exit 1
        else report_missing "${entry}" >&2
        fi
    done
}

# dnf_install <required|optional> <repo arg>... -- <package>...
dnf_install() {
    local tier=$1 args=(); shift
    while [[ "$1" != -- ]]; do args+=("$1"); shift; done; shift
    if [[ "${tier}" == required ]]; then dnf5 -y install --setopt=strict=1 "${args[@]}" "$@"; else dnf5 -y install "${args[@]}" "$@"; fi
}

# optional_install <repo arg>... -- <package>...: all at once, once more after a pause (a mirror hiccup), then one by one
optional_install() {
    local args=() pkg
    while [[ "$1" != -- ]]; do args+=("$1"); shift; done; shift
    [[ $# -gt 0 ]] || return 0
    dnf_install optional "${args[@]}" -- "$@" && return 0
    echo "WARNING: the optional list failed, retrying it once as a whole"
    sleep 20
    dnf5 clean expire-cache > /dev/null 2>&1 || true
    dnf_install optional "${args[@]}" -- "$@" && return 0
    echo "WARNING: the optional list failed twice, retrying its packages one by one"
    for pkg in "$@"; do dnf_install optional "${args[@]}" -- "${pkg}" || report_missing "${pkg}"; done
}

# copr <file>: per entry enable the COPR, install the one package strictly, disable the COPR (required only: there is no optional copr list)
copr() {
    local entry repo pkg list
    mapfile -t list < <(entries "$1")
    for entry in "${list[@]}"; do
        [[ "${entry}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+:.+-[0-9][^-]*-[0-9][^-]*$ ]] || { echo "ERROR: '${entry}' is not owner/project:name-version-release"; exit 1; }
        repo=${entry%%:*}; pkg=${entry#*:}
        dnf5 -y copr enable "${repo}"
        dnf_install required -- "${pkg}"
        dnf5 -y copr disable "${repo}"
    done
}

for tier in required optional; do
    for source in fedora negativo17 copr; do
        file=${dir}/${tier}-${source}.txt
        [[ -f "${file}" ]] || continue
        [[ -n "$(entries "${file}")" ]] || continue
        repo_args=()
        [[ "${source}" != negativo17 ]] || repo_args=(--enable-repo=fedora-multimedia)
        if [[ "${source}" == copr ]]; then
            [[ "${tier}" == required ]] || { echo "ERROR: ${file}: there is no optional copr list"; exit 1; }
            copr "${file}"
            continue
        fi
        # (a command substitution, not mapfile < <(...): a failing resolve must fail the build)
        resolved=$(entries "${file}" | resolve "${tier}" "${repo_args[@]}")
        mapfile -t pkgs <<< "${resolved}"
        if [[ "${tier}" == required ]]; then dnf_install required "${repo_args[@]}" -- "${pkgs[@]}"; else optional_install "${repo_args[@]}" -- "${pkgs[@]}"; fi
    done
done

echo "== optional packages missing:"
cat "${missing_file}"

# The dnf caches are cache mounts of the build; this only removes what would otherwise travel (dnf logs hold mirror URLs, root's leftovers)
if [[ "${NO_CLEANUP:-}" != 1 ]]; then
    dnf5 clean all
    rm -rf /var/cache/libdnf5 /var/cache/dnf /var/log/dnf5.log* /var/log/dnf.log* /root/.ssh /root/.viminfo /root/.cache /root/.local/share/wget /root/.wget-hsts
fi

echo "::endgroup::"
