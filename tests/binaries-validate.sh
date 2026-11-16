#!/usr/bin/env bash
# Tests for the decisions of binaries-component.yml (known-failure skip, publishing only from testing and main): its own steps are run per event and input.
# Run: tests/binaries-validate.sh
# Needs: bash, python3 with PyYAML.
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
root=$(mktemp -d); trap 'rm -rf -- "$root"' EXIT
pass=0; failn=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { failn=$((failn + 1)); echo "FAIL $1"; sed 's/^/     /' "$root/out" 2>/dev/null; }
check() { local d=$1; shift; if "$@" >"$root/out" 2>&1; then ok "$d"; else bad "$d"; fi; }
python3 -I - "$here" "$root" <<'PY'
import sys, yaml
root, out = sys.argv[1:3]
w = yaml.safe_load(open(f"{root}/.github/workflows/binaries-component.yml"))
final = [s for s in w["jobs"]["check"]["steps"] if s.get("id") == "final"][0]
open(f"{out}/final.sh", "w").write(final["run"])
chan = [s for s in w["jobs"]["build"]["steps"] if s.get("id") == "channel"][0]
open(f"{out}/channel.sh", "w").write(chan["run"])
PY
final() { : >"$root/gho"; env OPTIONAL=false KNOWN_FAIL_HIT=false COMPONENT=scx LOOKUP=true EVENT=push "$@" GITHUB_OUTPUT="$root/gho" bash "$root/final.sh" >"$root/out" 2>&1; }
val() { grep -qx "$1" "$root/gho"; }
final OPTIONAL=true KNOWN_FAIL_HIT=true LOOKUP=false EVENT=push
check "known failure: an optional component whose exact key failed before is not built again on a push (knownfail=true)" bash -c "grep -qx 'knownfail=true' '$root/gho'"
final OPTIONAL=true KNOWN_FAIL_HIT=true LOOKUP=false EVENT=schedule
check "known failure: the daily scheduled run tries again (knownfail=false)" bash -c "grep -qx 'knownfail=false' '$root/gho'"
final OPTIONAL=true KNOWN_FAIL_HIT=true LOOKUP=true EVENT=push
check "known failure: an image that exists is reused, nothing to skip" bash -c "grep -qx 'knownfail=false' '$root/gho'"
final OPTIONAL=false KNOWN_FAIL_HIT=true LOOKUP=false EVENT=push
check "known failure: a REQUIRED component is never skipped, whatever the cache says" bash -c "grep -qx 'knownfail=false' '$root/gho'"
final OPTIONAL=true KNOWN_FAIL_HIT=false LOOKUP=false EVENT=push
check "known failure: no marker, no skip" bash -c "grep -qx 'knownfail=false' '$root/gho'"
chan() { : >"$root/gho"; env REF="$1" GITHUB_OUTPUT="$root/gho" bash "$root/channel.sh" >"$root/out" 2>&1; }
chan refs/heads/main;  check "channel: main publishes" grep -qx 'publish=true' "$root/gho"
chan refs/heads/testing; check "channel: testing publishes" grep -qx 'publish=true' "$root/gho"
chan refs/heads/feat/x; check "channel: another ref never publishes" grep -qx 'publish=false' "$root/gho"
echo; echo "passed: $pass, failed: $failn"; [ "$failn" = 0 ]
