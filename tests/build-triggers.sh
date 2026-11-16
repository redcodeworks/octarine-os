#!/usr/bin/env bash
# Behavior that first runs on main: which refs publish (the channel step of build.yml is run with each ref). Run: tests/build-triggers.sh
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
root=$(mktemp -d)
trap 'rm -rf -- "$root"' EXIT
pass=0
failn=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { failn=$((failn + 1)); echo "FAIL $1"; [ -f "$root/out" ] && sed 's/^/     /' "$root/out"; }
check() { local d=$1; shift; if "$@" >"$root/out" 2>&1; then ok "$d"; else bad "$d"; fi; }

check "build.yml: only main and testing publish (channel step); a dispatch from any other ref is validation only" bash -s -- "$here" "$root" <<'SH'
python3 - "$1" "$2" <<'PY'
import sys, yaml
w = yaml.safe_load(open(sys.argv[1] + "/.github/workflows/build.yml"))
run = {s.get("id"): s for s in w["jobs"]["build_push"]["steps"]}["channel"]["run"]
open(sys.argv[2] + "/channel-step.sh", "w").write(run)
PY
f="$2/channel-step.sh"
for ref in refs/heads/feat/x refs/heads/some-dev refs/tags/v1; do
  rm -f "$2/out"; out=$(EVENT=workflow_dispatch REF=$ref GITHUB_OUTPUT="$2/out" bash "$f" >/dev/null </dev/null && grep -x "publish=.*" "$2/out")
  [ "$out" = "publish=false" ] || { echo "$ref: $out"; exit 1; }
done
for ref in refs/heads/main refs/heads/testing; do
  rm -f "$2/out"; out=$(EVENT=workflow_dispatch REF=$ref GITHUB_OUTPUT="$2/out" bash "$f" >/dev/null </dev/null && grep -x "publish=.*" "$2/out")
  [ "$out" = "publish=true" ] || { echo "$ref: $out"; exit 1; }
done
SH

echo
echo "passed: $pass, failed: $failn"
[ "$failn" = 0 ]
