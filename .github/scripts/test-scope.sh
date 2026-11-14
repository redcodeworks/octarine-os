#!/usr/bin/env bash
# Decide how much of the test job a push needs, and print `docs` or `full`.
#
#   test-scope.sh <event> [<before> [<after>]]
#   test-scope.sh --doc-tests        the tests that read the documentation, one per line (derived, never a fixed list)
#
# `docs` only when the event is a push, the commit range is known, and EVERY changed file is documentation text: a top-level *.md,
# anything under docs/, LICENSE, .gitignore. The test suite itself is NOT documentation here (a changed test must run), unlike in
# docs-only.sh, which decides what needs an image build. Everything else is `full`: a first push of a branch (before is all zeros or
# unknown), a manual dispatch, an empty diff, a failing git. The job keeps its name and its required check either way.
set -uo pipefail

doc_tests() { grep -lE 'README\.md|CLAUDE\.md|CONFIG-GUIDE\.md|docs/' tests/*.sh 2> /dev/null || true; }
if [[ "${1:-}" == --doc-tests ]]; then doc_tests; exit 0; fi

is_doc_text() {
    case "$1" in
        */*) [[ "$1" == docs/* ]] ;;
        *.md | LICENSE | .gitignore) return 0 ;;
        *) return 1 ;;
    esac
}

event="${1:?event}"
before="${2-}"
after="${3:-HEAD}"
full() { echo "full: $*" >&2; echo full; exit 0; }

[[ "${event}" == push ]] || full "not a push (${event})"
[[ -n "${before}" && ! "${before}" =~ ^0+$ ]] || full "no usable before commit"
git cat-file -e "${before}^{commit}" 2> /dev/null || full "the before commit is not available"
git cat-file -e "${after}^{commit}" 2> /dev/null || full "the after commit is not available"
mapfile -t changed < <(git diff --name-only "${before}" "${after}" 2> /dev/null) || full "git diff failed"
((${#changed[@]} > 0)) || full "empty diff"
for f in "${changed[@]}"; do
    is_doc_text "${f}" || full "${f} is not documentation"
done
echo "docs: ${#changed[@]} documentation files" >&2
echo docs
