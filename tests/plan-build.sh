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
    got=$("${script}" "$3" "${4-}" "${5-HEAD}" "${6-}" 2>/dev/null || true)
    if [[ "${got}" == "$2" ]]; then echo "PASS $1"; else echo "FAIL $1 (got ${got}, want $2)"; fail=1; fi
}
echo b >> README.md; echo b >> docs/a.txt; echo b > CLAUDE.md; echo b > .gitignore
c1=$(commit docs)
expect "docs only push" false push "${base}" "${c1}"
expect "pull_request is not an event of the build workflow" "" pull_request "${base}" "${c1}"
mkdir -p docs/sub; echo b > docs/sub/deep.png; c2=$(commit deepdoc)
expect "docs/** nested" false push "${c1}" "${c2}"
mkdir -p tests; echo t > tests/x.sh; c2t=$(commit testonly)
expect "a test-only push builds nothing (tests/** is listed with the docs)" false push "${c2}" "${c2t}"
mkdir -p .github/scripts; echo t > .github/scripts/x.sh; c2s=$(commit pipelinescript)
expect ".github/scripts stay image inputs" true push "${c2t}" "${c2s}"
git reset -q --hard "${c2}" 2>/dev/null || true
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
# A docs-only push to testing is never skipped by the diff alone (2026-11-16: after a batch of merges the last push was tests and notes, the earlier builds were
# cancelled, and the tip had no image): build=true lets the reuse step decide.
expect "docs-only push to testing: the reuse check decides" true push "${base}" "${c1}" refs/heads/testing
expect "docs-only push to a branch still skips" false push "${base}" "${c1}" refs/heads/feat/x
expect "docs-only push to main still skips" false push "${base}" "${c1}" refs/heads/main

# Fixture: two pushes in a row, the first image never built. C3 changes an image input (no image: its build was cancelled), C4 is docs-only.
# The plan must not end with nothing: reuse must find no image for C4, while an image of the commit before C3 must NOT count (inputs differ).
lookup="${tmp}/lookup.sh"
printf '#!/usr/bin/env bash\n[[ "$1" == "testing-$(git -C "%s" rev-parse --short %s)" ]] && { echo sha256:aaaa; exit 0; }\nexit 3\n' "${tmp}" "${base}" > "${lookup}"
chmod +x "${lookup}"
reuse_script=$(dirname "${script}")/plan-vanilla-reuse.sh
git reset -q --hard "${c2t}"
echo more >> system_files/x; c3=$(commit code-without-image)
echo more >> README.md; c4=$(commit docs-after)
expect "batch: the docs-only tip on testing builds" true push "${c3}" "${c4}" refs/heads/testing
got=$(REGISTRY_LOOKUP="${lookup}" "${reuse_script}" push refs/heads/testing "${c4}" 2>/dev/null | grep '^reuse=' || true)
if [[ "${got}" == "reuse=false" ]]; then echo "PASS batch: no image for the tip's inputs, no reuse (the build runs)"; else echo "FAIL batch: reuse decision '${got}'"; fail=1; fi
# and a docs-only tip whose inputs DO have an image is reused
lookup2="${tmp}/lookup2.sh"
printf '#!/usr/bin/env bash\n[[ "$1" == "testing-$(git -C "%s" rev-parse --short %s)" ]] && { echo sha256:bbbb; exit 0; }\nexit 3\n' "${tmp}" "${c3}" > "${lookup2}"
chmod +x "${lookup2}"
got=$(REGISTRY_LOOKUP="${lookup2}" "${reuse_script}" push refs/heads/testing "${c4}" 2>/dev/null | grep '^reuse=' || true)
if [[ "${got}" == "reuse=true" ]]; then echo "PASS a docs-only tip with an image of equal inputs is reused"; else echo "FAIL reuse decision '${got}'"; fail=1; fi
exit "${fail}"
