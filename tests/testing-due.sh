#!/usr/bin/env bash
# Tests .github/scripts/testing-due.sh with fixed inputs.
set -euo pipefail
script=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.github/scripts/testing-due.sh
fail=0
t() { # name want-prefix args...
    local name=$1 want=$2 got
    shift 2
    got=$("${script}" "$@")
    if [[ "${got}" == "${want}"* ]]; then echo "PASS ${name}"; else echo "FAIL ${name}: got '${got}', want '${want}...'"; fail=1; fi
}
a=aaaaaaa1111111111111111111111111111111aa
b=bbbbbbb2222222222222222222222222222222bb
t "no commits ahead of main" "skip testing has no changes" "$a" 0
t "no testing branch" "skip no testing branch" "" 3
t "bad file count" "skip unusable" "$a" x
t "a run for this sha exists" "skip a build of aaaaaaa" "$a" 3 "$b" "$a"
t "only a run of another sha exists" due "$a" 3 "$b"
t "only a cancelled run exists (the caller drops it)" due "$a" 3
t "no runs at all" due "$a" 5
echo
if [[ ${fail} == 0 ]]; then echo "all passed"; else echo "FAILED"; exit 1; fi
