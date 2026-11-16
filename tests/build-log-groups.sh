#!/usr/bin/env bash
# Behavior of the image build scripts that can run anywhere: a failing script exits 1 and a passing one exits 0 (the ::error:: and log group
# layout is cosmetic and not asserted). Run: tests/build-log-groups.sh. Needs: bash.
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
root=$(mktemp -d); trap 'rm -rf -- "$root"' EXIT
pass=0; failn=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { failn=$((failn + 1)); echo "FAIL $1"; sed 's/^/     /' "$root/out" 2>/dev/null; }
check() { local d=$1; shift; if "$@" >"$root/out" 2>&1; then ok "$d"; else bad "$d"; fi; }

export PATH="$root/bin:$PATH"; mkdir -p "$root/bin"
run() { "$@" >"$root/run" 2>&1; echo $? >"$root/rc"; }
run env BINARIES_ROOT="$root/empty" DESTDIR="$root/dest" bash "$here/build_files/install-binaries.sh"
check "install-binaries.sh with nothing to install: exit 1" test "$(cat "$root/rc")" = 1
run env REPO_DIRS="$root/none" DNF5="$root/no-dnf5" bash "$here/build_files/validate-repos.sh"
check "validate-repos.sh passing: exit 0" test "$(cat "$root/rc")" = 0
printf '#!/bin/sh\nprintf "repo id  name\\nrogue  x\\n"\n' >"$root/bin/dnf5"; chmod +x "$root/bin/dnf5"
run env REPO_DIRS="$root/none" bash "$here/build_files/validate-repos.sh"
check "validate-repos.sh with a rogue repo: exit 1" test "$(cat "$root/rc")" = 1
echo; echo "$pass passed, $failn failed"; [ "$failn" = 0 ]
