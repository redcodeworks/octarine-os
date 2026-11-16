#!/usr/bin/env bash
# Sanity check of the documentation text: no top-level or docs/ markdown file is empty or carries a merge conflict marker.
# Run from the repository root. Used by the `docs` job of test.yml (a documentation-only push).
set -uo pipefail
bad=0
for f in *.md docs/*.md; do
    [[ -f "$f" ]] || continue
    if [[ ! -s "$f" ]]; then echo "::error file=$f::empty"; bad=1; fi
    if grep -qE '^(<<<<<<<|=======|>>>>>>>)( |$)' "$f"; then echo "::error file=$f::merge conflict marker"; bad=1; fi
done
exit "$bad"
