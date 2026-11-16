#!/usr/bin/env bash
# Tests for the channel rule of binaries-component.yml (only testing publishes; main only promotes): its own step is run per ref.
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
chan = [s for s in w["jobs"]["build"]["steps"] if s.get("id") == "channel"][0]
open(f"{out}/channel.sh", "w").write(chan["run"])
PY
chan() { : >"$root/gho"; env REF="$1" GITHUB_OUTPUT="$root/gho" bash "$root/channel.sh" >"$root/out" 2>&1; }
chan refs/heads/main;  check "channel: main builds nothing, so it never publishes components" grep -qx 'publish=false' "$root/gho"
chan refs/heads/testing; check "channel: testing publishes" grep -qx 'publish=true' "$root/gho"
chan refs/heads/feat/x; check "channel: another ref never publishes" grep -qx 'publish=false' "$root/gho"
echo; echo "passed: $pass, failed: $failn"; [ "$failn" = 0 ]
