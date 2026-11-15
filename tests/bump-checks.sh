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
    "api repos/o/r/branches/bump/x") [[ -n "${NO_TIP:-}" ]] || echo "$SHA" ;;
    "api repos/o/r/commits/"*) echo "${MARKED:-0}" ;;
    "run list") [[ -n "${NO_RUN:-}" ]] || [[ -n "${RUN_AFTER_DISPATCH:-}" && ! -f "$DISPATCHED" ]] || echo 4242 ;;
    "workflow run") touch "$DISPATCHED" ;;
    "run watch") ;;
    "run view") if [[ -n "${UNFINISHED:-}" ]]; then echo '{"status":"in_progress","url":"https://x/runs/4242","jobs":[]}'; else echo "{\"status\":\"completed\",\"url\":\"https://x/runs/4242\",\"jobs\":[{\"name\":\"scope\",\"conclusion\":\"success\"},{\"name\":\"test\",\"conclusion\":\"${TEST_C:-success}\"},{\"name\":\"secrets\",\"conclusion\":\"success\"}]}"; fi ;;
    "api -X") [[ -z "${POST_FAIL:-}" ]] || exit 1 ;;
esac
exit 0
F
chmod +x "$bin/gh"
export GH_LOG="$root/log" DISPATCHED="$root/dispatched" SHA="$sha" GITHUB_REPOSITORY=o/r BUMP_CHECKS_WAIT=0 BUMP_CHECKS_POLL=1
run() { : > "$GH_LOG"; rm -f "$DISPATCHED"; (env "$@" PATH="$bin:$PATH" bash "$here/.github/scripts/bump-checks.sh" bump/x ${ARGS:-}) > "$root/run" 2>&1; rc=$?; }
posts() { grep -c '^gh api -X POST repos/o/r/check-runs' "$GH_LOG"; }
run X=1
check "success: two check runs, test and secrets, success, on the branch tip, with the marker title and the run URL" bash -c "[ $rc = 0 ] && [ \$(grep -c '^gh api -X POST repos/o/r/check-runs' '$GH_LOG') = 2 ] && grep -q 'name=test .*head_sha=$sha .*conclusion=success' '$GH_LOG' && grep -q 'name=secrets .*conclusion=success' '$GH_LOG' && grep -q 'output\[title\]=Reported by bump-checks.sh' '$GH_LOG' && grep -q 'details_url=https://x/runs/4242' '$GH_LOG'"
run TEST_C=failure
check "a failed test job is reported as failure (never as success), secrets stays success" bash -c "grep -q 'name=test .*conclusion=failure' '$GH_LOG' && grep -q 'name=secrets .*conclusion=success' '$GH_LOG'"
run TEST_C=cancelled
check "a cancelled test job is failure too" bash -c "grep -q 'name=test .*conclusion=failure' '$GH_LOG'"
run MARKED=1
check "the commit already has its reported checks: nothing is posted, nothing is run" bash -c "[ $rc = 0 ] && [ \$(grep -c 'check-runs' '$GH_LOG') = 1 ] && ! grep -q 'run list' '$GH_LOG'"
run NO_RUN=1
check "no Test run of the tip: a warning, nothing posted, exit 0, no dispatch without the flag" bash -c "[ $rc = 0 ] && grep -q '::warning::bump checks for bump/x: no Test run' '$root/run' && ! grep -q '^gh api -X POST' '$GH_LOG' && ! grep -q 'workflow run' '$GH_LOG'"
ARGS=--dispatch-if-missing run RUN_AFTER_DISPATCH=1 BUMP_CHECKS_WAIT=2
check "--dispatch-if-missing: the Test workflow is dispatched on the branch, then the run is found and reported" bash -c "grep -q '^gh workflow run test.yml --ref bump/x' '$GH_LOG' && [ \$(grep -c '^gh api -X POST repos/o/r/check-runs' '$GH_LOG') = 2 ]"
ARGS="" run UNFINISHED=1
check "a run that did not finish posts nothing (the PR stays blocked: fail closed)" bash -c "[ $rc = 0 ] && ! grep -q '^gh api -X POST' '$GH_LOG' && grep -q 'did not finish' '$root/run'"
run NO_TIP=1
check "an unreadable branch tip: warning, nothing posted, exit 0" bash -c "[ $rc = 0 ] && ! grep -q '^gh api -X POST' '$GH_LOG' && grep -q 'cannot read the tip' '$root/run'"
run POST_FAIL=1
check "a failed post is a warning, not a failure of the bump job" bash -c "[ $rc = 0 ] && grep -q 'could not post the check run test' '$root/run'"
check "bump-pr.sh calls it after the dispatch and on the already-open path; bump-pins.yml gives the three bump jobs checks: write" python3 -I - "$here" <<'PY'
import sys
h = sys.argv[1]
pr = open(h + "/.github/scripts/bump-pr.sh").read()
assert 'bump-checks.sh" "${branch}" || true' in pr and 'bump-checks.sh" "${branch}" --dispatch-if-missing' in pr
assert open(h + "/.github/workflows/bump-pins.yml").read().split("\n").count("      checks: write") == 3
PY
echo; echo "passed: $pass, failed: $failn"
[ "$failn" = 0 ]
