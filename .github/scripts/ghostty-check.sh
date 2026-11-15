#!/usr/bin/env bash
# Ask upstream whether Ghostty (binaries/ghostty) or its Zig toolchain has something newer than the pins, and print ONE decision line:
#
#   ghostty-check.sh
#
#   current <what>                                      nothing to do
#   bump <tag> <commit> <zig-version> <url> <sha256> <size>   a newer STABLE Ghostty tag (v<major>.<minor>.<patch> only: not tip, not vt-*, not a
#                                                       pre-release) with its peeled commit, and the Zig release that goes with it
#   zigbump <zig-version> <url> <sha256> <size>         same Ghostty tag, a newer patch of the PINNED Zig minor (a separate low-priority pull request)
#   wait <tag> <text>                                   a newer Ghostty tag exists but ziglang.org has no published x86_64-linux tarball of the Zig minor
#                                                       it needs yet: nothing is opened (the job summary says so); the next weekly run tries again
#   unreachable <text>                                  something could not be asked or read; fail soft (exit 0)
#
# The Zig MINOR follows from the Ghostty tag, never independently: for a new tag the minimum is read from `.minimum_zig_version` in that tag's
# build.zig.zon (gh api), the newest published patch of that minor comes from ziglang.org/download/index.json (x86_64-linux tarball, shasum, size).
# Ghostty's build (src/build/zig.zig requireZig) accepts the same major.minor with any patch >= the minimum, so a newer patch of the pinned minor is
# allowed; it is checked against the minimum at the PINNED tag. Reads upstream.env and zig.env of binaries/ghostty. Overrides for the tests: REPO_ROOT,
# ZIG_INDEX_FILE (a local copy of index.json, else downloaded with curl). Only `gh api` GET reads; nothing is written.
# shellcheck disable=SC2015
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../../binaries/lib/upstream-env.sh
source "${here}/../../binaries/lib/upstream-env.sh"
root="${REPO_ROOT:-$(cd "${here}/../.." && pwd)}"
dir="${root}/binaries/ghostty"

upstream_env_load "${dir}/upstream.env" || { echo "unreachable invalid binaries/ghostty/upstream.env"; exit 0; }
repo="${UPSTREAM_WATCH}"
pin_tag="${UPSTREAM_TAG}"
pin_zig=$(sed -n 's/^ZIG_VERSION=//p' "${dir}/zig.env" 2> /dev/null)
[[ "${pin_zig}" =~ ^0\.[0-9]+\.[0-9]+$ && "${pin_tag}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "unreachable the pins in binaries/ghostty are not release versions (tag '${pin_tag}', zig '${pin_zig}')"; exit 0; }

tags=$(gh api --paginate "repos/${repo}/tags?per_page=100" --jq '.[].name' 2> /dev/null) || { echo "unreachable cannot read the tags of ${repo}"; exit 0; }
latest=$(grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' <<<"${tags}" | sort -V | tail -n1)
[[ -n "${latest}" ]] || { echo "unreachable ${repo} has no stable v<major>.<minor>.<patch> tag"; exit 0; }

if [[ -n "${ZIG_INDEX_FILE:-}" ]]; then index=$(cat "${ZIG_INDEX_FILE}" 2> /dev/null) || index=""; else index=$(curl -fsSL --retry 2 https://ziglang.org/download/index.json 2> /dev/null) || index=""; fi
jq -e . > /dev/null 2>&1 <<<"${index}" || { echo "unreachable cannot read https://ziglang.org/download/index.json"; exit 0; }

min_zig_at() { # tag -> minimum_zig_version of that tag's build.zig.zon
    gh api "repos/${repo}/contents/build.zig.zon?ref=$1" --jq .content 2> /dev/null | base64 -d 2> /dev/null | sed -n 's/.*\.minimum_zig_version *= *"\([0-9][0-9.]*\)".*/\1/p' | head -n1
}
newest_patch() { # minor like 0.17 -> newest published patch version with an x86_64-linux tarball, or empty
    jq -r --arg m "$1" 'to_entries[] | select((.key | test("^" + ($m | gsub("\\."; "\\.")) + "\\.[0-9]+$")) and (.value["x86_64-linux"].tarball // "") != "") | .key' <<<"${index}" | sort -V | tail -n1
}
entry() { # version -> "url sha256 size", only when the URL is the official one (what fetch-zig.sh requires)
    local v=$1 url sha size
    url=$(jq -r --arg v "${v}" '.[$v]["x86_64-linux"].tarball // ""' <<<"${index}")
    sha=$(jq -r --arg v "${v}" '.[$v]["x86_64-linux"].shasum // ""' <<<"${index}")
    size=$(jq -r --arg v "${v}" '.[$v]["x86_64-linux"].size // "" | tostring' <<<"${index}")
    [[ "${url}" == "https://ziglang.org/download/${v}/zig-x86_64-linux-${v}.tar.xz" && "${sha}" =~ ^[0-9a-f]{64}$ && "${size}" =~ ^[0-9]+$ ]] || return 1
    echo "${url} ${sha} ${size}"
}

top=$(printf '%s\n%s\n' "${pin_tag}" "${latest}" | sort -V | tail -n1)
if [[ "${latest}" != "${pin_tag}" && "${top}" == "${latest}" ]]; then
    commit=$(gh api "repos/${repo}/commits/${latest}" --jq .sha 2> /dev/null) && [[ "${commit}" =~ ^[0-9a-f]{40}$ ]] || { echo "unreachable cannot resolve ${repo} ${latest} to a commit"; exit 0; }
    min=$(min_zig_at "${latest}")
    [[ "${min}" =~ ^0\.[0-9]+\.[0-9]+$ ]] || { echo "unreachable cannot read minimum_zig_version of ${repo} ${latest}"; exit 0; }
    minor=${min%.*}
    zv=$(newest_patch "${minor}")
    if [[ -z "${zv}" ]]; then echo "wait ${latest} ${latest} needs Zig ${minor} (minimum ${min}) and ziglang.org/download/index.json lists no x86_64-linux tarball of ${minor}.x yet"; exit 0; fi
    [[ "$(printf '%s\n%s\n' "${min}" "${zv}" | sort -V | tail -n1)" == "${zv}" ]] || { echo "wait ${latest} ${latest} needs Zig ${min} or newer and the newest published ${minor} is ${zv}"; exit 0; }
    e=$(entry "${zv}") || { echo "unreachable index.json has no official x86_64-linux tarball entry for ${zv}"; exit 0; }
    echo "bump ${latest} ${commit} ${zv} ${e}"
    exit 0
fi

# the pinned tag is current (or ahead of the newest stable tag): a newer patch of the pinned Zig minor?
min=$(min_zig_at "${pin_tag}")
[[ "${min}" =~ ^0\.[0-9]+\.[0-9]+$ ]] || { echo "unreachable cannot read minimum_zig_version of ${repo} ${pin_tag}"; exit 0; }
pin_minor=${pin_zig%.*}
if [[ "${min%.*}" != "${pin_minor}" ]]; then echo "unreachable the pinned Zig ${pin_zig} is not of the minor ${min%.*} that ${pin_tag} requires: fix zig.env by hand"; exit 0; fi
zv=$(newest_patch "${pin_minor}")
if [[ -n "${zv}" && "${zv}" != "${pin_zig}" && "$(printf '%s\n%s\n' "${pin_zig}" "${zv}" | sort -V | tail -n1)" == "${zv}" ]]; then
    [[ "$(printf '%s\n%s\n' "${min}" "${zv}" | sort -V | tail -n1)" == "${zv}" ]] || { echo "current ${pin_tag} with Zig ${pin_zig}"; exit 0; }
    e=$(entry "${zv}") || { echo "unreachable index.json has no official x86_64-linux tarball entry for ${zv}"; exit 0; }
    echo "zigbump ${zv} ${e}"
    exit 0
fi
echo "current ${pin_tag} is the newest stable Ghostty tag and Zig ${pin_zig} the newest published ${pin_minor}.x"
