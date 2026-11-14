#!/usr/bin/env bash
# Tests .github/scripts/dispatch-dx.sh with a stub `gh`: it dispatches on the right ref with the channel, the full sha and an optional base
# digest, finds the run it started (by the run URL that gh prints, or, when gh prints none, by a run id that was not in the list taken before the
# dispatch; no clock), and fails loudly when the dispatch is refused or no run appears. A summary line that cannot be written never fails the step
# (that was the CI failure of the first version: the runner's step summary file is not writable for the test user).
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script="$here/.github/scripts/dispatch-dx.sh"
root=$(mktemp -d)
trap 'rm -rf -- "$root"' EXIT
pass=0; failn=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { failn=$((failn + 1)); echo "FAIL $1"; sed 's/^/     /' "$root/out"; }
check() { local d=$1; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
mkdir -p "$root/bin"
for c in bash env cat grep sed date jq sleep dirname tail head tr; do p=$(command -v "$c") && ln -sf "$p" "$root/bin/$c"; done
# The stub registry of runs: $STATE/dispatched appears after `workflow run`; `run list` shows the old run always and the new one only after the dispatch.
cat >"$root/bin/gh" <<'F'
#!/usr/bin/env bash
echo "gh $*" >>"$LOG"
title="dx $FAKE_CHANNEL $FAKE_SHA"
case "$1 $2" in
    "--version "*) echo "gh version 2.102.0 (stub)"; exit 0 ;;
    "workflow run")
        [ "${FAKE_DISPATCH_FAIL:-}" = 1 ] && { echo "HTTP 422" >&2; exit 1; }
        : >"$STATE/dispatched"
        [ "${FAKE_PRINT_URL:-1}" = 1 ] && echo "https://github.com/redcodeworks/octarine-os/actions/runs/777"
        exit 0 ;;
    "run view") printf '{"displayTitle":"Build dx image","event":"%s","headBranch":"%s"}' "${FAKE_VIEW_EVENT:-workflow_dispatch}" "${FAKE_VIEW_BRANCH:-$FAKE_REF}"; exit 0 ;;
    "run list")
        old="{\"databaseId\":5,\"displayTitle\":\"$title\",\"headBranch\":\"$FAKE_REF\",\"url\":\"https://example/old\"}"
        new="{\"databaseId\":6,\"displayTitle\":\"$title\",\"headBranch\":\"$FAKE_REF\",\"url\":\"https://example/new\"}"
        other="{\"databaseId\":7,\"displayTitle\":\"$title\",\"headBranch\":\"other\",\"url\":\"https://example/other\"}"
        if [ -e "$STATE/dispatched" ] && [ "${FAKE_NO_RUN:-}" != 1 ]; then echo "[$new,$other,$old]"; else echo "[$old]"; fi ;;
esac
F
chmod +x "$root/bin/gh"
sha=$(printf 'a%.0s' {1..40})
dig="sha256:$(printf 'b%.0s' {1..64})"
export LOG="$root/log" STATE="$root/state" GITHUB_REPOSITORY=redcodeworks/octarine-os POLL_TRIES=3 POLL_WAIT=0 FAKE_SHA="$sha" FAKE_CHANNEL=testing FAKE_REF=testing
mkdir -p "$STATE"
unset GITHUB_STEP_SUMMARY
run() { : >"$LOG"; rm -f "$STATE/dispatched"; PATH="$root/bin" REF=${REF:-testing} bash "$script" "$@" >"$root/out" 2>&1; rc=$?; }

run testing "$sha"
check "gh prints the run URL: dispatched on the ref with channel and sha, the run (still titled with the workflow name, as a fresh run is) is accepted by event and branch, exit 0, the gh version is printed" bash -c "[ $rc = 0 ] && grep -qx 'gh workflow run build-dx.yml -R redcodeworks/octarine-os --ref testing -f channel=testing -f sha=$sha' '$LOG' && grep -q 'Started: https://github.com/redcodeworks/octarine-os/actions/runs/777' '$root/out' && grep -q 'gh version 2.102.0' '$root/out'"
FAKE_VIEW_EVENT=push run testing "$sha"
check "the run behind the printed URL is not a workflow_dispatch run: fails loudly" bash -c "[ $rc = 1 ] && grep -q 'expected a workflow_dispatch run' '$root/out'"
FAKE_VIEW_BRANCH=main run testing "$sha"
check "the run behind the printed URL is on another branch: fails loudly" bash -c "[ $rc = 1 ] && grep -q 'expected' '$root/out'"
FAKE_PRINT_URL=0 run testing "$sha"
check "gh prints no URL: the snapshot approach finds the NEW run (id not listed before, right title and branch), not the old one and not the one on another branch" bash -c "[ $rc = 0 ] && grep -q 'Started: https://example/new' '$root/out' && ! grep -q 'example/old\\|example/other' '$root/out'"
FAKE_PRINT_URL=0 FAKE_NO_RUN=1 run testing "$sha"
check "gh prints no URL and only the old run exists: fails loudly and says to re-run the job" bash -c "[ $rc = 1 ] && grep -q 'no new run' '$root/out' && grep -q 're-run this job' '$root/out'"
FAKE_DISPATCH_FAIL=1 run testing "$sha"
check "a refused dispatch fails, no run lookup after it" bash -c "[ $rc = 1 ] && grep -q 'could not dispatch' '$root/out' && ! grep -q 'run view' '$LOG'"
GITHUB_STEP_SUMMARY=/nonexistent/dir/summary run testing "$sha"
check "a step summary file that cannot be written does not fail the step (the CI failure of the first version)" bash -c "[ $rc = 0 ] && grep -q 'Started:' '$root/out'"
echo "$root/summary" >/dev/null; GITHUB_STEP_SUMMARY="$root/summary" run testing "$sha"
check "a writable step summary gets the line" grep -q "dx testing for $sha" "$root/summary"
FAKE_CHANNEL=latest FAKE_REF=main REF=main run latest "$sha" "$dig"
check "latest on main with a base digest: -f base_digest is passed" bash -c "[ $rc = 0 ] && grep -q -- '--ref main -f channel=latest -f sha=$sha -f base_digest=$dig' '$LOG'"
FAKE_CHANNEL=latest FAKE_REF=main REF=main run latest "$sha"
check "latest without a base digest: no base_digest input" bash -c "[ $rc = 0 ] && ! grep -q 'base_digest' '$LOG'"
run latest "$sha" sha256:short
check "a malformed digest exits 2 without dispatching" bash -c "[ $rc = 2 ] && ! grep -q 'workflow run' '$LOG'"
run bogus "$sha"
check "an unknown channel exits 2 without dispatching" bash -c "[ $rc = 2 ] && ! grep -q 'workflow run' '$LOG'"
run testing abc123
check "a short sha exits 2 without dispatching" bash -c "[ $rc = 2 ] && ! grep -q 'workflow run' '$LOG'"
REF=feat/x run testing "$sha"
check "any ref but main or testing is refused" bash -c "[ $rc = 2 ] && ! grep -q 'workflow run' '$LOG'"
echo; echo "passed: $pass, failed: $failn"
[ "$failn" = 0 ]
