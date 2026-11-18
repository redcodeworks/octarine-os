#!/usr/bin/env bash
# The test groups of the `suite` matrix: one group per directory under tests/ (the directory tree is the only list). Prints the groups as a JSON array on
# stdout and, with GITHUB_OUTPUT set, as `groups=<json>`. Fails when a tests/*.sh sits outside a group (it would never run) or a group directory has no *.sh.
# Run from anywhere: bash .github/scripts/plan-tests.sh
set -euo pipefail
root=$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)
cd "$root/tests"
stray=(*.sh)
if [ -e "${stray[0]}" ]; then
    echo "::error::tests/${stray[0]} is outside a group: move it into a tests/<group>/ directory (${stray[*]})"
    exit 1
fi
groups=()
for d in */; do
    d=${d%/}
    files=("$d"/*.sh)
    if [ ! -e "${files[0]}" ]; then
        echo "::error::the test group tests/$d has no *.sh"
        exit 1
    fi
    groups+=("$d")
done
[ "${#groups[@]}" -gt 0 ] || { echo "::error::no test groups under tests/"; exit 1; }
json=$(printf '%s\n' "${groups[@]}" | jq -R . | jq -sc .)
echo "$json"
[ -z "${GITHUB_OUTPUT:-}" ] || echo "groups=$json" >> "$GITHUB_OUTPUT"
