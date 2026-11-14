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
w = yaml.safe_load(open(f"{root}/.github/workflows/binaries.yml"))
final = [s for s in w["jobs"]["check"]["steps"] if s.get("id") == "final"][0]
open(f"{out}/final.sh", "w").write(final["run"])
chan = [s for s in w["jobs"]["build"]["steps"] if s.get("id") == "channel"][0]
open(f"{out}/channel.sh", "w").write(chan["run"])
PY
final() { : >"$root/gho"; env LOOKUP=true SIMULATE=false OWN=false EVENT=push VALIDATE_ONLY=false "$@" GITHUB_OUTPUT="$root/gho" bash "$root/final.sh" >"$root/out" 2>&1; }
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
final OWN=true EVENT=workflow_dispatch SIMULATE=true
check "a simulated build failure still skips the reuse and publishes as before" bash -c "grep -qx 'usable=false' '$root/gho' && grep -qx 'nopublish=false' '$root/gho'"
chan() { : >"$root/gho"; env REF="$1" NOPUBLISH="$2" GITHUB_OUTPUT="$root/gho" bash "$root/channel.sh" >"$root/out" 2>&1; }
chan refs/heads/main false;  check "channel: main publishes" grep -qx 'publish=true' "$root/gho"
chan refs/heads/main true;   check "channel: an own push or weekly run on main does NOT publish" grep -qx 'publish=false' "$root/gho"
chan refs/heads/testing true; check "channel: an own push run on testing does NOT publish" grep -qx 'publish=false' "$root/gho"
chan refs/heads/feat/x false; check "channel: another ref never publishes" grep -qx 'publish=false' "$root/gho"
check "binaries.yml triggers: push to main and testing for binaries/ and the workflow's own files only, a weekly schedule on Friday 08:00 UTC, and the validate_only input; nothing else is new" python3 -I - "$here" <<'PY'
import sys, yaml
w = yaml.safe_load(open(sys.argv[1] + "/.github/workflows/binaries.yml")); on = w.get(True) or w.get("on")
assert on["push"]["branches"] == ["main", "testing"]
assert set(on["push"]["paths"]) == {"binaries/**", ".github/workflows/binaries.yml", ".github/scripts/binaries-*.sh", ".github/scripts/push-tags.sh"}
assert on["schedule"] == [{"cron": "0 8 * * 5"}]
assert on["workflow_dispatch"]["inputs"]["validate_only"]["default"] is False
assert "pull_request" not in on
PY
check "the paths cover every input of the binaries image: its content is the tree of binaries/ (the tag), so binaries/** is the whole input; the scripts that build, check and publish it are the rest" bash -c "cd '$here' && grep -q 'git rev-parse HEAD:binaries' .github/workflows/binaries.yml && ls .github/scripts/binaries-*.sh | grep -q . && grep -q 'push-tags.sh' .github/workflows/binaries.yml"
check "nothing of an own run reaches the signing secret or last-good: the sign job runs only for a published build, the track job only when nopublish is not true, the signing environment is only on the sign job" python3 -I - "$here" <<'PY'
import sys, yaml
w = yaml.safe_load(open(sys.argv[1] + "/.github/workflows/binaries.yml"))
j = w["jobs"]
assert "needs.build.outputs.published == 'true'" in j["sign"]["if"] and j["sign"]["environment"] == "signing"
assert "needs.result.outputs.nopublish != 'true'" in j["track"]["if"]
assert [n for n, x in j.items() if "environment" in x] == ["sign"]
assert "SIGNING_SECRET" not in str({n: x for n, x in j.items() if n != "sign"})
PY
check "a failed weekly validation is visible: the result job fails when the build failed and no fallback applies (allow_fallback is the caller's input, absent for an own run)" python3 -I - "$here" <<'PY'
import sys, yaml
w = yaml.safe_load(open(sys.argv[1] + "/.github/workflows/binaries.yml"))
assert "The binaries build failed" in str(w["jobs"]["result"]["steps"])
assert "inputs.allow_fallback == true && github.event_name == 'schedule'" in " ".join(w["jobs"]["fallback"]["if"].split()), "a fallback needs the caller's allow_fallback, which an own schedule run does not pass"
PY
echo; echo "passed: $pass, failed: $failn"; [ "$failn" = 0 ]
