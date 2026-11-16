#!/usr/bin/env bash
# Tests for the own runs of binaries.yml (the README badge): the push trigger and its paths, the weekly validation, and the decisions that keep an own run from
# publishing or racing the caller: the workflow's own steps are run with each combination of event, caller and input. Run: tests/binaries-validate.sh
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
w2 = yaml.safe_load(open(f"{root}/.github/workflows/binaries.yml"))
chan2 = [s for s in w2["jobs"]["assemble"]["steps"] if s.get("id") == "channel"][0]
open(f"{out}/channel2.sh", "w").write(chan2["run"])
fin2 = [s for s in w2["jobs"]["assemble"]["steps"] if s.get("id") == "final"][0]
open(f"{out}/final2.sh", "w").write(fin2["run"])
PY
final() { : >"$root/gho"; env OPTIONAL=false KNOWN_FAIL_HIT=false COMPONENT=scx LOOKUP=true OWN=false EVENT=push "$@" GITHUB_OUTPUT="$root/gho" bash "$root/final.sh" >"$root/out" 2>&1; }
val() { grep -qx "$1" "$root/gho"; }
final OWN=true EVENT=push
check "own push run: no publishing, but an already signed image of the tree is reused (usable stays true): the caller's run is the one that publishes" bash -c "grep -qx 'nopublish=true' '$root/gho' && grep -qx 'usable=true' '$root/gho'"
final OWN=true EVENT=push LOOKUP=false
check "own push run, image missing: usable false (it builds to prove the content builds) but nopublish true: no push, no sign, nothing races the caller's publish" bash -c "grep -qx 'nopublish=true' '$root/gho' && grep -qx 'usable=false' '$root/gho'"
final OWN=true EVENT=schedule
check "own weekly run: the reuse shortcut is IGNORED (usable false although a signed image exists) and nothing is published" bash -c "grep -qx 'nopublish=true' '$root/gho' && grep -qx 'usable=false' '$root/gho'"
final OWN=false EVENT=push
check "the caller's push run (build.yml, github.workflow is the caller's name): unchanged, publishes, reuses when the image exists" bash -c "grep -qx 'nopublish=false' '$root/gho' && grep -qx 'usable=true' '$root/gho'"
final OWN=false EVENT=schedule
check "the caller's scheduled daily run: unchanged (a schedule of ANOTHER workflow is not the validation)" bash -c "grep -qx 'nopublish=false' '$root/gho' && grep -qx 'usable=true' '$root/gho'"
final OWN=true EVENT=workflow_dispatch
check "a plain dispatch of the workflow: unchanged (publishes on main and testing, reuses)" bash -c "grep -qx 'nopublish=false' '$root/gho' && grep -qx 'usable=true' '$root/gho'"
final OPTIONAL=true KNOWN_FAIL_HIT=true LOOKUP=false OWN=false EVENT=push
check "known failure: an optional component whose exact key failed before is not built again on a push (knownfail=true)" bash -c "grep -qx 'knownfail=true' '$root/gho'"
final OPTIONAL=true KNOWN_FAIL_HIT=true LOOKUP=false OWN=false EVENT=schedule
check "known failure: the daily scheduled run tries again (knownfail=false)" bash -c "grep -qx 'knownfail=false' '$root/gho'"
final OPTIONAL=true KNOWN_FAIL_HIT=true LOOKUP=true OWN=false EVENT=push
check "known failure: an image that exists is reused, nothing to skip" bash -c "grep -qx 'knownfail=false' '$root/gho'"
final OPTIONAL=false KNOWN_FAIL_HIT=true LOOKUP=false OWN=false EVENT=push
check "known failure: a REQUIRED component is never skipped, whatever the cache says" bash -c "grep -qx 'knownfail=false' '$root/gho'"
final OPTIONAL=true KNOWN_FAIL_HIT=false LOOKUP=false OWN=false EVENT=push
check "known failure: no marker, no skip" bash -c "grep -qx 'knownfail=false' '$root/gho'"
chan() { : >"$root/gho"; env REF="$1" NOPUBLISH="$2" GITHUB_OUTPUT="$root/gho" bash "$root/channel.sh" >"$root/out" 2>&1; }
chan refs/heads/main false;  check "channel: main publishes" grep -qx 'publish=true' "$root/gho"
chan refs/heads/main true;   check "channel: an own push or weekly run on main does NOT publish" grep -qx 'publish=false' "$root/gho"
chan refs/heads/testing true; check "channel: an own push run on testing does NOT publish" grep -qx 'publish=false' "$root/gho"
chan refs/heads/feat/x false; check "channel: another ref never publishes" grep -qx 'publish=false' "$root/gho"
chan2() { : >"$root/gho"; env REF="$1" OWN="$2" EVENT="$3" GITHUB_OUTPUT="$root/gho" bash "$root/channel2.sh" >"$root/out" 2>&1; }
chan2 refs/heads/main false schedule; check "assemble: the caller's daily run on main publishes" bash -c "grep -qx 'publish=true' '$root/gho' && grep -qx 'nopublish=false' '$root/gho'"
chan2 refs/heads/main true push;      check "assemble: an own push run does not publish" bash -c "grep -qx 'publish=false' '$root/gho' && grep -qx 'nopublish=true' '$root/gho'"
chan2 refs/heads/main true schedule;  check "assemble: the own weekly run does not publish" grep -qx 'publish=false' "$root/gho"
chan2 refs/heads/feat/x false workflow_dispatch; check "assemble: another ref never publishes" grep -qx 'publish=false' "$root/gho"
final2() { : >"$root/gho"; env LOOKUP=true LOOKUP_DIGEST=sha256:x OWN=false EVENT=push NOPUBLISH=false "$@" GITHUB_OUTPUT="$root/gho" bash "$root/final2.sh" >"$root/out" 2>&1; }
final2 OWN=true EVENT=schedule NOPUBLISH=true;  check "assemble: the own weekly run ignores an existing assembled image (usable false)" grep -qx 'usable=false' "$root/gho"
final2 OWN=true EVENT=push NOPUBLISH=true;      check "assemble: an own push run reuses an assembled image the caller published" grep -qx 'usable=true' "$root/gho"
final2 LOOKUP=;                                check "assemble: no lookup result means not usable" grep -qx 'usable=false' "$root/gho"
echo; echo "passed: $pass, failed: $failn"; [ "$failn" = 0 ]
