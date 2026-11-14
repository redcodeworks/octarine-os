#!/usr/bin/env bash
# Tests .github/scripts/ci-issue.sh with a stub `gh`: the first failure opens ONE issue (label ci-failure-dx), every later failure is a
# comment on it, a recovery comments and closes it, and nothing happens when no issue is open. Deduplication is on the label, not the title.
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script="$here/.github/scripts/ci-issue.sh"
root=$(mktemp -d)
trap 'rm -rf -- "$root"' EXIT
pass=0; failn=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { failn=$((failn + 1)); echo "FAIL $1"; sed 's/^/     /' "$root/out"; }
check() { local d=$1; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
mkdir -p "$root/bin"
for c in bash env cat grep sed date jq dirname; do p=$(command -v "$c") && ln -sf "$p" "$root/bin/$c"; done
cat >"$root/bin/gh" <<'F'
#!/usr/bin/env bash
echo "gh $*" >>"$LOG"
case "$1 $2" in
    "issue list") [ -n "${OPEN:-}" ] && echo "$OPEN"; exit 0 ;;
    "label create") exit "${LABEL_EXISTS:-0}" ;;
esac
exit 0
F
chmod +x "$root/bin/gh"
export LOG="$root/log" GITHUB_REPOSITORY=redcodeworks/octarine-os SHA=0123456789abcdef0123456789abcdef01234567 RUN_URL=https://example/run/9 NOW=2026-11-14
export NEEDS_JSON='{"plan":{"result":"success"},"build":{"result":"failure"},"sign":{"result":"skipped"}}'
run() { : >"$LOG"; PATH="$root/bin" bash "$script" "$@" >"$root/out" 2>&1; rc=$?; }

OPEN="" run fail
check "no open issue: ONE issue is created with the label, a title naming channel and short sha, the run URL and the failed job" bash -c "[ $rc = 0 ] && [ \$(grep -c '^gh issue create' '$LOG') = 1 ] && grep -q 'gh label create ci-failure-dx' '$LOG' && grep -q -- '--title dx/latest not published: latest 0123456' '$LOG' && grep -q -- '--label ci-failure-dx' '$LOG' && grep -q 'https://example/run/9' '$LOG' && grep -q 'Failed job(s): build' '$LOG' && grep -q 'vanilla-only' '$LOG' && ! grep -q 'issue comment' '$LOG'"
OPEN=41 run fail
check "an issue is already open: a comment is added (date, run URL, sha, failed job) and NO second issue is created" bash -c "[ $rc = 0 ] && grep -q 'gh issue comment 41' '$LOG' && grep -q 'Failed again (2026-11-14): https://example/run/9' '$LOG' && ! grep -q 'issue create' '$LOG'"
LABEL_EXISTS=1 OPEN=41 run fail
check "the label already existing is not an error" test "$rc" = 0
check "the open issue is looked up by LABEL and state, never by title" bash -c "grep -q 'gh issue list -R redcodeworks/octarine-os --label ci-failure-dx --state open' '$LOG' && ! grep -q 'issue list.*--search\\|issue list.*title' '$LOG'"
OPEN=41 run recover
check "recovery: a comment 'recovered: <run URL>' and the issue is closed" bash -c "[ $rc = 0 ] && grep -q 'gh issue comment 41' '$LOG' && grep -q 'recovered: https://example/run/9' '$LOG' && grep -q 'gh issue close 41' '$LOG'"
OPEN="" run recover
check "recovery with no open issue does nothing" bash -c "[ $rc = 0 ] && ! grep -qE 'issue (comment|close|create)' '$LOG'"
OPEN="" NEEDS_JSON="" run fail
check "no needs JSON: the issue still opens (failed job: see the run)" bash -c "[ $rc = 0 ] && grep -q 'see the run' '$LOG'"
run bogus
check "an unknown mode exits 2" test "$rc" = 2
echo; echo "passed: $pass, failed: $failn"
[ "$failn" = 0 ]
