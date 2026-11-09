#!/usr/bin/env bash
# Tests .github/scripts/plan-build.sh with fixed inputs in a temporary git repository.
set -euo pipefail
script=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.github/scripts/plan-build.sh
tmp=$(mktemp -d)
trap 'rm -rf "${tmp}"' EXIT
cd "${tmp}"
git init -q .
git config user.email t@example.invalid
git config user.name t
mkdir docs system_files
echo a > README.md; echo a > docs/a.txt; echo a > system_files/x; echo a > LICENSE
git add -A; git commit -qm base
base=$(git rev-parse HEAD)
fail=0
commit() { git add -A; git commit -qm "$1"; git rev-parse HEAD; }
expect() { # name want event before after
    local got
    got=$("${script}" "$3" "${4-}" "${5-HEAD}" 2>/dev/null)
    if [[ "${got}" == "$2" ]]; then echo "PASS $1"; else echo "FAIL $1 (got ${got}, want $2)"; fail=1; fi
}
echo b >> README.md; echo b >> docs/a.txt; echo b > CLAUDE.md; echo b > .gitignore
c1=$(commit docs)
expect "docs only push" false push "${base}" "${c1}"
expect "docs only pull request" false pull_request "${base}" "${c1}"
mkdir -p docs/sub; echo b > docs/sub/deep.png; c2=$(commit deepdoc)
expect "docs/** nested" false push "${c1}" "${c2}"
echo b >> system_files/x; c3=$(commit code)
expect "non-docs file" true push "${c2}" "${c3}"
expect "mixed range includes a non-docs file" true push "${base}" "${c3}"
mkdir -p system_files/sub; echo b > system_files/sub/NOTE.md; c4=$(commit nested-md)
expect "nested .md is not docs" true push "${c3}" "${c4}"
mkdir -p .github/workflows; echo b > .github/workflows/w.yml; c5=$(commit wf)
expect "workflow change" true push "${c4}" "${c5}"
expect "all-zero before" true push 0000000000000000000000000000000000000000 "${c1}"
expect "empty before" true push "" "${c1}"
expect "unknown before" true push 1111111111111111111111111111111111111111 "${c1}"
expect "empty diff" true push "${c1}" "${c1}"
expect "schedule" true schedule "${base}" "${c1}"
expect "workflow_dispatch" true workflow_dispatch "${base}" "${c1}"
exit "${fail}"
