#!/usr/bin/env bash
# Tests .github/scripts/bump-checks.sh (reports the dispatched Test run of a bump branch to its pull request as check runs `test` and `secrets`) with a stub gh:
# real conclusions are copied, nothing is posted without a finished run, a commit that already has its reported checks is left alone, the repair path dispatches.
# Run: tests/bump-checks.sh
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
root=$(mktemp -d)
trap 'rm -rf -- "${root:?}"' EXIT
pass=0; failn=0; rc=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { failn=$((failn + 1)); echo "FAIL $1"; sed 's/^/     /' "$root/run" 2> /dev/null; echo "     rc=$rc"; }
check() { local d=$1; shift; if "$@" > "$root/out" 2>&1; then ok "$d"; else bad "$d"; fi; }
sha=$(printf 'a%.0s' $(seq 1 40))
bin="$root/bin"; mkdir -p "$bin"
cat > "$bin/gh" <<'F'
#!/usr/bin/env bash
echo "gh $*" >> "$GH_LOG"
case "$1 $2" in
    "api repos/o/r/commits/"*) echo "${MARKED:-0}" ;;
    "run list") if [[ -n "${NO_RUN:-}" ]]; then :; elif [[ -n "${RUN_AFTER_DISPATCH:-}" && ! -f "$DISPATCHED" ]]; then :; else echo 4242; fi ;;
    "workflow run") [[ -z "${DISPATCH_FAIL:-}" ]] || exit 1; touch "$DISPATCHED" ;;
    "run watch") ;;
    "run view") if [[ -n "${UNFINISHED:-}" ]]; then echo '{"status":"in_progress","url":"https://x/runs/4242","jobs":[]}'; else echo "{\"status\":\"completed\",\"url\":\"https://x/runs/4242\",\"jobs\":[{\"name\":\"scope\",\"conclusion\":\"success\"},{\"name\":\"test\",\"conclusion\":\"${TEST_C:-success}\"},{\"name\":\"secrets\",\"conclusion\":\"success\"}]}"; fi ;;
    "api -X") [[ -z "${POST_FAIL:-}" ]] || exit 1 ;;
esac
exit 0
F
chmod +x "$bin/gh"
export GH_LOG="$root/log" DISPATCHED="$root/dispatched" SHA="$sha" GITHUB_REPOSITORY=o/r BUMP_CHECKS_WAIT=0 BUMP_CHECKS_POLL=1
run() { : > "$GH_LOG"; rm -f "$DISPATCHED"; (env "$@" PATH="$bin:$PATH" bash "$here/.github/scripts/bump-checks.sh" bump/x "${SHAARG:-$sha}") > "$root/run" 2>&1; rc=$?; }
posts() { grep -c '^gh api -X POST repos/o/r/check-runs' "$GH_LOG"; }
run X=1
check "success: two check runs, test and secrets, success, on the bump commit, with the marker title and the run URL" bash -c "[ $rc = 0 ] && [ \$(grep -c '^gh api -X POST repos/o/r/check-runs' '$GH_LOG') = 2 ] && grep -q 'name=test .*head_sha=$sha .*conclusion=success' '$GH_LOG' && grep -q 'name=secrets .*conclusion=success' '$GH_LOG' && grep -q 'output\[title\]=Reported by bump-checks.sh' '$GH_LOG' && grep -q 'details_url=https://x/runs/4242' '$GH_LOG'"
check "the run is looked up by its title 'Test of <sha>' and an existing run is not dispatched again" bash -c "grep -qF 'Test of $sha' '$GH_LOG' && ! grep -q 'workflow run' '$GH_LOG'"
run TEST_C=failure
check "a failed test job is reported as failure (never as success), secrets stays success" bash -c "grep -q 'name=test .*conclusion=failure' '$GH_LOG' && grep -q 'name=secrets .*conclusion=success' '$GH_LOG'"
run TEST_C=cancelled
check "a cancelled test job is failure too" bash -c "grep -q 'name=test .*conclusion=failure' '$GH_LOG'"
run MARKED=1
check "the commit already has its reported checks: nothing is posted, nothing is run" bash -c "[ $rc = 0 ] && [ \$(grep -c 'check-runs' '$GH_LOG') = 1 ] && ! grep -q 'run list' '$GH_LOG'"
run NO_RUN=1
check "no run yet: Test is dispatched on the TESTING ref with ref=<sha> (not on the bump branch, whose commit must stay without a suite), then, finding no run in time, a warning and nothing posted, exit 0" bash -c "[ $rc = 0 ] && grep -qx 'gh workflow run test.yml --ref testing -f ref=$sha' '$GH_LOG' && grep -q 'no Test run for' '$root/run' && ! grep -q '^gh api -X POST' '$GH_LOG'"
run RUN_AFTER_DISPATCH=1 BUMP_CHECKS_WAIT=3
check "the dispatched run appears later: it is found, watched and reported" bash -c "[ \$(grep -c '^gh api -X POST repos/o/r/check-runs' '$GH_LOG') = 2 ]"
run UNFINISHED=1
check "a run that did not finish posts nothing (the PR stays blocked: fail closed)" bash -c "[ $rc = 0 ] && ! grep -q '^gh api -X POST' '$GH_LOG' && grep -q 'did not finish' '$root/run'"
SHAARG=notasha run X=1
check "a value that is not a commit sha: warning, nothing posted, nothing dispatched, exit 0" bash -c "[ $rc = 0 ] && ! grep -q '^gh api -X POST' '$GH_LOG' && ! grep -q 'workflow run' '$GH_LOG' && grep -q 'not a commit sha' '$root/run'"
unset SHAARG
run POST_FAIL=1
check "a failed post is a warning, not a failure of the bump job" bash -c "[ $rc = 0 ] && grep -q 'could not post the check run test' '$root/run'"
run NO_RUN=1 DISPATCH_FAIL=1
check "bump-pr.sh calls it with the pushed commit; bump-pins.yml gives the three bump jobs checks: write; test.yml accepts the ref input, names its run after it and checks it out" python3 -I - "$here" <<'PY'
import sys
h = sys.argv[1]
pr = open(h + "/.github/scripts/bump-pr.sh").read()
assert 'bump-checks.sh" "${branch}" "$(git rev-parse HEAD)"' in pr
assert open(h + "/.github/workflows/bump-pins.yml").read().split("\n").count("      checks: write") == 3
t = open(h + "/.github/workflows/test.yml").read()
assert "format('Test of {0}', inputs.ref)" in t and t.count("ref: ${{ inputs.ref || github.sha }}") >= 3 and "inputs.ref || github.ref" in t
PY
echo; echo "passed: $pass, failed: $failn"
[ "$failn" = 0 ]
