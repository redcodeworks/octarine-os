#!/usr/bin/env bash
# Tests .github/scripts/run-tests.sh (the parallel shell test runner) and .github/scripts/test-scope.sh (documentation-only detection)
# with fixture scripts in a scratch directory. Run: tests/run-tests.sh
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
runner="$here/.github/scripts/run-tests.sh"
scope="$here/.github/scripts/test-scope.sh"
root=$(mktemp -d)
trap 'rm -rf -- "$root"' EXIT
pass=0; failn=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { failn=$((failn + 1)); echo "FAIL $1"; sed 's/^/     /' "$root/out" 2> /dev/null; }
check() { local d=$1; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }

mkdir -p "$root/t"
printf '#!/usr/bin/env bash\nsleep 1; echo "alpha ran"; exit 0\n' > "$root/t/a.sh"
printf '#!/usr/bin/env bash\necho "FAIL the deliberate one"; echo "details of beta"; exit 3\n' > "$root/t/b.sh"
printf '#!/usr/bin/env bash\nsleep 1; echo "gamma ran"\n' > "$root/t/c.sh"
printf '#!/usr/bin/env bash\nsleep 30\n' > "$root/t/hang.sh"
run() { bash "$runner" "$@" > "$root/out" 2>&1; rc=$?; }

run --jobs 3 "$root/t/a.sh" "$root/t/b.sh" "$root/t/c.sh"
check "a failing fixture: the runner exits 1 and names the failing script with its buffered output" bash -c "[ $rc = 1 ] && grep -q 'FAIL $root/t/b.sh (exit 3' '$root/out' && grep -q 'details of beta' '$root/out' && grep -q 'Summary: 2 passed, 1 failed' '$root/out' && grep -q '::error::failed: $root/t/b.sh' '$root/out'"
check "the results come in the order of the file list, whatever finished first (b is quick, a and c take a second)" bash -c "a=\$(grep -n 'a.sh (' '$root/out' | head -1 | cut -d: -f1); b=\$(grep -n 'b.sh (' '$root/out' | head -1 | cut -d: -f1); c=\$(grep -n 'c.sh (' '$root/out' | head -1 | cut -d: -f1); [ \$a -lt \$b ] && [ \$b -lt \$c ]"
check "the output of a passing test is not shown" bash -c "! grep -q 'alpha ran' '$root/out'"
run --jobs 3 "$root/t/a.sh" "$root/t/c.sh"
check "only passing fixtures: exit 0, the summary says so" bash -c "[ $rc = 0 ] && grep -q 'Summary: 2 passed, 0 failed' '$root/out'"
start=$(date +%s); run --jobs 2 "$root/t/a.sh" "$root/t/c.sh"; took=$(( $(date +%s) - start ))
check "two one-second tests with two at a time take about one second, not two (they really run in parallel)" test "$took" -lt 2 -o "$took" = 2
TEST_TIMEOUT=2 run --jobs 2 "$root/t/hang.sh" "$root/t/a.sh"
check "a hanging fixture hits the timeout: FAIL with the timeout, exit 1, the other test still passes" bash -c "[ $rc = 1 ] && grep -q 'FAIL $root/t/hang.sh (timed out after 2 s)' '$root/out' && grep -q 'PASS $root/t/a.sh' '$root/out'"
run --jobs 0 "$root/t/a.sh"
check "--jobs 0 is refused (exit 2)" test "$rc" = 2
run --jobs 2 "$root/t/missing.sh"
check "a missing file is a failing test, not a crash" bash -c "[ $rc = 1 ] && grep -q 'FAIL $root/t/missing.sh' '$root/out'"
(cd "$root" && mkdir -p tests && cp t/a.sh tests/x.sh && bash "$runner" > "$root/out" 2>&1; echo $? > "$root/rc"); rc=$(cat "$root/rc")
check "without arguments it runs tests/*.sh of the current directory" bash -c "[ $rc = 0 ] && grep -q 'PASS tests/x.sh' '$root/out'"
check "the workflow runs it with four at a time" grep -q 'run-tests.sh --jobs 4' "$here/.github/workflows/test.yml"

# ---- test-scope.sh: documentation only?
repo="$root/repo"; mkdir -p "$repo/docs" "$repo/tests" "$repo/system_files"
(
    cd "$repo" && git init -q -b main . && git config user.email t@example.invalid && git config user.name t
    echo a > README.md; echo a > docs/x.md; echo a > LICENSE; echo a > .gitignore; echo a > tests/t.sh; echo a > system_files/f
    git add -A && git commit -qm base
    echo b >> README.md; echo b >> docs/x.md; git commit -qam docs
    echo b >> tests/t.sh; git commit -qam test
    echo b >> system_files/f; echo b >> README.md; git commit -qam mixed
    echo b >> docs/x.md; git commit -qam docs2
)
c=($(cd "$repo" && git rev-list --reverse HEAD)); base=${c[0]}; d1=${c[1]}; t1=${c[2]}; mx=${c[3]}; d2=${c[4]}
sc() { (cd "$repo" && bash "$scope" "$@" 2> "$root/err"); }
check "documentation files only: docs" test "$(sc push "$base" "$d1")" = docs
check "a changed test is NOT documentation here: full" test "$(sc push "$d1" "$t1")" = full
check "a mixed push: full" test "$(sc push "$t1" "$mx")" = full
check "a push range that is documentation again: docs" test "$(sc push "$mx" "$d2")" = docs
check "a range that includes a non-documentation commit: full" test "$(sc push "$base" "$d2")" = full
check "a first push of a branch (before is all zeros): full" test "$(sc push 0000000000000000000000000000000000000000 "$d1")" = full
check "an unknown before commit: full" test "$(sc push 1111111111111111111111111111111111111111 "$d1")" = full
check "an empty before: full" test "$(sc push "" "$d1")" = full
check "a manual dispatch: full" test "$(sc workflow_dispatch "$base" "$d1")" = full
check "an empty diff: full" test "$(sc push "$d1" "$d1")" = full
check "outside a repository (git fails): full, the default of every doubt" bash -c "cd '$root' && [ \"\$(bash '$scope' push $base $d1 2>/dev/null)\" = full ]"
check "--doc-tests lists the tests that read README, CLAUDE, CONFIG-GUIDE or docs/ (derived, not a fixed list)" bash -c "cd '$here' && bash '$scope' --doc-tests | grep -q 'tests/readme-defaults.sh'"
echo; echo "passed: $pass, failed: $failn"
[ "$failn" = 0 ]
