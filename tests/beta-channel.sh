#!/usr/bin/env bash
# Quick checks of the beta channel workflow (.github/workflows/build-beta.yml): triggers, schedule slot, base, permissions,
# only the `beta` tag pushed, signing and verification, and that its smoke test matches build.yml's.
# Run: tests/beta-channel.sh
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
wf="$here/.github/workflows/build-beta.yml"
root=$(mktemp -d)
trap 'rm -rf -- "$root"' EXIT
pass=0
failn=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { failn=$((failn + 1)); echo "FAIL $1"; [ -f "$root/out" ] && sed 's/^/     /' "$root/out"; }
check() { local d=$1; shift; if "$@" >"$root/out" 2>&1; then ok "$d"; else bad "$d"; fi; }

check "workflow: bash syntax of every run block" python3 - "$wf" <<'PY'
import subprocess, sys, yaml
w = yaml.safe_load(open(sys.argv[1]))
for name, job in w["jobs"].items():
    for s in job.get("steps", []):
        if "run" in s:
            r = subprocess.run(["bash", "-n"], input=s["run"], text=True, capture_output=True)
            assert r.returncode == 0, (name, s.get("name"), r.stderr)
PY
check "workflow: schedule and dispatch only, weekly, no overlap with the other schedules" python3 - "$here" <<'PY'
import glob, sys, yaml
here = sys.argv[1]
w = yaml.safe_load(open(here + "/.github/workflows/build-beta.yml"))
on = w.get(True) or w.get("on")
assert set(on) == {"schedule", "workflow_dispatch"}, set(on)
assert len(on["schedule"]) == 1
cron = on["schedule"][0]["cron"].split()
assert cron[2:4] == ["*", "*"] and cron[4].isdigit(), cron  # one fixed weekday
others = []
for f in glob.glob(here + "/.github/workflows/*.yml"):
    if f.endswith("build-beta.yml"):
        continue
    o = yaml.safe_load(open(f))
    o = o.get(True) or o.get("on")
    for s in (o.get("schedule") or []) if isinstance(o, dict) else []:
        others.append(s["cron"])
assert on["schedule"][0]["cron"] not in others, others
assert w["concurrency"]["cancel-in-progress"] is False
PY
check "workflow: base is silverblue-main:beta, set in this workflow's env only" python3 - "$wf" <<'PY'
import sys, yaml
w = yaml.safe_load(open(sys.argv[1]))
assert w["env"]["BASE_IMAGE"] == "ghcr.io/ublue-os/silverblue-main", w["env"]
assert w["env"]["FEDORA_VERSION"] == "beta" and w["env"]["DEFAULT_TAG"] == "beta"
assert "vars." not in str(w["env"])
PY
check "workflow: least privilege per job, signing in the signing environment" python3 - "$wf" <<'PY'
import sys, yaml
w = yaml.safe_load(open(sys.argv[1]))
assert w["permissions"] == {"contents": "read"}
for n in ("build", "sign"):
    assert w["jobs"][n]["permissions"] == {"contents": "read", "packages": "write"}, n
assert w["jobs"]["sign"]["environment"] == "signing"
PY
check "workflow: pushes exactly beta and beta-<date>-<sha> (one push line, tags from one step, nothing else)" bash -c "
  set -e
  [ \$(grep -c 'push-tags.sh' '$wf') = 1 ]
  grep -q 'alias_tags=\"\${DEFAULT_TAG}-\$(date +%Y%m%d)-\$(git rev-parse --short HEAD) \${DEFAULT_TAG}\"' '$wf'
  ! grep -qE 'generate-build-tags|tag-images|:latest|:testing' '$wf'"
check "workflow: both pushed tags are verified after signing" bash -c "grep -q 'for tag in \${ALIAS_TAGS}' '$wf' && grep -q 'cosign verify --key cosign.pub \"\${IMAGE}:\${tag}\"' '$wf' && grep -q 'alias_tags: .*steps.tags' '$wf'"
check "workflow: signs the pushed digest and verifies the tag with cosign.pub" bash -c "grep -q 'cosign sign .*SIGNING\|cosign sign -y' '$wf' && grep -q 'cosign verify --key cosign.pub' '$wf'"
check "workflow: the daily build does not mention the beta workflow" bash -c "! grep -q 'build-beta\|silverblue-main:beta' '$here/.github/workflows/build.yml'"
check "workflow: the smoke test is the same script as the daily build's (default-smoke.sh), only the version pattern differs" bash -c "grep -q default-smoke.sh '$wf' && grep -q default-smoke.sh '$here/.github/workflows/build.yml'"
check "workflow: beta builds get the beta- version prefix and assert it; the stable build does not" bash -c "
  grep -q 'IMAGE_VERSION_PREFIX: beta-' '$wf' && ! grep -q IMAGE_VERSION_PREFIX '$here/.github/workflows/build.yml' &&
  grep -q \"VERSION_RE='beta-\[0-9\]{8}-\[0-9a-f\]{7,}'\" '$wf' &&
  grep -q 'BETA=true .github/scripts/check-version-neutral.sh' '$wf'"
check "signature policy covers the repository the beta tag lives in (any tag)" grep -q 'refs="ghcr.io/${org}/${base_name}' "$here/build_files/build.sh"

echo "passed: $pass, failed: $failn"
[ "$failn" = 0 ]
