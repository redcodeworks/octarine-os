#!/usr/bin/env bash
# Show which files of build_files/ derived from Bluefin changed upstream since the commit their header records (read-only: only `gh api` GETs on
# ublue-os/bluefin, nothing is written or opened there). Used by `just bluefin-diff`.
#
# A derived file has ONE header line:
#   # Derived from ublue-os/bluefin@<40-char sha> <path in Bluefin> (Apache-2.0, ...); modified for octarine-os.
# For each such file the script lists the commits that touched <path> on Bluefin's main branch after <sha> (short sha, subject, URL) and prints the
# diff of the file between <sha> and main. Nothing is printed for an unchanged file, and nothing at all when no file changed.
# Exit status: 0 whether or not something changed; non-zero only when `gh` fails (after the retries of retry.sh), with one line on stderr.
# Env (tests only): BLUEFIN_FILES (the files to scan, default build_files/*.sh), BLUEFIN_REF (default main).
set -euo pipefail
here=$(dirname "${BASH_SOURCE[0]}")
repo=ublue-os/bluefin
ref=${BLUEFIN_REF:-main}
gh_get() { "${here}/retry.sh" -- gh api "$@" 2> /dev/null || { echo "bluefin-diff: gh api $1 failed" >&2; return 1; }; }
raw() { gh_get -H 'Accept: application/vnd.github.raw' "repos/${repo}/contents/$1?ref=$2"; }

if [[ -n "${BLUEFIN_FILES:-}" ]]; then read -r -a files <<< "${BLUEFIN_FILES}"; else files=("$(git rev-parse --show-toplevel)"/build_files/*.sh); fi
tmp=$(mktemp -d)
trap 'rm -rf -- "${tmp}"' EXIT

for f in "${files[@]}"; do
    line=$(grep -m1 -E '^# Derived from ublue-os/bluefin@[0-9a-f]{40} ' "${f}" || true)
    [[ -n "${line}" ]] || continue
    sha=$(sed -E 's/^# Derived from ublue-os\/bluefin@([0-9a-f]{40}) .*/\1/' <<< "${line}")
    path=$(sed -E 's/^# Derived from ublue-os\/bluefin@[0-9a-f]{40} ([^ ]+) .*/\1/' <<< "${line}")
    # the commits that touched the path, newest first, up to the recorded one
    commits=$(gh_get "repos/${repo}/commits?path=${path}&sha=${ref}&per_page=100" -q '.[] | [.sha, (.commit.message | split("\n")[0]), .html_url] | @tsv') || exit 1
    newer=$(awk -F'\t' -v s="${sha}" '$1 == s { exit } { print }' <<< "${commits}")
    [[ -n "${newer}" ]] || continue
    echo "== ${f#"$(git rev-parse --show-toplevel)"/}: Bluefin ${path} changed since ${sha:0:12}"
    while IFS=$'\t' read -r c subject url; do echo "   ${c:0:12} ${subject} (${url})"; done <<< "${newer}"
    raw "${path}" "${sha}" > "${tmp}/old" || exit 1
    raw "${path}" "${ref}" > "${tmp}/new" || exit 1
    diff -u --label "bluefin@${sha:0:12}/${path}" --label "bluefin@${ref}/${path}" "${tmp}/old" "${tmp}/new" || true
    echo
done
