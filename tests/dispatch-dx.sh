#!/usr/bin/env bash
# Tests .github/scripts/dispatch-dx.sh with a stub `gh`: it dispatches on the right ref with the channel and the full sha, waits until a run
# with the title `dx <channel> <sha>` exists (created after the start), and fails loudly when the dispatch is refused or no run appears.
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
for c in bash env cat grep sed date jq sleep dirname; do p=$(command -v "$c") && ln -sf "$p" "$root/bin/$c"; done
cat >"$root/bin/gh" <<'F'
#!/usr/bin/env bash
echo "gh $*" >>"$LOG"
case "$1 $2" in
    "workflow run") [ "${FAKE_DISPATCH_FAIL:-}" = 1 ] && exit 1; exit 0 ;;
    "run list")
        [ "${FAKE_NO_RUN:-}" = 1 ] && { echo '[]'; exit 0; }
        printf '[{"databaseId":1,"displayTitle":"dx %s %s","createdAt":"2999-01-01T00:00:00Z","url":"https://example/run/1"},{"databaseId":0,"displayTitle":"dx %s %s","createdAt":"2000-01-01T00:00:00Z","url":"https://example/old"}]' "$FAKE_CHANNEL" "$FAKE_SHA" "$FAKE_CHANNEL" "$FAKE_SHA" ;;
esac
F
chmod +x "$root/bin/gh"
sha=$(printf 'a%.0s' {1..40})
export LOG="$root/log" GITHUB_REPOSITORY=redcodeworks/octarine-os POLL_TRIES=3 POLL_WAIT=0 FAKE_SHA="$sha" FAKE_CHANNEL=testing
run() { : >"$LOG"; PATH="$root/bin" REF=${REF:-testing} bash "$script" "$@" >"$root/out" 2>&1; rc=$?; }
run testing "$sha"
check "dispatches on the ref with channel and sha, finds the new run (not the old one), exit 0" bash -c "[ $rc = 0 ] && grep -qx 'gh workflow run build-dx.yml -R redcodeworks/octarine-os --ref testing -f channel=testing -f sha=$sha' '$LOG' && grep -q 'Started: https://example/run/1' '$root/out'"
FAKE_NO_RUN=1 run testing "$sha"
check "no run appears: fails loudly and says to re-run the job" bash -c "[ $rc = 1 ] && grep -q 'no run titled' '$root/out' && grep -q 're-run this job' '$root/out'"
FAKE_DISPATCH_FAIL=1 run testing "$sha"
check "a refused dispatch fails, no run lookup" bash -c "[ $rc = 1 ] && grep -q 'could not dispatch' '$root/out' && ! grep -q 'run list' '$LOG'"
FAKE_CHANNEL=latest REF=main run latest "$sha"
check "latest on main works" bash -c "[ $rc = 0 ] && grep -q -- '--ref main -f channel=latest' '$LOG'"
run bogus "$sha"
check "an unknown channel exits 2 without dispatching" bash -c "[ $rc = 2 ] && ! grep -q 'workflow run' '$LOG'"
run testing abc123
check "a short sha exits 2 without dispatching" bash -c "[ $rc = 2 ] && ! grep -q 'workflow run' '$LOG'"
REF=feat/x run testing "$sha"
check "any ref but main or testing is refused" bash -c "[ $rc = 2 ] && ! grep -q 'workflow run' '$LOG'"
echo; echo "passed: $pass, failed: $failn"
[ "$failn" = 0 ]
