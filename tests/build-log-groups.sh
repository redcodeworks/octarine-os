#!/usr/bin/env bash
# Tests for the GitHub Actions log groups of the image build scripts: every ::group:: has its ::endgroup:: (counted per script, and in the
# order group, endgroup, group, endgroup with no nesting for the straight-line scripts), a failing script still closes its group and prints
# the ::error:: line outside it, and the exit status is unchanged. Run: tests/build-log-groups.sh. Needs: bash, awk.
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
root=$(mktemp -d); trap 'rm -rf -- "$root"' EXIT
pass=0; failn=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { failn=$((failn + 1)); echo "FAIL $1"; sed 's/^/     /' "$root/out" 2>/dev/null; }
check() { local d=$1; shift; if "$@" >"$root/out" 2>&1; then ok "$d"; else bad "$d"; fi; }

scripts="build_files/build.sh build_files/install-binaries.sh build_files/gen-schedulers.sh build_files/final-cleanup.sh build_files/validate-repos.sh variants/dx/dx.sh variants/nvidia/nvidia.sh"
for s in $scripts; do
    f="$here/$s"
    check "$s: every ::group:: line has a matching ::endgroup:: (counts by line)" bash -c "g=\$(grep -cE 'echo \"::group::' '$f'); e=\$(grep -cE 'echo \"::endgroup::\"' '$f'); [ \"\$g\" -ge 1 ] && [ \"\$g\" -le \"\$e\" ]"
    check "$s: an EXIT trap closes the group and prints ::error:: on failure" grep -qE "^trap 'rc=\\\$\\?;.*::endgroup::.*::error::" "$f"
    check "$s: bash -n" bash -n "$f"
done
# Order check: in the text of each script the ::group:: / ::endgroup:: lines of straight-line code alternate (a group never opens inside
# another one). build.sh holds the optional-package groups in a loop (a group per iteration, closed on both branches), so the loop body is
# read as the sequence group, endgroup, group, endgroup too: that is what the awk below checks on the file order.
for s in $scripts; do
    check "$s: groups never nest (file order alternates group and endgroup; the trap line is the closing one at the top)" bash -c "awk '
        /echo \"::group::/ && !/^trap/ { if (open) { print \"nested group at line \" NR; bad = 1 } open = 1 }
        /echo \"::endgroup::\"/ && !/^trap/ { open = 0 }
        END { exit bad }' '$f'" f="$here/$s"
done
# Behavior of the scripts that can run anywhere
export PATH="$root/bin:$PATH"; mkdir -p "$root/bin"
run() { "$@" >"$root/run" 2>&1; echo $? >"$root/rc"; }
run env BINARIES_ROOT="$root/empty" DESTDIR="$root/dest" bash "$here/build_files/install-binaries.sh"
check "install-binaries.sh failing: exit 1, group closed, ::error:: printed after the endgroup" bash -c "[ \"\$(cat '$root/rc')\" = 1 ] && grep -n '' '$root/run' | awk -F: '/::group::/{g=\$1} /::endgroup::/{e=\$1} /::error::install-binaries.sh failed/{r=\$1} END{exit !(g && e > g && r > e)}'"
run env REPO_DIRS="$root/none" DNF5="$root/no-dnf5" bash "$here/build_files/validate-repos.sh"
check "validate-repos.sh passing: exit 0, the group is opened and closed once" bash -c "[ \"\$(cat '$root/rc')\" = 0 ] && [ \$(grep -c '^::group::' '$root/run') = 1 ] && [ \$(grep -c '^::endgroup::' '$root/run') = 1 ] && ! grep -q '::error::' '$root/run'"
printf '#!/bin/sh\nprintf "repo id  name\\nrogue  x\\n"\n' >"$root/bin/dnf5"; chmod +x "$root/bin/dnf5"
run env REPO_DIRS="$root/none" bash "$here/build_files/validate-repos.sh"
check "validate-repos.sh failing: exit 1, ::error:: after the endgroup" bash -c "[ \"\$(cat '$root/rc')\" = 1 ] && grep -n '' '$root/run' | awk -F: '/::group::/{g=\$1} /::endgroup::/{e=\$1} /::error::validate-repos.sh failed/{r=\$1} END{exit !(g && e > g && r > e)}'"
# harmless outside Actions: nothing but text lines, no other effect
check "the log lines are plain echo lines (no workflow command is ever executed or written to a file)" bash -c "! grep -nE 'GITHUB_(OUTPUT|ENV|STEP_SUMMARY)|set-output' $(for s in $scripts; do printf '%s ' "$here/$s"; done)"
echo; echo "$pass passed, $failn failed"; [ "$failn" = 0 ]
