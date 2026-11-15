#!/usr/bin/env bash
# Open or update the ONE bump pull request of Ghostty or of its Zig toolchain: branch bump/ghostty or bump/zig, into testing.
#
#   bump-ghostty.sh ghostty <new-tag> <new-commit> <zig-version> <zig-url> <zig-sha256> <zig-size>
#       a new stable Ghostty tag: changes binaries/ghostty/upstream.env (tag AND peeled commit) and binaries/ghostty/zig.env (version, URL, sha256,
#       size, signature URL) in the SAME pull request, because the Zig minor follows from the Ghostty tag
#   bump-ghostty.sh zig <zig-version> <zig-url> <zig-sha256> <zig-size>
#       a newer patch of the pinned Zig minor: changes only zig.env; a separate, low-priority pull request
#
# Same mechanics as bump-upstream.sh: an open PR for exactly this version is left alone, one for an older version gets one more commit on
# its branch (never a force-push) and a new title and body, the Test workflow is dispatched on the branch (events made with GITHUB_TOKEN start
# none by themselves). Nothing is published here and nothing is built by the pull request: the merge into testing changes the content key of
# the ghostty component, whose build then proves the bump (a failing Ghostty build degrades the component, it never blocks an image build: it is
# optional). Needs git (origin = this repository), gh, GH_TOKEN. Committer identity comes from the environment; no commit trailers.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root="${REPO_ROOT:-$(cd "${here}/../.." && pwd)}"
# shellcheck source=../../binaries/lib/upstream-env.sh
source "${root}/binaries/lib/upstream-env.sh"

mode="${1:?ghostty or zig}"
base="${BUMP_BASE:-testing}"
dir="binaries/ghostty"
case "${mode}" in
    ghostty) new_tag="${2:?new tag}"; new_commit="${3:?new commit}"; zv="${4:?zig version}"; zurl="${5:?zig url}"; zsha="${6:?zig sha256}"; zsize="${7:?zig size}" ;;
    zig) zv="${2:?zig version}"; zurl="${3:?zig url}"; zsha="${4:?zig sha256}"; zsize="${5:?zig size}" ;;
    *) echo "bump-ghostty.sh: mode must be ghostty or zig" >&2; exit 2 ;;
esac
[[ "${zv}" =~ ^0\.[0-9]+\.[0-9]+$ && "${zsha}" =~ ^[0-9a-f]{64}$ && "${zsize}" =~ ^[0-9]+$ && "${zurl}" == "https://ziglang.org/download/${zv}/zig-x86_64-linux-${zv}.tar.xz" ]] \
    || { echo "bump-ghostty.sh: the Zig arguments are not an official x86_64-linux release entry" >&2; exit 2; }
branch="bump/${mode}"
cd "${root}"
upstream_env_load "${dir}/upstream.env"
repo="${UPSTREAM_WATCH}"
old_tag="${UPSTREAM_TAG}"
old_zig=$(sed -n 's/^ZIG_VERSION=//p' "${dir}/zig.env")
if [[ "${mode}" == ghostty ]]; then title="Bump ghostty to ${new_tag} (Zig ${zv})"; else title="Bump the Ghostty Zig toolchain to ${zv}"; fi

zig_env_set() { # rewrite the four value lines and the signature URL, keep everything else (comments, the key)
    sed -i \
        -e "s|^ZIG_VERSION=.*|ZIG_VERSION=${zv}|" -e "s|^ZIG_URL=.*|ZIG_URL=${zurl}|" -e "s|^ZIG_SHA256=.*|ZIG_SHA256=${zsha}|" \
        -e "s|^ZIG_SIZE=.*|ZIG_SIZE=${zsize}|" -e "s|^ZIG_SIGNATURE_URL=.*|ZIG_SIGNATURE_URL=${zurl}.minisig|" "${dir}/zig.env"
}

if [[ "${mode}" == ghostty ]]; then
    body="Upstream ${repo} has a newer STABLE tag than the pin of \`ghostty\`.

- Ghostty: \`${old_tag}\` to \`${new_tag}\` (commit \`${new_commit}\`); release notes https://ghostty.org/docs/install/release-notes, changes https://github.com/${repo}/compare/${old_tag}...${new_tag}
- Zig: \`${old_zig}\` to \`${zv}\` (the minor follows from \`.minimum_zig_version\` of the new tag's build.zig.zon; ${zurl}, sha256 \`${zsha}\`)

Only \`${dir}/upstream.env\` and \`${dir}/zig.env\` change. The ghostty component is OPTIONAL: after the merge into \`${base}\` its build proves the bump; if it fails, the image uses the last good Ghostty or leaves it out and builds anyway (a ci-failure-binaries issue names it on main). The build checks the tag still resolves to the pinned commit and the Zig tarball against its sha256, ziglang.org/download/index.json and the minisign signature. Check the packages the builder installs (\`binaries/ghostty/Containerfile\`) and the image's runtime libraries against the new release notes. Not verified: nothing is built or run by this PR."
else
    body="A newer patch of the pinned Zig minor is published (\`${old_zig}\` to \`${zv}\`; ${zurl}, sha256 \`${zsha}\`). Ghostty's build accepts the same major.minor with any patch at or above its minimum (src/build/zig.zig requireZig), so only \`${dir}/zig.env\` changes. LOW PRIORITY: nothing here is needed unless you want the patch. The ghostty component is optional; its build after the merge into \`${base}\` proves the bump. Not verified: nothing is built or run by this PR."
fi
bodyfile=$(mktemp); trap 'rm -f "${bodyfile}"' EXIT
printf '%s\n' "${body}" > "${bodyfile}"
if [[ "${mode}" == ghostty ]]; then why="upstream released it and the Zig minor follows from its tag"; else why="a newer patch of the pinned Zig minor is published"; fi
files=(--file "${dir}/zig.env"); [[ "${mode}" != ghostty ]] || files+=(--file "${dir}/upstream.env")
writer() { [[ "${mode}" != ghostty ]] || upstream_env_set "${dir}/upstream.env" "${new_tag}" "${new_commit}"; zig_env_set; }
export mode dir zv zurl zsha zsize; export new_tag="${new_tag:-}" new_commit="${new_commit:-}"; export -f zig_env_set writer upstream_env_set
BUMP_BASE="${base}" REPO_ROOT="${root}" "${here}/bump-pr.sh" --branch "${branch}" --title "${title}" --body-file "${bodyfile}" --message "${title}: ${why}" "${files[@]}" -- bash -c writer
