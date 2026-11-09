#!/usr/bin/env bash
# Quick checks that pull requests into `testing` run build.yml as a validation build only: the trigger, one
# concurrency group per PR, every publishing step gated off, the aggregate job, and that the other workflows
# keep their triggers. Run: tests/pr-validation.sh
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
root=$(mktemp -d)
trap 'rm -rf -- "$root"' EXIT
pass=0
failn=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { failn=$((failn + 1)); echo "FAIL $1"; [ -f "$root/out" ] && sed 's/^/     /' "$root/out"; }
check() { local d=$1; shift; if "$@" >"$root/out" 2>&1; then ok "$d"; else bad "$d"; fi; }

check "build.yml: pull_request into testing only, push main/testing, schedule, dispatch" python3 - "$here" <<'PY'
import sys, yaml
w = yaml.safe_load(open(sys.argv[1] + "/.github/workflows/build.yml"))
on = w.get(True) or w.get("on")
assert on["pull_request"] == {"branches": ["testing"]}, on["pull_request"]
assert on["push"] == {"branches": ["main", "testing"]}, on["push"]
assert set(on) == {"pull_request", "push", "schedule", "workflow_dispatch"}, set(on)
assert on["schedule"] == [{"cron": "05 10 * * *"}]
PY
check "build.yml: concurrency is per ref (one group per PR) and cancels everything but main and schedule" python3 - "$here" <<'PY'
import sys, yaml
c = yaml.safe_load(open(sys.argv[1] + "/.github/workflows/build.yml"))["concurrency"]
assert "github.ref" in c["group"] and "github.workflow" in c["group"], c
assert c["cancel-in-progress"] == "${{ github.ref != 'refs/heads/main' && github.event_name != 'schedule' }}", c
PY
check "build.yml: a pull request run never publishes (channel step)" python3 - "$here" <<'PY'
import sys, yaml
w = yaml.safe_load(open(sys.argv[1] + "/.github/workflows/build.yml"))
st = {s.get("name"): s for s in w["jobs"]["build_push"]["steps"]}
run = st["Choose channel"]["run"]
assert 'if [[ "${EVENT}" != "pull_request" ]]' in run, run
# publish=true is only set inside that guard
assert run.index("publish=true") > run.index('!= "pull_request"')
PY
check "build.yml: login and push run only when publish is true; no other step in the build job logs in, pushes or signs" python3 - "$here" <<'PY'
import sys, yaml
w = yaml.safe_load(open(sys.argv[1] + "/.github/workflows/build.yml"))
gate = "steps.channel.outputs.publish == 'true'"
for s in w["jobs"]["build_push"]["steps"]:
    text = str(s.get("uses", "")) + " " + str(s.get("run", ""))
    risky = "login-action" in text or "podman push" in text or "cosign sign" in text or "skopeo copy" in text
    if risky:
        assert s.get("if") == gate, (s.get("name"), s.get("if"))
assert {"Login to GitHub Container Registry", "Push To GHCR"} <= {s["name"] for s in w["jobs"]["build_push"]["steps"]}
PY
check "build.yml: promote only on a main push; sign needs a publish or a promotion, so it skips on pull requests" python3 - "$here" <<'PY'
import sys, yaml
w = yaml.safe_load(open(sys.argv[1] + "/.github/workflows/build.yml"))
plan = {s.get("name"): s for s in w["jobs"]["plan"]["steps"]}
assert "github.event_name == 'push' && github.ref == 'refs/heads/main'" in plan["Look for a tested testing image to promote"]["if"]
cond = " ".join(w["jobs"]["sign"]["if"].split())
assert "needs.build_push.outputs.publish == 'true'" in cond and "needs.promote.result == 'success'" in cond, cond
assert w["jobs"]["sign"]["environment"] == "signing"
PY
check "build.yml: aggregate job is named 'Build and push image', always runs, needs plan, build, promote and sign" python3 - "$here" <<'PY'
import sys, yaml
j = yaml.safe_load(open(sys.argv[1] + "/.github/workflows/build.yml"))["jobs"]["build_result"]
assert j["name"] == "Build and push image" and j["if"] == "always()", j
assert j["needs"] == ["plan", "build_push", "promote", "sign"], j["needs"]
PY
check "build.yml: the PR plan diffs the PR base..head" grep -q "github.event.pull_request.head.sha" "$here/.github/workflows/build.yml"
check "plan-build.sh and aggregate-result.sh accept the pull_request event" bash -c "
  cd '$here' && .github/scripts/plan-build.sh pull_request '' HEAD 2>/dev/null | grep -qx true &&
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

echo "passed: $pass, failed: $failn"
[ "$failn" = 0 ]
