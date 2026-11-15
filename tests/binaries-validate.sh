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
unset GITHUB_OUTPUT GITHUB_ENV GITHUB_STEP_SUMMARY
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
final() { : >"$root/gho"; env OPTIONAL=false KNOWN_FAIL_HIT=false COMPONENT=scx LOOKUP=true SIMULATE_LIST= OWN=false EVENT=push VALIDATE_ONLY=false "$@" GITHUB_OUTPUT="$root/gho" bash "$root/final.sh" >"$root/out" 2>&1; }
val() { grep -qx "$1" "$root/gho"; }
final OWN=true EVENT=push
check "own push run: no publishing, but an already signed image of the tree is reused (usable stays true): the caller's run is the one that publishes" bash -c "grep -qx 'nopublish=true' '$root/gho' && grep -qx 'usable=true' '$root/gho'"
final OWN=true EVENT=push LOOKUP=false
check "own push run, image missing: usable false (it builds to prove the content builds) but nopublish true: no push, no sign, nothing races the caller's publish" bash -c "grep -qx 'nopublish=true' '$root/gho' && grep -qx 'usable=false' '$root/gho'"
final OWN=true EVENT=schedule
check "own weekly run: the reuse shortcut is IGNORED (usable false although a signed image exists) and nothing is published" bash -c "grep -qx 'nopublish=true' '$root/gho' && grep -qx 'usable=false' '$root/gho'"
final OWN=true EVENT=workflow_dispatch VALIDATE_ONLY=true
check "dispatch with validate_only: the same as the weekly run (rebuild, publish nothing)" bash -c "grep -qx 'nopublish=true' '$root/gho' && grep -qx 'usable=false' '$root/gho'"
final OWN=false EVENT=push
check "the caller's push run (build.yml, github.workflow is the caller's name): unchanged, publishes, reuses when the image exists" bash -c "grep -qx 'nopublish=false' '$root/gho' && grep -qx 'usable=true' '$root/gho'"
final OWN=false EVENT=schedule
check "the caller's scheduled daily run: unchanged (a schedule of ANOTHER workflow is not the validation)" bash -c "grep -qx 'nopublish=false' '$root/gho' && grep -qx 'usable=true' '$root/gho'"
final OWN=true EVENT=workflow_dispatch
check "a plain dispatch of the workflow: unchanged (publishes on main and testing, reuses)" bash -c "grep -qx 'nopublish=false' '$root/gho' && grep -qx 'usable=true' '$root/gho'"
final OWN=true EVENT=workflow_dispatch SIMULATE_LIST=scx
check "a simulated build failure of THIS component skips its reuse and publishes as before" bash -c "grep -qx 'usable=false' '$root/gho' && grep -qx 'nopublish=false' '$root/gho'"
final OWN=true EVENT=workflow_dispatch SIMULATE_LIST=extest,ghostty
check "a rehearsal that names OTHER components leaves this one alone (reuse stays)" bash -c "grep -qx 'usable=true' '$root/gho'"
final OWN=true EVENT=workflow_dispatch SIMULATE_LIST=all
check "a rehearsal of all components skips the reuse of every one" bash -c "grep -qx 'usable=false' '$root/gho'"
final OWN=true EVENT=workflow_dispatch SIMULATE_LIST=true
check "the old boolean spelling (true) still means all components" bash -c "grep -qx 'usable=false' '$root/gho'"
final OPTIONAL=true KNOWN_FAIL_HIT=true LOOKUP=false OWN=false EVENT=push
check "known failure: an optional component whose exact key failed before is not built again on a push (knownfail=true)" bash -c "grep -qx 'knownfail=true' '$root/gho'"
final OPTIONAL=true KNOWN_FAIL_HIT=true LOOKUP=false OWN=false EVENT=schedule
check "known failure: the daily scheduled run tries again (knownfail=false)" bash -c "grep -qx 'knownfail=false' '$root/gho'"
final OPTIONAL=true KNOWN_FAIL_HIT=true LOOKUP=false OWN=true EVENT=workflow_dispatch VALIDATE_ONLY=true
check "known failure: a validation run builds again" bash -c "grep -qx 'knownfail=false' '$root/gho'"
final OPTIONAL=true KNOWN_FAIL_HIT=true LOOKUP=false OWN=true EVENT=workflow_dispatch SIMULATE_LIST=scx
check "known failure: a rehearsal builds again" bash -c "grep -qx 'knownfail=false' '$root/gho'"
final OPTIONAL=true KNOWN_FAIL_HIT=true LOOKUP=true OWN=false EVENT=push
check "known failure: an image that exists is reused, nothing to skip" bash -c "grep -qx 'knownfail=false' '$root/gho'"
final OPTIONAL=false KNOWN_FAIL_HIT=true LOOKUP=false OWN=false EVENT=push
check "known failure: a REQUIRED component is never skipped, whatever the cache says" bash -c "grep -qx 'knownfail=false' '$root/gho'"
final OPTIONAL=true KNOWN_FAIL_HIT=false LOOKUP=false OWN=false EVENT=push
check "known failure: no marker, no skip" bash -c "grep -qx 'knownfail=false' '$root/gho'"
check "known failure: the marker is saved only after a failed optional build and never on a pull request; the build job is skipped on a known failure; the cache action is the pinned one" python3 -I - "$here" <<'PY'
import sys, yaml
w = yaml.safe_load(open(sys.argv[1] + "/.github/workflows/binaries-component.yml")); j = w["jobs"]
assert "needs.check.outputs.knownfail != 'true'" in j["build"]["if"]
save = [s for s in j["build"]["steps"] if "cache/save" in s.get("uses", "") and "known-fail" in s["with"]["key"]][0]
assert "inputs.optional" in save["if"] and "github.event_name != 'pull_request'" in save["if"] and "steps.record.outputs.ok == 'false'" in save["if"]
assert save["uses"].startswith("actions/cache/save@55cc8345863c7cc4c66a329aec7e433d2d1c52a9")
rest = [s for s in j["check"]["steps"] if "cache/restore" in s.get("uses", "")][0]
assert rest["with"]["lookup-only"] is True and rest["uses"].startswith("actions/cache/restore@55cc8345863c7cc4c66a329aec7e433d2d1c52a9")
PY
chan() { : >"$root/gho"; env REF="$1" NOPUBLISH="$2" GITHUB_OUTPUT="$root/gho" bash "$root/channel.sh" >"$root/out" 2>&1; }
chan refs/heads/main false;  check "channel: main publishes" grep -qx 'publish=true' "$root/gho"
chan refs/heads/main true;   check "channel: an own push or weekly run on main does NOT publish" grep -qx 'publish=false' "$root/gho"
chan refs/heads/testing true; check "channel: an own push run on testing does NOT publish" grep -qx 'publish=false' "$root/gho"
chan refs/heads/feat/x false; check "channel: another ref never publishes" grep -qx 'publish=false' "$root/gho"
chan2() { : >"$root/gho"; env REF="$1" OWN="$2" EVENT="$3" VALIDATE_ONLY="$4" GITHUB_OUTPUT="$root/gho" bash "$root/channel2.sh" >"$root/out" 2>&1; }
chan2 refs/heads/main false schedule false; check "assemble: the caller's daily run on main publishes" bash -c "grep -qx 'publish=true' '$root/gho' && grep -qx 'nopublish=false' '$root/gho'"
chan2 refs/heads/main true push false;      check "assemble: an own push run does not publish" bash -c "grep -qx 'publish=false' '$root/gho' && grep -qx 'nopublish=true' '$root/gho'"
chan2 refs/heads/main true schedule false;  check "assemble: the own weekly run does not publish" grep -qx 'publish=false' "$root/gho"
chan2 refs/heads/testing true workflow_dispatch true; check "assemble: validate_only does not publish" grep -qx 'publish=false' "$root/gho"
chan2 refs/heads/feat/x false workflow_dispatch false; check "assemble: another ref never publishes" grep -qx 'publish=false' "$root/gho"
final2() { : >"$root/gho"; env LOOKUP=true LOOKUP_DIGEST=sha256:x OWN=false EVENT=push VALIDATE_ONLY=false SIMULATE=false NOPUBLISH=false "$@" GITHUB_OUTPUT="$root/gho" bash "$root/final2.sh" >"$root/out" 2>&1; }
final2 OWN=true EVENT=schedule NOPUBLISH=true;  check "assemble: the own weekly run ignores an existing assembled image (usable false)" grep -qx 'usable=false' "$root/gho"
final2 OWN=true EVENT=push NOPUBLISH=true;      check "assemble: an own push run reuses an assembled image the caller published" grep -qx 'usable=true' "$root/gho"
final2 SIMULATE=true;                          check "assemble: a rehearsal never reuses" grep -qx 'usable=false' "$root/gho"
final2 LOOKUP=;                                check "assemble: no lookup result means not usable" grep -qx 'usable=false' "$root/gho"
check "binaries.yml triggers: push to main and testing for binaries/ and the workflow's own files only, a weekly schedule on Friday 08:00 UTC, and the validate_only input; nothing else is new" python3 -I - "$here" <<'PY'
import sys, yaml
w = yaml.safe_load(open(sys.argv[1] + "/.github/workflows/binaries.yml")); on = w.get(True) or w.get("on")
assert on["push"]["branches"] == ["main", "testing"]
assert set(on["push"]["paths"]) == {"binaries/**", ".github/workflows/binaries.yml", ".github/workflows/binaries-component.yml", ".github/scripts/binaries-*.sh", ".github/scripts/push-tags.sh"}
assert on["schedule"] == [{"cron": "0 8 * * 5"}]
assert on["workflow_dispatch"]["inputs"]["validate_only"]["default"] is False
assert "pull_request" not in on
PY
check "the paths cover every input of the binaries: the content keys are made from binaries/ (its components, lib/ and builder.env), so binaries/** is the whole input; the workflows and scripts that build, check and publish it are the rest" bash -c "cd '$here' && grep -q 'binaries-key.sh' .github/workflows/binaries-component.yml && ls .github/scripts/binaries-*.sh | grep -q . && grep -q 'push-tags.sh' .github/workflows/binaries-component.yml && grep -q 'push-tags.sh' .github/workflows/binaries.yml"
check "nothing of an own run reaches the signing secret or last-good: the sign jobs run only for a published build, the track job only when nopublish is not true, the signing environment is only on the sign jobs" python3 -I - "$here" <<'PY'
import sys, yaml
r = sys.argv[1] + "/.github/workflows/"
w = yaml.safe_load(open(r + "binaries.yml")); c = yaml.safe_load(open(r + "binaries-component.yml"))
j = w["jobs"]
assert "needs.assemble.outputs.published == 'true'" in j["sign"]["if"] and j["sign"]["environment"] == "signing"
assert "needs.build.outputs.published == 'true'" in c["jobs"]["sign"]["if"] and c["jobs"]["sign"]["environment"] == "signing"
assert "needs.assemble.outputs.nopublish != 'true'" in j["track"]["if"]
assert "SIGNING_SECRET" not in str({n: x for n, x in j.items() if n not in ("sign", "component")})
assert "SIGNING_SECRET" not in str({n: x for n, x in c["jobs"].items() if n != "sign"})
PY
check "a failed weekly validation is visible: the component's result job and the assemble's result job fail when something that must exist does not (allow_fallback is the caller's input, absent for an own run, so an own run falls back for no required component)" python3 -I - "$here" <<'PY'
import sys, yaml
r = sys.argv[1] + "/.github/workflows/"
w = yaml.safe_load(open(r + "binaries.yml")); c = yaml.safe_load(open(r + "binaries-component.yml"))
assert "could not be put together" in str(w["jobs"]["result"]["steps"])
f = " ".join(c["jobs"]["fallback"]["if"].split())
assert "inputs.allow_fallback && github.event_name == 'schedule' && github.ref == 'refs/heads/main'" in f
assert "allow_fallback: ${{ inputs.allow_fallback == true }}" in open(r + "binaries.yml").read()
PY
echo; echo "passed: $pass, failed: $failn"; [ "$failn" = 0 ]
