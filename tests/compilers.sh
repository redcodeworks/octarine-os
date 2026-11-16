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

# the critical list of build.sh: the words of the first `dnf5 install -y` after the CRITICAL comment
crit_build=$(awk '/^# CRITICAL/{f=1} f&&/^dnf5 install -y/{g=1;next} g{print} g&&!/\\$/{exit}' "$here/build_files/build.sh" | sed 's/\\//' | tr -s ' \t' '\n' | sed '/^$/d' | sort | tr '\n' ' ')
crit_wf=$(grep -m1 '^ *CRITICAL="' "$here/.github/scripts/default-smoke.sh" | sed 's/^ *CRITICAL="//; s/"$//' | tr ' ' '\n' | sort | tr '\n' ' ')
check "the CRITICAL list of default-smoke.sh (build.yml runs it) equals the critical tier of build.sh" bash -c "[ -n '$crit_build' ] && [ '$crit_build' = '$crit_wf' ]"
check "gcc, gcc-c++, make and binutils are in the critical tier" bash -c "for p in gcc gcc-c++ make binutils; do grep -qw -- \$p <<<'$crit_build' || exit 1; done"
check "the compilers are not in an optional group of build.sh" bash -c "! grep -E '^    \"[a-z]+:.*\\b(gcc|gcc-c\\+\\+|make|binutils)\\b' '$here/build_files/build.sh'"
check "no test or script still says the default image has no compilers" bash -c "! grep -rIiE 'no compilers|carries no compilers|has none \\(neither' '$here/README.md' '$here/CLAUDE.md' '$here/docs/CONFIG-GUIDE.md' '$here/build_files' '$here/system_files/usr/share/ublue-os/distrobox'"
for w in build; do
    check "$w.yml runs the compiler smoke test on the built image" python3 -I - "$here/.github/workflows/$w.yml" <<'PY'
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
steps = [s for j in wf["jobs"].values() for s in j.get("steps", []) if s.get("name") == "Compiler smoke test"]
assert len(steps) == 1, steps
assert "compiler-smoke.sh" in steps[0]["run"] and "podman run" in steps[0]["run"], steps[0]
PY
done
check "compiler-smoke.sh parses and is executable" bash -c "bash -n '$here/.github/scripts/compiler-smoke.sh' && [ -x '$here/.github/scripts/compiler-smoke.sh' ]"
if command -v gcc >/dev/null && command -v g++ >/dev/null && command -v make >/dev/null && command -v ld >/dev/null && command -v as >/dev/null && command -v ar >/dev/null; then
    check "compiler-smoke.sh passes where the toolchain is installed" bash "$here/.github/scripts/compiler-smoke.sh"
else
    echo "skip compiler-smoke.sh run (no full gcc, g++, make, binutils on this host; CI runs it inside the image)"
fi
# a toolchain that cannot link must fail the script (a fake gcc that exits 1)
mkdir -p "$root/bin"; for t in gcc g++; do printf '#!/bin/sh\n[ "$1" = --version ] && { echo fake; exit 0; }\nexit 1\n' >"$root/bin/$t"; done
for t in make ld; do printf '#!/bin/sh\necho fake\n' >"$root/bin/$t"; done
chmod +x "$root/bin"/*
check "a gcc that cannot compile makes the script fail" bash -c "! PATH='$root/bin:'\"\$PATH\" bash '$here/.github/scripts/compiler-smoke.sh'"
echo; echo "$pass passed, $failn failed"; [ "$failn" = 0 ]
