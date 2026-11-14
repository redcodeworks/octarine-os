#!/usr/bin/env bash
# Tests for the NVIDIA developer image (octarine-os-nvidia-dx): .github/workflows/build-nvidia-dx.yml (triggers, guards, the
# one shared dx layer, smoke tests, tags, signing, no required-check context), the DX_IMAGE_ID part of variants/dx/dx.sh, the
# CDI pieces in variants/nvidia/nvidia.sh and the dx-only input list. The plan decision (BASE_NAME, DX_NAME,
# PROMOTE_FROM_TESTING) is tested in tests/plan-dx.sh, the ujust dev cuda step in tests/dev-setup.sh, the policy rule in
# tests/dx-image.sh and tests/nvidia-variant.sh. Run: tests/nvidia-dx-image.sh
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
wf="$here/.github/workflows/build-nvidia-dx.yml"
root=$(mktemp -d)
trap 'rm -rf -- "$root"' EXIT
pass=0
failn=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { failn=$((failn + 1)); echo "FAIL $1"; [ -f "$root/out" ] && sed 's/^/     /' "$root/out" | tail -20; }
check() { local d=$1; shift; if "$@" >"$root/out" 2>&1; then ok "$d"; else bad "$d"; fi; }

check "workflow: valid YAML, workflow_run of the NVIDIA build on main plus dispatch only (no push, pull_request, schedule)" python3 - "$wf" <<'PY'
import sys, yaml
w = yaml.safe_load(open(sys.argv[1]))
on = w.get(True) or w.get("on")
assert set(on) == {"workflow_run", "workflow_dispatch"}, set(on)
assert on["workflow_run"] == {"workflows": ["Build NVIDIA variant"], "types": ["completed"], "branches": ["main"]}, on["workflow_run"]
assert w["concurrency"] == {"group": "build-nvidia-dx", "cancel-in-progress": False}
assert w["permissions"] == {"contents": "read"}
PY
check "workflow: the plan runs on the main workflow file only, for a dispatch or a successful scheduled or dispatched NVIDIA build of main" python3 - "$wf" <<'PY'
import sys, yaml
w = yaml.safe_load(open(sys.argv[1]))
c = w["jobs"]["plan"]["if"]
assert "github.ref == 'refs/heads/main'" in c and "workflow_run.conclusion == 'success'" in c and "workflow_run.head_branch == 'main'" in c, c
assert "'[\"schedule\",\"workflow_dispatch\"]'" in c and "pull_request" not in c
PY
check "workflow: the plan names the NVIDIA base, the nvidia-dx image and no testing promotion" python3 - "$wf" <<'PY'
import sys, yaml
w = yaml.safe_load(open(sys.argv[1]))
st = [s for s in w["jobs"]["plan"]["steps"] if s.get("id") == "plan"][0]
assert st["env"] == {"BASE_NAME": "octarine-os-nvidia", "DX_NAME": "octarine-os-nvidia-dx", "PROMOTE_FROM_TESTING": "false"}, st["env"]
assert st["run"] == ".github/scripts/plan-dx.sh"
assert w["env"]["CHANNEL"] == "latest"
PY
check "workflow: it never posts the required check context of build-dx.yml (no job of that name, no statuses permission or API call)" python3 - "$wf" "$here/.github/workflows/build-dx.yml" <<'PY'
import sys, yaml
w = yaml.safe_load(open(sys.argv[1])); dx = yaml.safe_load(open(sys.argv[2]))
names = {j.get("name") for j in w["jobs"].values()}
assert "Build dx and push image" not in names, names
text = open(sys.argv[1]).read()
assert "statuses" not in text.replace("statuses are", "") or "statuses: write" not in text, "statuses permission"
assert "repos/${GITHUB_REPOSITORY}/statuses" not in text and 'context="Build dx and push image"' not in text
for j in w["jobs"].values():
    assert "statuses" not in (j.get("permissions") or {}), j
# and the dx workflow keeps posting it, unchanged
assert dx["jobs"]["dx_result"]["name"] == "Build dx and push image"
assert dx["jobs"]["dx_result"]["permissions"] == {"contents": "read", "statuses": "write"}
PY
check "workflow: jobs are plan -> build -> sign -> result, result named 'NVIDIA dx build result', sign in the signing environment" python3 - "$wf" <<'PY'
import sys, yaml
w = yaml.safe_load(open(sys.argv[1]))
assert list(w["jobs"]) == ["plan", "build", "sign", "nvidia_dx_result"], list(w["jobs"])
assert w["jobs"]["nvidia_dx_result"]["name"] == "NVIDIA dx build result" and w["jobs"]["nvidia_dx_result"]["if"] == "always()"
assert w["jobs"]["nvidia_dx_result"]["needs"] == ["plan", "build", "sign"]
assert w["jobs"]["sign"]["environment"] == "signing" and w["jobs"]["sign"]["needs"] == "build"
assert w["jobs"]["build"]["if"] == "needs.plan.outputs.build == 'true'"
assert w["jobs"]["build"]["needs"] == "plan"
PY
check "workflow: the result job feeds aggregate-dx.sh with promote skipped (no promote job here)" bash -c "
  grep -q 'run: .github/scripts/aggregate-dx.sh' '$wf' && grep -q 'PROMOTE: skipped' '$wf' && ! grep -q 'skopeo copy' '$wf'"
check "workflow: one shared dx layer (variants/dx/Containerfile) on the NVIDIA base, by digest, nothing forked" bash -c "
  grep -q -- '-f variants/dx/Containerfile' '$wf'
  grep -q 'BASE_IMAGE=ghcr.io/\${owner}/octarine-os-nvidia' '$wf'
  grep -q -- '--build-arg \"BASE_DIGEST=\${BASE_DIGEST}\"' '$wf'
  grep -q -- '--build-arg \"DX_IMAGE_ID=octarine-os-nvidia-dx\"' '$wf'
  grep -q 'cosign verify --key cosign.pub \"\${BASE_IMAGE}@\${BASE_DIGEST}\"' '$wf'
  [ \$(find '$here/variants' -name Containerfile | wc -l) = 2 ] && [ ! -e '$here/variants/nvidia-dx' ]"
check "workflow: the labels are explicit, the dx inputs are recorded and the inherited ones are unset" bash -c "
  for l in title description source licenses vendor revision version created url documentation base.name base.digest; do grep -q -- \"--label \\\"org.opencontainers.image.\$l=\" '$wf' || { echo missing \$l; exit 1; }; done
  grep -q 'io.github.redcodeworks.octarine-os.dx-inputs=\${DX_INPUTS}' '$wf'
  grep -q -- '--unsetlabel io.github.redcodeworks.octarine-os.base-index-digest' '$wf' && grep -q -- '--unsetlabel io.github.redcodeworks.octarine-os.vanilla-inputs' '$wf'
  grep -q -- '--label \"org.opencontainers.image.title=octarine-os-nvidia-dx\"' '$wf'"
check "workflow: both smoke tests run on the built image (dx checks with the nvidia-dx IMAGE_ID, then the NVIDIA checks)" bash -c "
  grep -q 'EXPECT_IMAGE_ID=octarine-os-nvidia-dx' '$wf' && grep -q 'dx-smoke.sh:/smoke.sh:ro' '$wf'
  grep -q 'nvidia-smoke.sh:/smoke.sh:ro' '$wf' && grep -q 'bash /smoke.sh present' '$wf'
  a=\$(grep -n 'dx-smoke.sh' '$wf' | head -1 | cut -d: -f1); b=\$(grep -n 'nvidia-smoke.sh' '$wf' | head -1 | cut -d: -f1); r=\$(grep -n 'ostree-rechunk' '$wf' | head -1 | cut -d: -f1)
  [ \$a -lt \$b ] && [ \$b -lt \$r ]"
check "workflow: size guard, rechunk, neutral-version check, one push (push-tags.sh), the NVIDIA variant's tags" bash -c "
  grep -q 'MAX_IMAGE_GIB: 15' '$wf' && grep -q 'just ostree-rechunk octarine-os-nvidia-dx \"\${CHANNEL}\"' '$wf'
  grep -q 'BETA=false .github/scripts/check-version-neutral.sh' '$wf'
  [ \$(grep -c 'push-tags.sh' '$wf') = 1 ] && ! grep -q 'podman push' '$wf'
  grep -q 'alias_tags=\"latest-\${sha} latest-\${date}-\${sha} \${date}-\${sha} \${date} latest latest-\${date}\"' '$wf'
  ! grep -qE 'testing|beta' <(grep -v '^ *#' '$wf')"
check "workflow: it signs every pushed digest with the repository key and verifies every tag" bash -c "
  grep -q 'cosign sign -y --new-bundle-format=false --use-signing-config=false --key env://COSIGN_PRIVATE_KEY' '$wf'
  grep -q 'SIGNING_SECRET' '$wf' && grep -q 'cosign verify --key cosign.pub \"\${IMAGE}:\${tag}\"' '$wf'"
check "workflow: every third-party action is pinned by commit sha" python3 - "$wf" <<'PY'
import re, sys
for l in open(sys.argv[1]):
    m = re.search(r"uses: (\S+)", l)
    if m and not m.group(1).startswith("./"):
        assert re.search(r"@[0-9a-f]{40}\b", m.group(1)), l
PY
check "workflow: bash -n on every run block" python3 - "$wf" "$root" <<'PY'
import subprocess, sys, yaml
w = yaml.safe_load(open(sys.argv[1]))
for jn, j in w["jobs"].items():
    for i, s in enumerate(j.get("steps", [])):
        if "run" in s:
            p = f"{sys.argv[2]}/{jn}-{i}.sh"
            open(p, "w").write(s["run"])
            r = subprocess.run(["bash", "-n", p], capture_output=True, text=True)
            assert r.returncode == 0, (jn, s.get("name"), r.stderr)
PY
check "the dx and NVIDIA dx workflows build with the same Containerfile and the same smoke script (kept in step)" python3 - "$wf" "$here/.github/workflows/build-dx.yml" <<'PY'
import sys, yaml
a = yaml.safe_load(open(sys.argv[1])); b = yaml.safe_load(open(sys.argv[2]))
def step(w, job, name): return [s for s in w["jobs"][job]["steps"] if s.get("name") == name][0]
for n in ("Maximize build space", "Check Just Syntax", "Check image size", "Rechunk with rpm-ostree"):
    sa, sb = step(a, "build", n), step(b, "build", n)
    assert {k: v for k, v in sa.items() if k != "run"} == {k: v for k, v in sb.items() if k != "run"}, n
assert step(a, "build", "Check the dev-packages pin")["run"] == step(b, "build", "Check the dev-packages pin")["run"]
PY
check "workflow: a doc or comment never says the CUDA toolkit is in the image (licensing: it is installed by the user in a distrobox)" bash -c "! grep -qiE 'cuda-toolkit|nvidia/cuda' '$wf'"

# ---- the os-release identity part of dx.sh (the same layer, two IMAGE_IDs)
idblock="$root/idblock.sh"
{
    echo 'set -euo pipefail'
    sed -n '/^set_os_release_field() {/,/^}/p' "$here/variants/dx/dx.sh"
    sed -n '/^: "\${IMAGE_VERSION/,/IMAGE_ID_EXPECTED=/p' "$here/variants/dx/dx.sh" | sed "s#/usr/lib/os-release#$root/os-release#"
} >"$idblock"
mkid() { printf 'ID=fedora\nIMAGE_ID="octarine-os"\nIMAGE_VERSION="old"\n' >"$root/os-release"; }
mkid; IMAGE_VERSION=20261110-abc1234 OS_RELEASE_FILE="$root/os-release" bash "$idblock" >"$root/out" 2>&1; rc=$?
check "dx.sh: without DX_IMAGE_ID the image id is octarine-os-dx" bash -c "[ $rc = 0 ] && grep -qx 'IMAGE_ID=\"octarine-os-dx\"' '$root/os-release' && grep -qx 'IMAGE_VERSION=\"20261110-abc1234\"' '$root/os-release'"
mkid; DX_IMAGE_ID=octarine-os-nvidia-dx IMAGE_VERSION=20261110-abc1234 OS_RELEASE_FILE="$root/os-release" bash "$idblock" >"$root/out" 2>&1; rc=$?
check "dx.sh: DX_IMAGE_ID=octarine-os-nvidia-dx sets that image id" bash -c "[ $rc = 0 ] && grep -qx 'IMAGE_ID=\"octarine-os-nvidia-dx\"' '$root/os-release'"
mkid; DX_IMAGE_ID='octarine-os' IMAGE_VERSION=20261110-abc1234 OS_RELEASE_FILE="$root/os-release" bash "$idblock" >"$root/id.out" 2>&1; rc=$?
check "dx.sh: any other DX_IMAGE_ID is refused" bash -c "[ $rc != 0 ] && grep -q 'is not octarine-os-dx or octarine-os-nvidia-dx' '$root/id.out'"
check "Containerfile: DX_IMAGE_ID is a build argument of the final stage, default octarine-os-dx" bash -c "
  f='$here/variants/dx/Containerfile'; from=\$(grep -n '^FROM \${BASE_IMAGE}' \$f | cut -d: -f1); arg=\$(grep -n '^ARG DX_IMAGE_ID=octarine-os-dx' \$f | cut -d: -f1); [ -n \"\$arg\" ] && [ \"\$arg\" -gt \"\$from\" ]"

# ---- the NVIDIA variant brings what a container needs for CDI (unverified on a real build; failing is a warning)
check "nvidia.sh: tries nvidia-container-toolkit-base once, only as a warning, and enables the refresh units when they exist" bash -c "
  grep -q 'rpm -q nvidia-container-toolkit-base' '$here/variants/nvidia/nvidia.sh'
  grep -q 'dnf5 -y install nvidia-container-toolkit-base ||' '$here/variants/nvidia/nvidia.sh'
  grep -q 'nvidia-cdi-refresh.path' '$here/variants/nvidia/nvidia.sh' && grep -q '/usr/lib/systemd/system/\${u}' '$here/variants/nvidia/nvidia.sh'
  bash -n '$here/variants/nvidia/nvidia.sh'"
check "no CUDA toolkit or NVIDIA CUDA repository anywhere in the image build" bash -c "! grep -rqiE 'cuda-toolkit|developer\.download\.nvidia\.com|cuda-nvcc' '$here/build_files' '$here/variants/nvidia' '$here/variants/dx/dx.sh' '$here/variants/dx/packages' '$here/Containerfile' '$here/variants/dx/Containerfile' '$here/system_files'"

# ---- the dx-only inputs
check "inputs: the nvidia-dx workflow and this test are dx-only inputs (a change rebuilds dx, never the default image)" bash -c "
  . '$here/.github/scripts/inputs-hash.sh'
  is_dx_only .github/workflows/build-nvidia-dx.yml && is_dx_only tests/nvidia-dx-image.sh && ! is_dx_only .github/workflows/build-nvidia.yml"
check "build-nvidia.yml and build-dx.yml never mention nvidia-dx (their triggers and results are unchanged)" bash -c "! grep -q 'nvidia-dx' '$here/.github/workflows/build-nvidia.yml' '$here/.github/workflows/build-dx.yml'"
check "bash -n of the scripts touched" bash -c "bash -n '$here/.github/scripts/plan-dx.sh' && bash -n '$here/.github/scripts/dx-smoke.sh' && bash -n '$here/.github/scripts/nvidia-smoke.sh' && bash -n '$here/variants/dx/dx.sh'"

echo
echo "passed: $pass, failed: $failn"
[ "$failn" -eq 0 ]
