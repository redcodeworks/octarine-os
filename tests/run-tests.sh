#!/usr/bin/env bash
# Tests .github/scripts/run-tests.sh (the parallel shell test runner)
# with fixture scripts in a scratch directory. Run: tests/run-tests.sh
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
runner="$here/.github/scripts/run-tests.sh"
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
TEST_TIMEOUT=2 run --jobs 2 "$root/t/hang.sh" "$root/t/a.sh"
check "a hanging fixture hits the timeout: FAIL with the timeout, exit 1, the other test still passes" bash -c "[ $rc = 1 ] && grep -q 'FAIL $root/t/hang.sh (timed out after 2 s)' '$root/out' && grep -q 'PASS $root/t/a.sh' '$root/out'"
run --jobs 0 "$root/t/a.sh"
check "--jobs 0 is refused (exit 2)" test "$rc" = 2
run --jobs 2 "$root/t/missing.sh"
check "a missing file is a failing test, not a crash" bash -c "[ $rc = 1 ] && grep -q 'FAIL $root/t/missing.sh' '$root/out'"
(cd "$root" && mkdir -p tests && cp t/a.sh tests/x.sh && bash "$runner" > "$root/out" 2>&1; echo $? > "$root/rc"); rc=$(cat "$root/rc")
check "without arguments it runs tests/*.sh of the current directory" bash -c "[ $rc = 0 ] && grep -q 'PASS tests/x.sh' '$root/out'"

echo; echo "passed: $pass, failed: $failn"
[ "$failn" = 0 ]
