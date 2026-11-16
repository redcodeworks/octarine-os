#!/usr/bin/env bash
# Tests .github/scripts/retry.sh (the one retry helper) and that the transient-prone calls of the pipeline go through it. Run: tests/retry.sh
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
root=$(mktemp -d)
trap 'rm -rf -- "${root:?}"' EXIT
pass=0; failn=0; rc=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { failn=$((failn + 1)); echo "FAIL $1"; sed 's/^/     /' "$root/run" 2> /dev/null; echo "     rc=$rc"; }
check() { local d=$1; shift; if "$@" > "$root/out" 2>&1; then ok "$d"; else bad "$d"; fi; }
r="$here/.github/scripts/retry.sh"
export RETRY_DELAY=0
# a command that fails the first N times (counter file), then succeeds
cat > "$root/flaky" <<'F'
#!/usr/bin/env bash
n=$(cat "$COUNT" 2> /dev/null || echo 0); n=$((n + 1)); echo "$n" > "$COUNT"
echo "output of try $n"
[[ "$n" -gt "${FAILS:-2}" ]]
F
chmod +x "$root/flaky"
export COUNT="$root/count"
: > "$COUNT"; rm -f "$COUNT"; FAILS=2 bash "$r" "$root/flaky" > "$root/run" 2>&1; rc=$?
check "fails twice, then succeeds: exit 0 after exactly three tries, the output of the command passes through, each failed try is a warning" bash -c "[ $rc = 0 ] && [ \$(cat '$COUNT') = 3 ] && grep -q 'output of try 3' '$root/run' && [ \$(grep -c '::warning::try' '$root/run') = 2 ] && ! grep -q '::error::' '$root/run'"
rm -f "$COUNT"; FAILS=99 bash "$r" "$root/flaky" > "$root/run" 2>&1; rc=$?
check "always fails: three tries, then the last exit status and a clear error (never success)" bash -c "[ $rc = 1 ] && [ \$(cat '$COUNT') = 3 ] && grep -q '::error::.*failed 3 times' '$root/run'"
rm -f "$COUNT"; bash "$r" -n 5 -- bash -c 'exit 7' > "$root/run" 2>&1; rc=$?
check "-n sets the tries and the exit status of the command is kept (7)" bash -c "[ $rc = 7 ] && [ \$(grep -c '::warning::try' '$root/run') = 4 ]"
rm -f "$COUNT"; FAILS=0 bash "$r" "$root/flaky" > "$root/run" 2>&1; rc=$?
check "a command that works at once runs exactly once" bash -c "[ $rc = 0 ] && [ \$(cat '$COUNT') = 1 ] && ! grep -q '::warning::' '$root/run'"
bash "$r" > "$root/run" 2>&1; rc=$?
check "no command: usage, exit 2" bash -c "[ $rc = 2 ] && grep -q usage '$root/run'"
bash "$r" -n x true > "$root/run" 2>&1; rc=$?
check "bad tries: exit 2" test "$rc" = 2
check "the pause grows with the try number (DELAY times k)" bash -c "RETRY_DELAY=1 bash '$r' -n 3 -- bash -c 'exit 1' 2>&1 | grep -c 'retrying in' | grep -qx 2 && RETRY_DELAY=1 bash '$r' -n 3 -- bash -c 'exit 1' 2>&1 | grep -q 'retrying in 2 s'"
echo; echo "passed: $pass, failed: $failn"
[ "$failn" = 0 ]
