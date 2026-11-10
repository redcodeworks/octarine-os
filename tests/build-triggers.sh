#!/usr/bin/env bash
# Quick checks of the build triggers: build.yml has no pull_request trigger, a dispatch from any other ref is a
# validation build (never logs in, pushes or signs), the aggregate job keeps its required name, and the other
# workflows keep their triggers. Run: tests/build-triggers.sh
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
root=$(mktemp -d)
trap 'rm -rf -- "$root"' EXIT
pass=0
failn=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { failn=$((failn + 1)); echo "FAIL $1"; [ -f "$root/out" ] && sed 's/^/     /' "$root/out"; }
check() { local d=$1; shift; if "$@" >"$root/out" 2>&1; then ok "$d"; else bad "$d"; fi; }

check "build.yml: NO pull_request trigger; push main/testing, schedule, dispatch only" python3 - "$here" <<'PY'
import sys, yaml
w = yaml.safe_load(open(sys.argv[1] + "/.github/workflows/build.yml"))
on = w.get(True) or w.get("on")
assert "pull_request" not in on and "pull_request_target" not in on, set(on)
assert on["push"] == {"branches": ["main", "testing"]}, on["push"]
assert set(on) == {"push", "schedule", "workflow_dispatch"}, set(on)
assert on["schedule"] == [{"cron": "0 11 * * *"}]
PY
check "build.yml: concurrency is per ref and cancels everything but main and schedule" python3 - "$here" <<'PY'
import sys, yaml
c = yaml.safe_load(open(sys.argv[1] + "/.github/workflows/build.yml"))["concurrency"]
assert "github.ref" in c["group"] and "github.workflow" in c["group"], c
assert c["cancel-in-progress"] == "${{ github.ref != 'refs/heads/main' && github.event_name != 'schedule' }}", c
PY
check "build.yml: only main and testing publish (channel step); a dispatch from any other ref is validation only" bash -s -- "$here" "$root" <<'SH'
python3 - "$1" "$2" <<'PY'
import sys, yaml
w = yaml.safe_load(open(sys.argv[1] + "/.github/workflows/build.yml"))
run = {s.get("name"): s for s in w["jobs"]["build_push"]["steps"]}["Choose channel"]["run"]
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
check "build.yml: login and push run only when publish is true; no other step in the build job logs in, pushes or signs" python3 - "$here" <<'PY'
import sys, yaml
w = yaml.safe_load(open(sys.argv[1] + "/.github/workflows/build.yml"))
gate = "steps.channel.outputs.publish == 'true'"
for s in w["jobs"]["build_push"]["steps"]:
    text = str(s.get("uses", "")) + " " + str(s.get("run", ""))
    risky = "login-action" in text or "push-tags.sh" in text or "cosign sign" in text or "skopeo copy" in text
    if risky:
        assert s.get("if") == gate, (s.get("name"), s.get("if"))
assert {"Login to GitHub Container Registry", "Push To GHCR"} <= {s["name"] for s in w["jobs"]["build_push"]["steps"]}
PY
check "build.yml: promote only on a main push; sign needs a publish or a promotion, so a validation dispatch never signs" python3 - "$here" <<'PY'
import sys, yaml
w = yaml.safe_load(open(sys.argv[1] + "/.github/workflows/build.yml"))
plan = {s.get("name"): s for s in w["jobs"]["plan"]["steps"]}
assert "github.event_name == 'push' && github.ref == 'refs/heads/main'" in plan["Look for a tested testing image to promote"]["if"]
cond = " ".join(w["jobs"]["sign"]["if"].split())
assert "needs.build_push.outputs.publish == 'true'" in cond and "needs.promote.result == 'success'" in cond, cond
assert w["jobs"]["sign"]["environment"] == "signing"
PY
check "build.yml: aggregate job is named 'Build and push image', always runs (also on push), needs plan, build, promote and sign" python3 - "$here" <<'PY'
import sys, yaml
j = yaml.safe_load(open(sys.argv[1] + "/.github/workflows/build.yml"))["jobs"]["build_result"]
assert j["name"] == "Build and push image" and j["if"] == "always()", j
assert "needs.plan" not in str(j.get("if")) and "event_name" not in str(j.get("if")), j
assert j["needs"] == ["plan", "build_push", "promote", "sign"], j["needs"]
PY
check "build.yml: no code refers to the pull_request event any more" bash -c "! grep -v '^ *#' '$here/.github/workflows/build.yml' | grep -q pull_request"
check "plan-build.sh and aggregate-result.sh: a validation build (no publish, no sign) passes" bash -c "
  cd '$here' && .github/scripts/plan-build.sh workflow_dispatch '' HEAD 2>/dev/null | grep -qx true &&
  PLAN=success BUILD_WANTED=true PROMOTE_WANTED=false PUBLISH=false BUILD=success PROMOTE=skipped SIGN=skipped .github/scripts/aggregate-result.sh"
check "require-testing-branch.yml: pull requests into main only" python3 - "$here" <<'PY'
import sys, yaml
w = yaml.safe_load(open(sys.argv[1] + "/.github/workflows/require-testing-branch.yml"))
on = w.get(True) or w.get("on")
assert on == {"pull_request": {"branches": ["main"]}}, on
PY
check "other workflows have no pull_request trigger (daily, beta, NVIDIA, disk, prune unchanged)" python3 - "$here" <<'PY'
import glob, sys, yaml
for f in glob.glob(sys.argv[1] + "/.github/workflows/*.yml"):
    if f.endswith(("build.yml", "require-testing-branch.yml")):
        continue
    on = yaml.safe_load(open(f)); on = on.get(True) or on.get("on")
    assert "pull_request" not in on and "pull_request_target" not in on, f
PY
check "schedules: on the hour, no two alike, Sunday order prune 05:00, daily 11:00, NVIDIA 12:00" python3 - "$here" <<'PY'
import glob, sys, yaml
crons = {}
for f in glob.glob(sys.argv[1] + "/.github/workflows/*.yml"):
    on = yaml.safe_load(open(f)); on = on.get(True) or on.get("on")
    for s in (on.get("schedule") or []):
        crons[f.rsplit("/", 1)[1]] = s["cron"]
assert crons == {"build.yml": "0 11 * * *", "build-nvidia.yml": "0 12 * * 0", "build-beta.yml": "0 14 * * 3", "prune-testing.yml": "0 5 * * 0"}, crons
assert len(set(crons.values())) == len(crons)
PY

check "build.yml: the reuse step runs only for a push to testing whose plan wants a build, and feeds the verify and final steps" python3 - "$here" <<'PY'
import sys, yaml
w = yaml.safe_load(open(sys.argv[1] + "/.github/workflows/build.yml"))
plan = {s.get("name"): s for s in w["jobs"]["plan"]["steps"]}
r = plan["Look for an identical default-image build on testing"]
assert r["id"] == "reuse"
assert r["if"] == "steps.plan.outputs.build == 'true' && github.event_name == 'push' && github.ref == 'refs/heads/testing'", r["if"]
assert "plan-vanilla-reuse.sh" in r["run"]
v = plan["Verify the signature of the image to promote or reuse"]
assert "steps.reuse.outputs.reuse == 'true'" in v["if"] and "steps.promote.outputs.promote == 'true'" in v["if"]
assert "vanilla-inputs" in v["run"]
assert w["jobs"]["plan"]["outputs"]["source_digest"] == "${{ steps.promote.outputs.source_digest || steps.reuse.outputs.source_digest }}"
PY
check "build.yml: the final decision of the plan: promote, reuse (nothing to build), build, never skip on a failed verification" bash -s -- "$here" "$root" <<'SH'
python3 - "$1" "$2" <<'PY'
import sys, yaml
w = yaml.safe_load(open(sys.argv[1] + "/.github/workflows/build.yml"))
run = {s.get("name"): s for s in w["jobs"]["plan"]["steps"]}["Final decision"]["run"]
open(sys.argv[2] + "/final-step.sh", "w").write(run)
PY
f="$2/final-step.sh"
root=$2
t() { local want=$1; shift; got=$(rm -f "$root/o"; BUILD_PLAN=$1 SCHED_SKIP=$2 CANDIDATE=$3 REUSE=$4 VERIFY=$5 GITHUB_OUTPUT="$root/o" GITHUB_STEP_SUMMARY="$root/sum" bash "$f" >/dev/null 2>&1 </dev/null; echo "$(sed -n 's/^build=//p' "$root/o") $(sed -n 's/^promote=//p' "$root/o")"); [ "$got" = "$want" ] || { echo "$*: got '$got' want '$want'"; exit 1; }; }
t "false true"  true "" true  ""    success   # promote, verified
t "true false"  true "" true  ""    failure   # promote candidate, verification failed: build
t "false false" true "" ""    true  success   # dx-only change on testing: reused image verified, nothing to build
t "true false"  true "" ""    true  failure   # reused image failed verification: build
t "true false"  true "" ""    ""    skipped   # vanilla change: build
t "false false" false "" ""   ""    skipped   # docs-only: plan said no
t "false false" true true ""  ""    skipped   # scheduled skip
SH
check "Justfile: the build labels the image with the vanilla_inputs hash, the scheduled skip compares vanilla_inputs" bash -c "
  grep -q 'io.github.redcodeworks.octarine-os.vanilla-inputs=\$(.github/scripts/inputs-hash.sh vanilla)' '$here/Justfile'
  grep -q 'inputs-hash.sh vanilla \"\${revision}\"' '$here/.github/workflows/build.yml'"
check "build.yml: promotion of main uses plan-promote.sh, which compares vanilla_inputs (a dx-only testing tip promotes the default image)" bash -c "
  grep -q 'plan-promote.sh' '$here/.github/workflows/build.yml' && grep -q 'vanilla_inputs' '$here/.github/scripts/plan-promote.sh' && ! grep -q 'docs_only_between' '$here/.github/scripts/plan-promote.sh'"

echo "passed: $pass, failed: $failn"
[ "$failn" = 0 ]
