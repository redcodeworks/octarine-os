#!/usr/bin/env bash
# Invariants of the build triggers: nothing that publishes has a pull_request trigger, only main and testing publish
# (a dispatch from any other ref is a validation build that never logs in, pushes or signs), the aggregate job keeps
# its required name, a job that reads a needed result has its own status function, schedules are on the hour and do
# not collide. The behavior of the plan is tested by plan-*.sh; this file does not restate step names or literal
# conditions. Run: tests/build-triggers.sh
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
root=$(mktemp -d)
trap 'rm -rf -- "$root"' EXIT
pass=0
failn=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { failn=$((failn + 1)); echo "FAIL $1"; [ -f "$root/out" ] && sed 's/^/     /' "$root/out"; }
check() { local d=$1; shift; if "$@" >"$root/out" 2>&1; then ok "$d"; else bad "$d"; fi; }

check "build.yml: NO pull_request trigger; push only main and testing" python3 - "$here" <<'PY'
import sys, yaml
w = yaml.safe_load(open(sys.argv[1] + "/.github/workflows/build.yml"))
on = w.get(True) or w.get("on")
assert "pull_request" not in on and "pull_request_target" not in on, set(on)
assert on["push"] == {"branches": ["main", "testing"]}, on["push"]
PY
check "build.yml: concurrency is per workflow and ref, and the cancel condition spares main" python3 - "$here" <<'PY'
import sys, yaml
c = yaml.safe_load(open(sys.argv[1] + "/.github/workflows/build.yml"))["concurrency"]
assert "github.ref" in c["group"] and "github.workflow" in c["group"], c
assert "refs/heads/main" in str(c["cancel-in-progress"]), c
PY
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
check "build.yml: every step that logs in, pushes or signs is gated on the publish output (the one login that only pulls the binaries image is exempt)" python3 - "$here" <<'PY'
import sys, yaml
w = yaml.safe_load(open(sys.argv[1] + "/.github/workflows/build.yml"))
for s in w["jobs"]["build_push"]["steps"]:
    text = str(s.get("uses", "")) + " " + str(s.get("run", ""))
    risky = "login-action" in text or "push-tags.sh" in text or "cosign sign" in text or "skopeo copy" in text
    if risky and "pull" not in str(s.get("name")).lower():
        assert "outputs.publish" in str(s.get("if")), (s.get("name"), s.get("if"))
PY
check "build.yml: sign runs only after a publish or a promotion, in the signing environment, so a validation dispatch never signs" python3 - "$here" <<'PY'
import sys, yaml
j = yaml.safe_load(open(sys.argv[1] + "/.github/workflows/build.yml"))["jobs"]["sign"]
cond = " ".join(j["if"].split())
assert "outputs.publish" in cond and "promote.result" in cond, cond
assert j["environment"] == "signing"
PY
check "build.yml: the aggregate job keeps the required name, always runs and needs every job that publishes or signs" python3 - "$here" <<'PY'
import sys, yaml
jobs = yaml.safe_load(open(sys.argv[1] + "/.github/workflows/build.yml"))["jobs"]
j = jobs["build_result"]
assert j["name"] == "Build and push image", j["name"]
assert "always()" in str(j.get("if")), j
pub = {n for n, x in jobs.items() if n != "build_result" and ("environment" in x or "push-tags.sh" in str(x) or "cosign sign" in str(x))}
assert pub and pub <= set(j["needs"]), (pub, j["needs"])
PY
check "require-testing-branch.yml: pull requests into main only" python3 - "$here" <<'PY'
import sys, yaml
w = yaml.safe_load(open(sys.argv[1] + "/.github/workflows/require-testing-branch.yml"))
on = w.get(True) or w.get("on")
assert on == {"pull_request": {"branches": ["main"]}}, on
PY
check "other workflows have no pull_request trigger (daily, beta, NVIDIA, disk, prune unchanged)" python3 - "$here" <<'PY'
import glob, sys, yaml
for f in glob.glob(sys.argv[1] + "/.github/workflows/*.yml"):
    if f.endswith(("build.yml", "require-testing-branch.yml", "zizmor.yml")):  # zizmor.yml audits workflow changes in pull requests
        continue
    on = yaml.safe_load(open(f)); on = on.get(True) or on.get("on")
    assert "pull_request" not in on and "pull_request_target" not in on, f
PY
check "a job whose if reads a needed job's RESULT has its own status function (always() or !cancelled()): GitHub adds an implicit success() otherwise, which is false when ANY ancestor was skipped" python3 - "$here" <<'PY'
import sys, glob, re, yaml
status = re.compile(r"always\(\)|!cancelled\(\)|failure\(\)|success\(\)|cancelled\(\)")
bad = []
for f in glob.glob(sys.argv[1] + "/.github/workflows/*.yml"):
    for n, j in yaml.safe_load(open(f))["jobs"].items():
        cond = str(j.get("if", ""))
        if re.search(r"needs\.[\w-]+\.result", cond) and not status.search(cond):
            bad.append((f.split("/")[-1], n))
# these two sign jobs are meant to be skipped together with a skipped build
bad = [b for b in bad if b not in (('binaries.yml', 'sign'), ('binaries-component.yml', 'sign'), ('build-nvidia-dx.yml', 'sign'))]
assert not bad, bad
PY
check "workflow_run is used only by the NVIDIA dx chain; build-dx.yml is dispatched by the pipelines (dispatch_dx), never triggered by a finished run" python3 - "$here" <<'PY'
import sys, glob, yaml
for f in glob.glob(sys.argv[1] + "/.github/workflows/*.yml"):
    w = yaml.safe_load(open(f))
    on = w.get(True) or w.get("on") or {}
    if isinstance(on, dict) and "workflow_run" in on:
        assert f.endswith("build-nvidia-dx.yml"), f
PY
check "schedules: every cron is on the hour and unique; the prune runs before the daily build, the NVIDIA build after it" python3 - "$here" <<'PY'
import glob, sys, yaml
crons = {}
for f in glob.glob(sys.argv[1] + "/.github/workflows/*.yml"):
    on = yaml.safe_load(open(f)); on = on.get(True) or on.get("on")
    for s in (on.get("schedule") or []):
        crons[f.rsplit("/", 1)[1]] = s["cron"]
for name, c in crons.items():
    m, h, *_ = c.split()
    assert m == "0" and h.isdigit() and 0 <= int(h) < 24, (name, c)
assert len(set(crons.values())) == len(crons), crons
hour = lambda n: int(crons[n].split()[1])
assert hour("prune-testing.yml") < hour("build.yml") < hour("build-nvidia.yml"), crons
PY
check "the final decision of the plan: promote, reuse (nothing to build), build, never skip on a failed verification" bash -s -- "$here" "$root" <<'SH'
python3 - "$1" "$2" <<'PY'
import sys, yaml
w = yaml.safe_load(open(sys.argv[1] + "/.github/workflows/build.yml"))
run = next(s["run"] for s in w["jobs"]["plan"]["steps"] if "BUILD_PLAN" in str(s.get("env")))
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
check "the image label the build writes for the default-image inputs is the one the promote and reuse verification reads" python3 - "$here" <<'PY'
import re, sys
d = sys.argv[1]
m = re.search(r'"--label" "([^="]+)=\$\(\.github/scripts/inputs-hash\.sh vanilla\)', open(d + "/Justfile").read())
assert m, "no label written for the vanilla inputs"
assert m.group(1) in open(d + "/.github/workflows/build.yml").read(), m.group(1)
PY

echo "passed: $pass, failed: $failn"
[ "$failn" = 0 ]
