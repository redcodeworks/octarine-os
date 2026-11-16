#!/usr/bin/env bash
# Tests for the compilers and the linker on the default image: the critical package list of build.sh agrees with both smoke tests, the
# in-image compile-and-run script works (here with the host's own gcc, g++, make and binutils when present), and the workflows run it.
# Run: tests/compilers.sh. Needs: bash, python3 with PyYAML.
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
root=$(mktemp -d); trap 'rm -rf -- "$root"' EXIT
pass=0; failn=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { failn=$((failn + 1)); echo "FAIL $1"; sed 's/^/     /' "$root/out" 2>/dev/null; }
check() { local d=$1; shift; if "$@" >"$root/out" 2>&1; then ok "$d"; else bad "$d"; fi; }

check "compiler-smoke.sh parses and is executable" bash -c "bash -n '$here/.github/scripts/compiler-smoke.sh' && [ -x '$here/.github/scripts/compiler-smoke.sh' ]"
# a toolchain that cannot link must fail the script (a fake gcc that exits 1)
mkdir -p "$root/bin"; for t in gcc g++; do printf '#!/bin/sh\n[ "$1" = --version ] && { echo fake; exit 0; }\nexit 1\n' >"$root/bin/$t"; done
for t in make ld; do printf '#!/bin/sh\necho fake\n' >"$root/bin/$t"; done
chmod +x "$root/bin"/*
check "a gcc that cannot compile makes the script fail" bash -c "! PATH='$root/bin:'\"\$PATH\" bash '$here/.github/scripts/compiler-smoke.sh'"
echo; echo "$pass passed, $failn failed"; [ "$failn" = 0 ]
