#!/usr/bin/env bash
# Quick checks of the beta channel workflow (.github/workflows/build-beta.yml): triggers, schedule slot, base, permissions,
# pinned actions, only the `beta` tag pushed, signing and verification, and that its smoke test matches build.yml's.
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
check "workflow: every third-party action is pinned by SHA with a version comment" python3 - "$wf" <<'PY'
import re, sys
for line in open(sys.argv[1]):
    m = re.search(r"uses:\s*(\S+)", line)
    if m and not m.group(1).startswith("./"):
        ref = m.group(1).split("@", 1)[1]
        assert re.fullmatch(r"[0-9a-f]{40}", ref), line
        if "ublue-os/remove-unwanted-software" not in line:  # build.yml pins this one without a comment too
            assert re.search(r"#\s*v\d", line), line
PY
check "workflow: pushes exactly beta and beta-<date>-<sha> (one push line, tags from one step, nothing else)" bash -c "
  set -e
  [ \$(grep -c 'push-tags.sh' '$wf') = 1 ]
  ! grep -q 'podman push' '$wf'
  grep -q 'alias_tags=\"\${DEFAULT_TAG}-\$(date +%Y%m%d)-\$(git rev-parse --short HEAD) \${DEFAULT_TAG}\"' '$wf'
  ! grep -qE 'generate-build-tags|tag-images|:latest|:testing' '$wf'"
check "workflow: both pushed tags are verified after signing" bash -c "grep -q 'for tag in \${ALIAS_TAGS}' '$wf' && grep -q 'cosign verify --key cosign.pub \"\${IMAGE}:\${tag}\"' '$wf' && grep -q 'alias_tags: .*steps.tags' '$wf'"
check "workflow: signs the pushed digest and verifies the tag with cosign.pub" bash -c "grep -q 'cosign sign .*SIGNING\|cosign sign -y' '$wf' && grep -q 'cosign verify --key cosign.pub' '$wf'"
check "workflow: the daily build does not mention the beta workflow" bash -c "! grep -q 'build-beta\|silverblue-main:beta' '$here/.github/workflows/build.yml'"
check "workflow: smoke test equals the one in build.yml" python3 - "$here" <<'PY'
import sys
def block(p):
    t = open(p).read()
    a = t.index("- name: Smoke test image")
    b = t.index("# Optional packages that could not be installed") if "build.yml" in p else t.index("- name: Rechunk with rpm-ostree")
    # the only intended difference: the version pattern of the IMAGE_VERSION assertion (beta- prefix)
    return t[a:b].strip().replace("-e VERSION_RE='beta-[0-9]{8}", "-e VERSION_RE='[0-9]{8}")
d = sys.argv[1] + "/.github/workflows/"
assert block(d + "build.yml") == block(d + "build-beta.yml")
PY
check "workflow: beta builds get the beta- version prefix and assert it; the stable build does not" bash -c "
  grep -q 'IMAGE_VERSION_PREFIX: beta-' '$wf' && ! grep -q IMAGE_VERSION_PREFIX '$here/.github/workflows/build.yml'
  grep -q \"VERSION_RE='beta-\[0-9\]{8}-\[0-9a-f\]{7,}'\" '$wf'
  grep -q 'BETA=true .github/scripts/check-version-neutral.sh' '$wf'
  grep -q 'check \"image id\"' '$wf' && grep -q 'IMAGE_ID=' '$wf'"
check "signature policy covers the repository the beta tag lives in (any tag)" grep -q 'refs="ghcr.io/${org}/${base_name}' "$here/build_files/build.sh"

# ---- prune rule for the beta channel
prune=$here/.github/scripts/prune-testing.py
pj() { # n versions with dated beta tags, ids 1..n, oldest first
    python3 - "$1" "${2:-}" <<'PY'
import json, sys
n = int(sys.argv[1]); extra = sys.argv[2]
vs = [{"id": i, "name": "sha256:" + format(i, "x") * 64, "created_at": f"2026-01-{i:02d}T00:00:00Z",
       "metadata": {"container": {"tags": [f"beta-202601{i:02d}-{i}{i}{i}{i}{i}{i}{i}"]}}} for i in range(1, n + 1)]
if extra == "beta-on-oldest":
    vs[0]["metadata"]["container"]["tags"].append("beta")
vs += [{"id": 90, "name": "sha256:" + "e" * 64, "created_at": "2025-01-01T00:00:00Z", "metadata": {"container": {"tags": ["latest", "latest-20250101-aaaaaaa", "20250101"]}}},
       {"id": 91, "name": "sha256:" + "f" * 64, "created_at": "2025-01-01T00:00:00Z", "metadata": {"container": {"tags": ["testing-bbbbbbb", "testing"]}}},
       {"id": 92, "name": "sha256:" + "d" * 64, "created_at": "2025-01-01T00:00:00Z", "metadata": {"container": {"tags": ["20250101-aaaaaaa"]}}},
       {"id": 93, "name": "sha256:" + "9" * 64, "created_at": "2025-01-01T00:00:00Z", "metadata": {"container": {"tags": [f"sha256-{'3' * 64}.sig"]}}}]
print(json.dumps(vs))
PY
}
beta_out=$(pj 5 | PRUNE_KIND=beta KEEP=3 DRY_RUN=true python3 -I "$prune" 2>&1)
check "prune beta: keeps 3 of 5 (the 2 oldest are deleted)" bash -c "[ \$(grep -c 'DELETE image' <<<'$beta_out') = 2 ] && grep -q 'DELETE image id=1 ' <<<'$beta_out' && grep -q 'DELETE image id=2 ' <<<'$beta_out'"
check "prune beta: latest, testing, dated stable tags and signatures of other images are untouched" bash -c "! grep -qE 'id=(90|91|92|93) ' <<<'$beta_out'"
beta_out=$(pj 2 | PRUNE_KIND=beta KEEP=3 DRY_RUN=true python3 -I "$prune" 2>&1)
check "prune beta: nothing deleted with 2 builds (keep 3)" grep -q 'Nothing to prune' <<<"$beta_out"
beta_out=$(pj 5 beta-on-oldest | PRUNE_KIND=beta KEEP=3 DRY_RUN=true python3 -I "$prune" 2>&1)
check "prune beta: a version holding the beta tag is kept however old" bash -c "! grep -q 'DELETE image id=1 ' <<<'$beta_out' && grep -q 'DELETE image id=2 ' <<<'$beta_out'"
check "prune beta: dry run is the default" bash -c "pj() { :; }; echo '[]' | env -u DRY_RUN PRUNE_KIND=beta python3 -I '$prune' | grep -q 'Nothing to prune'"
check "prune testing kind leaves beta versions alone" bash -c "! (python3 -c 'print(1)' >/dev/null; $(declare -f pj); pj 5 | PRUNE_KIND=testing KEEP=1 DRY_RUN=true python3 -I '$prune' | grep -E 'DELETE image id=[1-5] ')"
check "prune workflow runs weekly and passes the beta kind with keep 3" bash -c "grep -q \"cron: '0 5 \* \* 0'\" '$here/.github/workflows/prune-testing.yml' && grep -q 'PRUNE_KIND=beta KEEP=3' '$here/.github/workflows/prune-testing.yml'"

echo "passed: $pass, failed: $failn"
[ "$failn" = 0 ]
