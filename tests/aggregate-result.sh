#!/usr/bin/env bash
# Tests .github/scripts/aggregate-result.sh with fixed job results.
set -euo pipefail
script=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.github/scripts/aggregate-result.sh
fail=0
t() { # name want plan bw pw publish build promote sign
    local rc=0
    PLAN=$3 BUILD_WANTED=$4 PROMOTE_WANTED=$5 PUBLISH=$6 BUILD=$7 PROMOTE=$8 SIGN=$9 "${script}" >/dev/null 2>&1 || rc=$?
    if { [[ $2 == pass && $rc == 0 ]] || [[ $2 == fail && $rc != 0 ]]; }; then echo "PASS $1"; else echo "FAIL $1 (rc=${rc})"; fail=1; fi
}
t "validation build (dispatch from a dev branch), nothing published" pass success true false false success skipped skipped
t "testing/main build published and signed" pass success true false true success skipped success
t "published but sign failed" fail success true false true success skipped failure
t "published but sign cancelled" fail success true false true success skipped cancelled
t "published but sign skipped" fail success true false true success skipped skipped
t "build failed" fail success true false true failure skipped skipped
t "docs-only plan" pass success false false "" skipped skipped skipped
t "docs-only plan but sign ran" fail success false false "" skipped skipped success
t "promote signed" pass success false true "" skipped success success
t "promote, sign failed" fail success false true "" skipped success failure
t "promote, sign skipped" fail success false true "" skipped success skipped
t "promote failed" fail success false true "" skipped failure skipped
t "plan failed" fail failure "" "" "" skipped skipped skipped
t "build and promote both ran" fail success true false true success success success
exit "${fail}"
