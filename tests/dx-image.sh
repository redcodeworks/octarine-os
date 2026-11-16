#!/usr/bin/env bash
# Quick checks of the developer image (octarine-os-dx): the workflow (triggers, guards, channel mapping, permissions,
# pins, tags, signing, concurrency, the plan step with stub tools), the Containerfile and package lists, the signature
# policy of all three repositories, the in-image smoke script (stub tools) and the dev-packages pin
# (format and `just dev-packages-bump` with fake skopeo and cosign). Nothing here builds an image.
# Run: tests/dx-image.sh
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
keys_doc=$here/docs/signing-keys.md   # the one place that names the keys document
wf="$here/.github/workflows/build-dx.yml"
root=$(mktemp -d)
trap 'rm -rf -- "$root"' EXIT
pass=0
failn=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { failn=$((failn + 1)); echo "FAIL $1"; [ -f "$root/out" ] && sed 's/^/     /' "$root/out"; }
check() { local d=$1; shift; if "$@" >"$root/out" 2>&1; then ok "$d"; else bad "$d"; fi; }

# ---- the workflow
check "workflow: bash syntax of every run block" python3 - "$wf" <<'PY'
import subprocess, sys, yaml
w = yaml.safe_load(open(sys.argv[1]))
for name, job in w["jobs"].items():
    for s in job.get("steps", []):   # a job that calls a reusable workflow has no steps
        if "run" in s:
            r = subprocess.run(["bash", "-n"], input=s["run"], text=True, capture_output=True)
            assert r.returncode == 0, (name, s.get("name"), r.stderr)
PY
check "workflow: the only trigger is workflow_dispatch (channel, sha, base_digest, force, dry_run); no workflow_run, push, schedule or pull request; run-name carries channel and sha for dispatch-dx.sh" python3 - "$wf" <<'PY'
import sys, yaml
w = yaml.safe_load(open(sys.argv[1]))
on = w.get(True) or w.get("on")
assert set(on) == {"workflow_dispatch"}, set(on)
inp = on["workflow_dispatch"]["inputs"]
assert set(inp) == {"channel", "sha", "base_digest", "force", "dry_run"}, inp
assert inp["base_digest"]["type"] == "string" and inp["base_digest"]["default"] == ""
assert inp["dry_run"]["type"] == "boolean" and inp["dry_run"]["default"] is False
assert inp["channel"]["options"] == ["testing", "latest", "beta"] and inp["channel"]["default"] == "latest"
assert inp["sha"]["type"] == "string" and inp["force"]["type"] == "boolean" and inp["force"]["default"] is False
assert w["run-name"] == "dx ${{ inputs.channel }} ${{ inputs.sha || github.sha }}", w["run-name"]
assert "workflow_run" not in "".join(l for l in open(sys.argv[1]) if not l.lstrip().startswith("#"))
PY
check "workflow: the triggering workflow names are the real ones" bash -c "grep -qx 'name: Build container image' '$here/.github/workflows/build.yml' && grep -qx 'name: Build beta image' '$here/.github/workflows/build-beta.yml'"
check "workflow: the plan job runs only on testing (channel testing) or main (latest, beta), never another ref; the later jobs follow the plan" python3 - "$wf" <<'PY'
import sys, yaml
w = yaml.safe_load(open(sys.argv[1]))
cond = " ".join(w["jobs"]["plan"]["if"].split())
assert "github.ref == 'refs/heads/testing' && inputs.channel == 'testing'" in cond, cond
assert "github.ref == 'refs/heads/main' && contains(fromJSON('[\"latest\",\"beta\"]'), inputs.channel)" in cond, cond
assert "pull_request" not in cond and "feat" not in cond
assert w["jobs"]["build"]["needs"] == "plan" and w["jobs"]["build"]["if"] == "needs.plan.outputs.build == 'true' && !inputs.dry_run"
assert w["jobs"]["promote"]["needs"] == "plan" and w["jobs"]["promote"]["if"] == "needs.plan.outputs.promote == 'true' && !inputs.dry_run"
assert w["jobs"]["sign"]["needs"] == ["build", "promote"]
PY
check "workflow: the plan refuses a sha that is not a full commit sha or not on the ref (nothing off the branch is built)" python3 - "$wf" <<'PY'
import sys, yaml
w = yaml.safe_load(open(sys.argv[1]))
st = next(s for s in w["jobs"]["plan"]["steps"] if s.get("name", "").startswith("Check the commit belongs"))
assert "[0-9a-f]{40}" in st["run"] and "git merge-base --is-ancestor" in st["run"] and 'git fetch --no-tags origin "${GITHUB_REF}"' in st["run"]
PY
check "workflow: channel, sha and dry_run are the inputs; the group build-dx-<channel> never cancels a running build and is the group the old workflow_run version used" python3 - "$wf" <<'PY'
import sys, yaml
w = yaml.safe_load(open(sys.argv[1]))
assert w["env"] == {"CHANNEL": "${{ inputs.channel }}", "FORCE": "${{ inputs.force || false }}", "SHA": "${{ inputs.sha || github.sha }}", "DRY_RUN": "${{ inputs.dry_run || false }}"}, w["env"]
assert w["concurrency"]["group"] == "build-dx-${{ inputs.channel == 'latest' && format('latest-{0}', inputs.sha || github.sha) || inputs.channel }}" and w["concurrency"]["cancel-in-progress"] is False
assert w["jobs"]["build"]["env"]["CHANNEL"] == "${{ needs.plan.outputs.channel }}"
assert w["jobs"]["build"]["env"]["BASE_DIGEST"] == "${{ needs.plan.outputs.base_digest }}"
assert w["jobs"]["build"]["env"]["BASE_TAG"] == "${{ needs.plan.outputs.base_tag }}"
assert w["jobs"]["build"]["env"]["DX_INPUTS"] == "${{ needs.plan.outputs.dx_inputs }}"
PY
check "workflow: least privilege per job, signing in the signing environment, plan only reads packages" python3 - "$wf" <<'PY'
import sys, yaml
w = yaml.safe_load(open(sys.argv[1]))
assert w["permissions"] == {"contents": "read"}
assert w["jobs"]["plan"]["permissions"] == {"contents": "read", "packages": "read"}
for n in ("build", "promote", "sign"):
    assert w["jobs"][n]["permissions"] == {"contents": "read", "packages": "write"}, n
assert w["jobs"]["dx_result"]["permissions"] == {"contents": "read", "statuses": "write"}
assert "environment" not in w["jobs"]["promote"] and "environment" not in w["jobs"]["dx_result"]
assert w["jobs"]["sign"]["environment"] == "signing"
assert "environment" not in w["jobs"]["build"] and "environment" not in w["jobs"]["plan"]
PY
# (the SHA pins of every workflow are checked once, in tests/test-workflow.sh)
check "workflow: pushes <channel> and <channel>-<date>-<sha> (testing: testing and testing-<sha>), one push-tags.sh call (one push, the other tag a digest copy), nothing else" bash -c "
  set -e
  [ \$(grep -c 'push-tags.sh' '$wf') = 1 ]
  ! grep -q 'podman push' '$wf'
  grep -q 'alias_tags=\"\${CHANNEL}-\$(date +%Y%m%d)-\${sha} \${CHANNEL}\"' '$wf'
  grep -q 'alias_tags=\"testing-\${sha} testing\"' '$wf'
  grep -q 'sha=\$(git rev-parse --short=7 HEAD)' '$wf'
  grep -q '.github/scripts/push-tags.sh \"octarine-os-dx:\${CHANNEL}\" \"\${DX_IMAGE}\" \${ALIAS_TAGS}' '$wf'
  ! grep -qE 'generate-build-tags|tag-images' '$wf'"
check "workflow: every pushed digest is signed and both pushed tags are verified with cosign.pub" bash -c "
  grep -q 'cosign sign -y --new-bundle-format=false --use-signing-config=false --key env://COSIGN_PRIVATE_KEY \"\${IMAGE}@\${digest}\"' '$wf'
  grep -q 'for digest in \${DIGESTS}' '$wf'
  grep -q 'for tag in \${ALIAS_TAGS}' '$wf' && grep -q 'cosign verify --key cosign.pub \"\${IMAGE}:\${tag}\"' '$wf'
  grep -q 'alias_tags: .*steps.tags' '$wf' && grep -q 'digests: .*steps.push' '$wf'"
check "workflow: the base is verified (plan and build), the dev-packages pin is verified with the toolbox key, size guard, smoke test and rechunk run before the push" python3 - "$wf" <<'PY'
import sys, yaml
w = yaml.safe_load(open(sys.argv[1]))
text = lambda j: "\n".join(s.get("run", "") for s in w["jobs"][j]["steps"])
assert 'cosign verify --key cosign.pub "${BASE_IMAGE}@${BASE_DIGEST}"' in text("build")
assert 'cosign verify --key keys/redcodeworks-toolbox-cosign.pub "${ref}"' in text("build")
names = [s.get("name") for s in w["jobs"]["build"]["steps"]]
for a, b in (("Check the dev-packages pin", "Build the image"), ("Check image size", "Smoke test the image"),
             ("Smoke test the image", "Rechunk with chunkah"), ("Rechunk with chunkah", "Push to GHCR"),
             ("Check the version is channel-neutral", "Push to GHCR")):
    assert names.index(a) < names.index(b), (a, b)
size = next(s for s in w["jobs"]["build"]["steps"] if s.get("name") == "Check image size")
assert int(size["env"]["MAX_IMAGE_GIB"]) > 0 and "MAX_IMAGE_GIB" in size["run"]
assert "dx-smoke.sh" in text("build") and 'just rechunk octarine-os-dx "${CHANNEL}"' in text("build")
PY
check "workflow: the build is by digest and has explicit labels (base name and digest, no inherited maintainer data)" bash -c "
  grep -q -- '--build-arg \"BASE_DIGEST=\${BASE_DIGEST}\"' '$wf'
  for l in title description source licenses vendor revision version created url documentation base.name base.digest; do grep -q -- \"--label \\\"org.opencontainers.image.\$l=\" '$wf' || { echo missing \$l; exit 1; }; done
  grep -q -- '--unsetlabel org.opencontainers.image.maintainer' '$wf'
  grep -q -- '--unsetlabel io.github.redcodeworks.octarine-os.base-index-digest' '$wf'
  grep -q 'io.github.redcodeworks.octarine-os.dx-tree=' '$wf' && grep -q 'io.github.redcodeworks.octarine-os.dx-inputs=\${DX_INPUTS}' '$wf'
  grep -q -- '--unsetlabel io.github.redcodeworks.octarine-os.vanilla-inputs' '$wf'"
check "build.yml and build-beta.yml only dispatch the dx workflow (no dx build steps, no uses:), the NVIDIA variant never mentions it" bash -c "! grep -l 'build-dx\|octarine-os-dx' '$here/.github/workflows/build-nvidia.yml' && ! grep -q 'variants/dx/Containerfile' '$here/.github/workflows/build.yml' '$here/.github/workflows/build-beta.yml' && ! grep -q 'build-dx.yml$' <(grep 'uses:' '$here/.github/workflows/build.yml' '$here/.github/workflows/build-beta.yml')"

# ---- the plan: the decision table is tested by tests/plan-dx.sh, which the runner runs on its own
check "workflow: the aggregate job always runs, needs plan, build, promote and sign; it is named 'Build dx and push image' only when the built commit is the tip of the ref (else 'Build dx (older commit)', and never the required name in a dry run); the commit status of the same name is posted on the BUILT commit for channel testing only, never in a dry run" python3 - "$wf" <<'PY'
import sys, yaml
w = yaml.safe_load(open(sys.argv[1]))
j = w["jobs"]["dx_result"]
assert j["name"] == "${{ inputs.dry_run && 'Build dx (dry run)' || ((inputs.sha || github.sha) == github.sha && 'Build dx and push image' || 'Build dx (older commit)') }}", j["name"]
assert j["if"] == "always()" and j["needs"] == ["plan", "build", "promote", "sign"], j
post = next(s for s in j["steps"] if "commit status" in s.get("name", ""))
assert post["if"] == "always() && needs.plan.result != 'skipped' && inputs.channel == 'testing' && !inputs.dry_run", post["if"]
assert 'context="Build dx and push image"' in post["run"] and "statuses/${SHA}" in post["run"] and "workflow_run" not in post["run"]
assert any(s.get("run") == ".github/scripts/aggregate-dx.sh" for s in j["steps"])
PY
check "workflow: every checkout takes the built commit (env.SHA, not the ref tip), the plan with full history" python3 - "$wf" <<'PY'
import sys, yaml
w = yaml.safe_load(open(sys.argv[1]))
for n in ("plan", "build", "promote", "sign"):
    co = w["jobs"][n]["steps"][0]
    assert co["uses"].startswith("actions/checkout@") and co["with"]["ref"] == "${{ env.SHA }}", (n, co)
assert w["jobs"]["plan"]["steps"][0]["with"]["fetch-depth"] == 0
PY
check "build.yml: dispatch_dx is the last job, guarded (always() and the base aggregate succeeded, main or testing only), needs the base aggregate (and the two jobs whose digest it hands over), has actions: write, passes the built commit; nothing of the base needs it" python3 - "$here" <<'PY'
import sys, yaml
w = yaml.safe_load(open(sys.argv[1] + "/.github/workflows/build.yml"))
d = w["jobs"]["dispatch_dx"]
assert d["needs"] == ["build_result", "build_push", "promote"] and d["if"].startswith("always() && needs.build_result.result == 'success'"), d
assert "refs/heads/main" in d["if"] and "refs/heads/testing" in d["if"] and "pull_request" not in d["if"]
assert d["permissions"] == {"contents": "read", "actions": "write"}
run = next(s["run"] for s in d["steps"] if "dispatch-dx.sh" in s.get("run", ""))
assert '"${GITHUB_SHA}"' in run and '"${BASE_DIGEST}"' in run and "'testing'" in run and "'latest'" in run, run
for n, j in w["jobs"].items():
    nd = j.get("needs") or []
    nd = [nd] if isinstance(nd, str) else nd
    assert n == "dispatch_dx" or "dispatch_dx" not in nd, n
PY
check "build-beta.yml: dispatch_dx follows the beta sign job, main only, channel beta, actions: write" python3 - "$here" <<'PY'
import sys, yaml
w = yaml.safe_load(open(sys.argv[1] + "/.github/workflows/build-beta.yml"))
d = w["jobs"]["dispatch_dx"]
assert d["needs"] == "sign" and d["if"].startswith("always() && needs.sign.result == 'success'") and "refs/heads/main" in d["if"], d
assert d["permissions"] == {"contents": "read", "actions": "write"}
assert any('dispatch-dx.sh beta "${GITHUB_SHA}"' in s.get("run", "") for s in d["steps"])
PY
check "workflow: promote copies with skopeo --preserve-digests and compares the digest before and, polling, after" bash -c "
  grep -q 'skopeo copy --all --preserve-digests' '$wf' && grep -q 'now=\$(\"\${lookup}\" \"\${SOURCE_TAG}\")' '$wf' && grep -q 'registry-settled.sh \"\${IMAGE}\" \"\${tag}\" \"\${SOURCE_DIGEST}\"' '$wf'"

# ---- Containerfile, scripts and package lists
cf="$here/variants/dx/Containerfile"
check "Containerfile: ARGs BASE_IMAGE, BASE_TAG and BASE_DIGEST before the first FROM, base pinned by digest" python3 - "$cf" <<'PY'
import re, sys
lines = open(sys.argv[1]).read().splitlines()
first = next(i for i, l in enumerate(lines) if l.startswith("FROM "))
head = "\n".join(lines[:first])
for a in ("ARG BASE_IMAGE=ghcr.io/redcodeworks/octarine-os", "ARG BASE_TAG=latest", "ARG BASE_DIGEST="):
    assert a in head, a
assert "FROM ${BASE_IMAGE}:${BASE_TAG}${BASE_DIGEST:+@}${BASE_DIGEST}" in lines
PY
tag=$(sed -n 's/^ARG DEV_PACKAGES_TAG=//p' "$cf")
dig=$(sed -n 's/^ARG DEV_PACKAGES_DIGEST=//p' "$cf")
check "Containerfile: dev-packages tag is latest or latest-YYYYMMDD-<sha>" test -n "$(printf '%s' "$tag" | grep -E '^(latest|latest-[0-9]{8}-[0-9a-f]{7})$')"
check "Containerfile: dev-packages digest is sha256: plus 64 hex characters" test -n "$(printf '%s' "$dig" | grep -E '^sha256:[0-9a-f]{64}$')"
check "Containerfile: the devpkgs stage uses the digest, the bind mount runs install.sh through dx.sh" bash -c "
  grep -qx 'FROM ghcr.io/redcodeworks/dev-packages@\${DEV_PACKAGES_DIGEST} AS devpkgs' '$cf'
  grep -q 'from=devpkgs,source=/,target=/dev-packages' '$cf' && grep -q 'bash /dev-packages/install.sh' '$here/variants/dx/dx.sh'"
check "no datastore pin, stage, bind mount, helper, Quadlet or render script is left in the dx image's inputs (the datastore is a bundle fetched on demand)" bash -c "! grep -rqiE 'DATASTORE_IMAGES|datastoreimgs|datastore-images/images' '$here/variants/dx' '$here/.github/workflows' '$here/.github/scripts' '$here/Justfile' && ! test -e '$here/variants/dx/datastore' && ! test -e '$here/variants/dx/system_files/usr/share/octarine-os/lib/datastore.sh'"
check "Containerfile: the build context carries the toolbox key for the bundle's signature policy" bash -c "grep -qx 'COPY keys/redcodeworks-toolbox-cosign.pub /toolbox-cosign.pub' '$cf'"
check "Containerfile: ends with the strict lint (bootc container lint --fatal-warnings, no truncation)" bash -c "tail -1 '$cf' | grep -qx 'RUN --network=none bootc container lint --fatal-warnings --no-truncate'"
check "dx.sh: bash syntax, strict extras install, podman.socket, kernel unchanged" bash -c "
  bash -n '$here/variants/dx/dx.sh' && grep -q 'dnf5 -y install --setopt=strict=1' '$here/variants/dx/dx.sh' &&
  grep -q 'systemctl enable podman.socket' '$here/variants/dx/dx.sh' && grep -q 'changed the kernel' '$here/variants/dx/dx.sh'"
check "extras.txt: plain package names (no groups, no alternatives), no duplicates" python3 - "$here/variants/dx/packages/extras.txt" <<'PY'
import sys
lines = open(sys.argv[1]).read().splitlines()
names = [l.split("#")[0].strip() for l in lines if l.split("#")[0].strip()]
assert len(names) == len(set(names)), "duplicate names"
assert all(not n.startswith("@") and "|" not in n and " " not in n for n in names)
PY
check "no Flatpak preinstall list ships VS Code or virt-manager (dx has no flatpak dir; Boxes is in the default list)" bash -c "
  [ ! -e '$here/variants/dx/system_files/usr/share/flatpak' ] && ! grep -rqE 'visualstudio|virt_manager' '$here/system_files/usr/share/flatpak' \
  && grep -qx '\[Flatpak Preinstall org.gnome.Boxes\]' '$here/system_files/usr/share/flatpak/preinstall.d/gnome.preinstall'"
check "the default Containerfile and build.sh stay free of the dx package list" bash -c "! grep -q 'dev-packages\|variants/dx' '$here/Containerfile' '$here/build_files/build.sh'"
check "the vendored toolbox key is a public key and is described in docs/signing-keys.md" bash -c "head -1 '$here/keys/redcodeworks-toolbox-cosign.pub' | grep -qx -- '-----BEGIN PUBLIC KEY-----' && grep -q redcodeworks-toolbox-cosign.pub '$keys_doc'"

# ---- signature policy: all three repositories, from any image name
policy_run() { # image name
    local t="$root/pol-$1"
    mkdir -p "$t/etc/containers/registries.d" "$t/etc/pki/containers"
    echo '{"default":[{"type":"insecureAcceptAnything"}],"transports":{"docker":{"":[{"type":"insecureAcceptAnything"}]}}}' >"$t/etc/containers/policy.json"
    sed -n '/^# --- Container signature policy/,/^# --- end signature policy ---/p' "$here/build_files/build.sh" \
        | sed -e "s#/etc/#$t/etc/#g" -e "s#/ctx/cosign.pub#$here/cosign.pub#g" >"$t/block.sh"
    IMAGE_ORG=redcodeworks IMAGE_NAME="$1" bash -e "$t/block.sh" >"$root/out" 2>&1
}
for n in octarine-os octarine-os-nvidia octarine-os-dx octarine-os-nvidia-dx; do
    policy_run "$n"
    for r in octarine-os octarine-os-nvidia octarine-os-dx octarine-os-nvidia-dx; do
        check "policy ($n image): sigstoreSigned rule for ghcr.io/redcodeworks/$r" python3 -c "
import json
d = json.load(open('$root/pol-$n/etc/containers/policy.json'))['transports']['docker']['ghcr.io/redcodeworks/$r']
assert d[0]['type'] == 'sigstoreSigned' and d[0]['signedIdentity'] == {'type': 'matchRepository'} and d[0]['keyPath'].endswith('.pub')"
    done
    check "policy ($n image): the catch-all stays last" python3 -c "import json; d=json.load(open('$root/pol-$n/etc/containers/policy.json'))['transports']['docker']; assert list(d)[-1]==''"
    check "policy ($n image): sigstore attachments enabled for the namespace" grep -q 'use-sigstore-attachments: true' "$root"/pol-$n/etc/containers/registries.d/*.yaml
done
# the dx.sh block that adds the policy for the datastore bundle: run on a copy of the default policy
bt="$root/bundlepol"; mkdir -p "$bt/etc/containers/registries.d" "$bt/etc/pki/containers"
echo '{"default":[{"type":"insecureAcceptAnything"}],"transports":{"docker":{"ghcr.io/redcodeworks/octarine-os":[{"type":"sigstoreSigned","keyPath":"/k","signedIdentity":{"type":"matchRepository"}}],"":[{"type":"insecureAcceptAnything"}]}}}' >"$bt/etc/containers/policy.json"
sed -n '/^# --- datastore bundle signature policy ---/,/^# --- end datastore bundle signature policy ---/p' "$here/variants/dx/dx.sh" | sed -e "s#/etc/#$bt/etc/#g" -e "s#/ctx/toolbox-cosign.pub#$here/keys/redcodeworks-toolbox-cosign.pub#g" >"$bt/block.sh"
check "dx.sh bundle policy: the block runs" bash -e "$bt/block.sh"
check "dx.sh bundle policy: a sigstoreSigned rule for the bundle repository with the toolbox key, the image's own rules and the catch-all kept, catch-all last" python3 -I - "$bt" "$here/keys/redcodeworks-toolbox-cosign.pub" <<'PY'
import json, sys
bt, pub = sys.argv[1:]
d = json.load(open(bt + "/etc/containers/policy.json"))["transports"]["docker"]
r = d["ghcr.io/redcodeworks/datastore-images"]
assert len(r) == 1 and r[0]["type"] == "sigstoreSigned" and r[0]["signedIdentity"] == {"type": "matchRepository"}
assert open(r[0]["keyPath"]).read() == open(pub).read()
assert "ghcr.io/redcodeworks/octarine-os" in d and list(d)[-1] == ""
PY
check "dx.sh bundle policy: registries.d reads the signature attachments of exactly the bundle repository" bash -c "grep -q 'ghcr.io/redcodeworks/datastore-images:' '$bt'/etc/containers/registries.d/*.yaml && grep -q 'use-sigstore-attachments: true' '$bt'/etc/containers/registries.d/*.yaml"
check "the default smoke test asserts the dx rule" bash -c "grep -q 'covers the dx variant repository\" \"grep -q \$REF-dx' '$here/.github/scripts/default-smoke.sh'"

# ---- the in-image smoke script with stub tools
smoke="$here/.github/scripts/dx-smoke.sh"
check "smoke: bash syntax, no producer-pipe-into-grep -q (pipefail)" bash -c "bash -n '$smoke' && ! grep -v '^[[:space:]]*#' '$smoke' | grep -nE '\\|[[:space:]]*grep -q'"
sb="$root/sb"
mk_world() { # kernel dir name; rebuilds the stub world: a passing dx image
    rm -rf "$sb"; mkdir -p "$sb/bin" "$sb/sys" "$sb/modules/$1" "$sb/units" "$sb/pre" "$sb/share/ublue-os/just" "$sb/share/octarine-os/lib" "$sb/share/ublue-os/distrobox" "$sb/etc/profile.d" "$sb/etc/default" "$sb/lib/bootc/kargs.d" "$sb/usr-bin" "$sb/share/fish/vendor_conf.d"
    for c in bash sh grep sed ls basename tr sort head cat python3 dirname; do p=$(command -v "$c") && ln -sf "$p" "$sb/sys/$c"; done
    for c in gcc g++ clang cmake ninja meson gdb pkgconf uv rustup-init fish qemu-kvm virt-manager virt-viewer virt-install visudo; do printf '#!/bin/sh\nexit 0\n' >"$sb/bin/$c"; done
    printf '#!/bin/sh\necho "dev niri-setup user-setup"\n' >"$sb/bin/ujust"
    cat >"$sb/bin/rpm" <<'F'
#!/usr/bin/env bash
# rpm -q NAME: ok when NAME is in $RPM_LIST; rpm -qa [glob]: print the list
if [[ "$1" == -qa ]]; then cat "$RPM_LIST"; exit 0; fi
shift
rc=0; for p in "$@"; do grep -qxF -- "$p" "$RPM_LIST" || rc=1; done; exit "$rc"
F
    cat >"$sb/bin/systemctl" <<'F'
#!/usr/bin/env bash
[[ -n "${SYSTEMCTL_FAIL:-}" && "$*" == *"${SYSTEMCTL_FAIL}"* ]] && exit 1
exit 0
F
    cat >"$sb/bin/pkgconf" <<'F'
#!/usr/bin/env bash
exit "${PKGCONF_RC:-0}"
F
    chmod +x "$sb/bin"/*
    echo initramfs >"$sb/modules/$1/initramfs.img"
    touch "$sb/units/libvirtd.service" "$sb/units/virtqemud.service" "$sb/units/virtnetworkd.service" "$sb/units/virtstoraged.service"
    printf '[Flatpak Preinstall io.github.kolunmi.Bazaar]\nBranch=stable\n' >"$sb/pre/tools.preinstall"
    printf '[Flatpak Preinstall org.gnome.Example]\nBranch=stable\n' >"$sb/pre/gnome.preinstall"
    echo x >"$sb/share/ublue-os/just/70-octarine-dev.just"; echo 'import? "/usr/share/ublue-os/just/70-octarine-dev.just"' >"$sb/share/ublue-os/justfile"
    printf '#!/bin/sh\nexit 0\n' >"$sb/usr-bin/sdk"; chmod +x "$sb/usr-bin/sdk"
    printf 'GROUP=100\nSHELL=/bin/bash\n' >"$sb/etc/default/useradd"
    echo x >"$sb/share/ublue-os/just/72-octarine-datastore.just"; echo x >"$sb/share/ublue-os/just/75-octarine-virthost.just"
    mkdir -p "$sb/etc/containers/registries.d" "$sb/etc/pki/containers"; cp "$here/keys/redcodeworks-toolbox-cosign.pub" "$sb/etc/pki/containers/redcodeworks-toolbox.pub"
    printf 'docker:\n  ghcr.io/redcodeworks/datastore-images:\n    use-sigstore-attachments: true\n' >"$sb/etc/containers/registries.d/redcodeworks-datastore-images.yaml"
    echo 'PATH="$PATH:$HOME/.cargo/bin"' >"$sb/etc/profile.d/octarine-dx-cargo.sh"; echo 'fish_add_path --append $HOME/.cargo/bin' >"$sb/share/fish/vendor_conf.d/octarine-os-30-rustup.fish"
    echo x >"$sb/share/ublue-os/just/60-custom.just"; echo x >"$sb/share/octarine-os/lib/menu.sh"; echo '[dev-toolbox]' >"$sb/share/ublue-os/distrobox/dev-toolbox.ini"
    printf 'ID=fedora\nPRETTY_NAME="octarineOS"\nIMAGE_ID="octarine-os-dx"\nIMAGE_VERSION="%s"\n' "${OS_IMAGE_VERSION:-20261110-abc1234}" >"$sb/os-release"
    echo '{"transports":{"docker":{"ghcr.io/redcodeworks/octarine-os":[],"ghcr.io/redcodeworks/octarine-os-nvidia":[],"ghcr.io/redcodeworks/octarine-os-dx":[],"ghcr.io/redcodeworks/octarine-os-nvidia-dx":[],"ghcr.io/redcodeworks/datastore-images":[{"type":"sigstoreSigned","keyPath":"/etc/pki/containers/redcodeworks-toolbox.pub","signedIdentity":{"type":"matchRepository"}}],"":[]}}}' >"$sb/policy.json"
    printf '%s\n' rustup libvirt qemu-kvm cockpit-machines virt-manager virt-viewer virtiofsd swtpm swtpm-tools edk2-ovmf libvirt-nss dnsmasq glib2-devel openssl-devel pam-u2f snapper tailscale borgbackup zsh distrobox fwupd flatpak gnome-shell bcc >"$sb/rpms"
}
smoke_run() { # BASE_KERNEL
    PATH="$sb/bin:$sb/sys" RPM_LIST="$sb/rpms" MODULES_DIR="$sb/modules" UNIT_DIR="$sb/units" PREINSTALL_DIR="$sb/pre" \
        POLICY_FILE="$sb/policy.json" OS_RELEASE="$sb/os-release" SHARE_DIR="$sb/share" ETC_DIR="$sb/etc" BIN_DIR="$sb/usr-bin" LIB_DIR="$sb/lib" BASE_KERNEL="$1" QUADLET_GENERATOR="$sb/no-generator" \
        bash "$smoke" >"$root/smoke.out" 2>&1
}
K=7.2.15-300.fc45.x86_64
mk_world "$K"; smoke_run "$K"; check "smoke: a complete dx image passes" test $? -eq 0
mk_world "$K"; rm "$sb/bin/clang"; smoke_run "$K"; rc=$?
check "smoke: a missing compiler fails and says which" bash -c "[ $rc -ne 0 ] && grep -q 'FAIL command clang' '$root/smoke.out'"
check "smoke: failure prints diagnostics (kernels, missing packages, units)" bash -c "grep -q 'DIAG kernels found' '$root/smoke.out' && grep -q 'DIAG developer and VM packages not installed' '$root/smoke.out' && grep -q 'DIAG policy scopes' '$root/smoke.out'"
mk_world "$K"; smoke_run "$K"; check "smoke: a passing run prints no diagnostics" bash -c "! grep -q DIAG '$root/smoke.out'"
mk_world "$K"; rm "$sb/bin/virt-manager"; smoke_run "$K"; check "smoke: no virt-manager fails" test $? -ne 0
mk_world "$K"; rm "$sb/bin/virt-viewer"; smoke_run "$K"; check "smoke: no virt-viewer fails" test $? -ne 0
mk_world "$K"; rm "$sb/bin/uv"; smoke_run "$K"; check "smoke: no uv fails" test $? -ne 0
mk_world "$K"; rm "$sb/bin/rustup-init"; smoke_run "$K"; check "smoke: no rustup-init fails" test $? -ne 0
mk_world "$K"; grep -vx rustup "$sb/rpms" >"$sb/r2"; mv "$sb/r2" "$sb/rpms"; smoke_run "$K"; check "smoke: no rustup package fails" test $? -ne 0
mk_world "$K"; smoke_run "$K"; check "smoke: a rustup command is not required (only rustup-init)" bash -c "! grep -q 'command rustup\$' '$root/smoke.out' && grep -q 'PASS command rustup-init' '$root/smoke.out'"
mk_world "$K"; grep -vx glib2-devel "$sb/rpms" >"$sb/r2"; mv "$sb/r2" "$sb/rpms"; smoke_run "$K"; check "smoke: a missing -devel package fails" test $? -ne 0
mk_world "$K"; rm "$sb/units/virtqemud.service"; smoke_run "$K"; check "smoke: a missing virtqemud unit fails" test $? -ne 0
mk_world "$K"; rm "$sb/units/libvirtd.service"; smoke_run "$K"; check "smoke: a missing libvirtd unit fails" test $? -ne 0
mk_world "$K"; rm "$sb/units/virtnetworkd.service"; smoke_run "$K"; check "smoke: a missing virtnetworkd unit fails" test $? -ne 0
mk_world "$K"; grep -vx libvirt-nss "$sb/rpms" >"$sb/r2"; mv "$sb/r2" "$sb/rpms"; smoke_run "$K"; check "smoke: a missing libvirt-nss fails" test $? -ne 0
mk_world "$K"; grep -vx cockpit-machines "$sb/rpms" >"$sb/r2"; mv "$sb/r2" "$sb/rpms"; smoke_run "$K"; check "smoke: a missing cockpit-machines fails" test $? -ne 0
mk_world "$K"; rm "$sb/bin/qemu-kvm"; smoke_run "$K"; check "smoke: no qemu-kvm binary fails" test $? -ne 0
mk_world "$K"; mkdir "$sb/modules/7.2.16-300.fc45.x86_64"; smoke_run "$K"; check "smoke: two kernels fail" test $? -ne 0
mk_world "7.2.14-300.fc45.x86_64"; smoke_run "$K"; check "smoke: a kernel that differs from the base fails" test $? -ne 0
mk_world "$K"; smoke_run ""; check "smoke: an unset BASE_KERNEL fails" test $? -ne 0
mk_world "$K"; printf '[Flatpak Preinstall com.visualstudio.code]\nBranch=stable\n' >"$sb/pre/dx.preinstall"; smoke_run "$K"; check "smoke: a VS Code preinstall entry fails" test $? -ne 0
mk_world "$K"; rm "$sb/pre/gnome.preinstall"; smoke_run "$K"; check "smoke: the default Flatpak lists must survive" test $? -ne 0
mk_world "$K"; sed -i 's#,"ghcr.io/redcodeworks/octarine-os-dx":\[\]##' "$sb/policy.json"; smoke_run "$K"; check "smoke: the dx signature rule is required" test $? -ne 0
mk_world "$K"; printf '#!/bin/sh\necho "niri-setup user-setup"\n' >"$sb/bin/ujust"; smoke_run "$K"; check "smoke: ujust must list the dev recipe" test $? -ne 0
mk_world "$K"; rm "$sb/share/ublue-os/just/70-octarine-dev.just"; smoke_run "$K"; check "smoke: the dev recipe file is required" test $? -ne 0
mk_world "$K"; : >"$sb/share/ublue-os/justfile"; smoke_run "$K"; check "smoke: the justfile import of the dev recipe file is required" test $? -ne 0
mk_world "$K"; echo 'kargs = ["iommu=pt"]' >"$sb/lib/bootc/kargs.d/10-iommu.toml"; smoke_run "$K"; check "smoke: a kargs.d file that mentions iommu fails (no image ships one)" test $? -ne 0
mk_world "$K"; echo 'kargs = ["quiet"]' >"$sb/lib/bootc/kargs.d/10-other.toml"; smoke_run "$K"; check "smoke: an unrelated kargs.d file does not fail the iommu check" test $? -eq 0
mk_world "$K"; sed -i 's#^SHELL=.*#SHELL=/usr/bin/zsh#' "$sb/etc/default/useradd"; smoke_run "$K"; check "smoke: zsh as the default shell of new users fails" test $? -ne 0
mk_world "$K"; sed -i 's#,"ghcr.io/redcodeworks/datastore-images":\[[^]]*\]##' "$sb/policy.json"; smoke_run "$K"; check "smoke: the policy rule for the datastore bundle is required" test $? -ne 0
mk_world "$K"; rm "$sb/etc/pki/containers/redcodeworks-toolbox.pub"; smoke_run "$K"; check "smoke: the key of the bundle's policy rule is required" test $? -ne 0
mk_world "$K"; rm "$sb/etc/containers/registries.d/redcodeworks-datastore-images.yaml"; smoke_run "$K"; check "smoke: the registries.d entry of the bundle is required" test $? -ne 0
mk_world "$K"; mkdir -p "$sb/share/containers/systemd/users"; touch "$sb/share/containers/systemd/users/datastore.pod"; smoke_run "$K"; check "smoke: a baked datastore unit fails (the datastore is not part of the image)" test $? -ne 0
mk_world "$K"; rm "$sb/share/ublue-os/just/72-octarine-datastore.just"; smoke_run "$K"; check "smoke: the datastore recipe file is required" test $? -ne 0
mk_world "$K"; rm "$sb/usr-bin/sdk"; smoke_run "$K"; check "smoke: the sdk wrapper is required" test $? -ne 0
mk_world "$K"; rm "$sb/etc/profile.d/octarine-dx-cargo.sh"; smoke_run "$K"; check "smoke: the cargo profile snippet is required" test $? -ne 0
mk_world "$K"; SYSTEMCTL_FAIL=podman.socket smoke_run "$K"; check "smoke: a disabled podman.socket fails" test $? -ne 0
mk_world "$K"; echo firefox >>"$sb/rpms"; smoke_run "$K"; check "smoke: firefox must stay removed" test $? -ne 0
for rp in rocminfo rocm-smi rocm-hip rocm-opencl hipcc; do
    mk_world "$K"; echo "$rp" >>"$sb/rpms"; smoke_run "$K"; rc=$?
    check "smoke: an installed ROCm package ($rp) fails the dx image" bash -c "[ $rc -ne 0 ] && grep -q 'FAIL ROCm package $rp is NOT installed' '$root/smoke.out'"
done
mk_world "$K"; smoke_run "$K"; check "smoke: a dx image without ROCm passes the ROCm checks" bash -c "[ \$(grep -c 'PASS ROCm package' '$root/smoke.out') = 5 ]"
check "dx.sh: every package it excludes from the shared list is asserted absent by dx-smoke.sh" bash -c "ex=\$(sed -n 's/.*EXCLUDE=\"\\([^\"]*\\)\" bash \\/dev-packages\\/install.sh.*/\\1/p' '$here/variants/dx/dx.sh'); [ -n \"\$ex\" ] && for p in \$ex; do grep -qw -- \"\$p\" '$here/.github/scripts/dx-smoke.sh' || { echo \$p; exit 1; }; done"
mk_world "$K"; PKGCONF_RC=1 smoke_run "$K"; check "smoke: pkgconf not finding glib-2.0 and openssl fails" test $? -ne 0
mk_world "$K"; sed -i 's/^IMAGE_ID=.*/IMAGE_ID="octarine-os"/' "$sb/os-release"; smoke_run "$K"; check "smoke: the default image's IMAGE_ID fails" test $? -ne 0
mk_world "$K"; sed -i '/^IMAGE_ID=/d' "$sb/os-release"; smoke_run "$K"; check "smoke: a missing IMAGE_ID fails" test $? -ne 0
mk_world "$K"; sed -i '/^IMAGE_VERSION=/d' "$sb/os-release"; smoke_run "$K"; check "smoke: a missing IMAGE_VERSION fails" test $? -ne 0
OS_IMAGE_VERSION=latest-20261110-abc1234 mk_world "$K"; smoke_run "$K"; check "smoke: a channel word in a stable IMAGE_VERSION fails" test $? -ne 0
OS_IMAGE_VERSION=beta-20261110-abc1234 mk_world "$K"; smoke_run "$K"; check "smoke: a beta- IMAGE_VERSION fails on the latest channel" test $? -ne 0
OS_IMAGE_VERSION=beta-20261110-abc1234 mk_world "$K"; IMAGE_CHANNEL=beta smoke_run "$K"; check "smoke: a beta- IMAGE_VERSION passes on the beta channel" test $? -eq 0
mk_world "$K"; IMAGE_CHANNEL=beta smoke_run "$K"; check "smoke: an unprefixed IMAGE_VERSION fails on the beta channel" test $? -ne 0
check "workflow: the dx build passes IMAGE_VERSION (beta- prefixed on beta), the smoke test gets the channel, the neutral check knows beta" bash -c "
  grep -q 'os_version=\"beta-\${version}\"' '$wf' && grep -q 'IMAGE_VERSION=\${os_version}' '$wf'
  grep -q 'IMAGE_CHANNEL=\"\${CHANNEL}\"' '$wf' && grep -q 'BETA=\$' '$wf'
  grep -q '^ARG IMAGE_VERSION' '$here/variants/dx/Containerfile' && grep -q 'set_os_release_field IMAGE_ID .*image_id' '$here/variants/dx/dx.sh' && grep -q '^ARG DX_IMAGE_ID=octarine-os-dx' '$here/variants/dx/Containerfile'"
# a long package list with the match first: grep -q on a pipe must not turn SIGPIPE into a failure
mk_world "$K"; { cat "$sb/rpms"; for i in $(seq 1 20000); do echo "pkg-$i"; done; } >"$sb/r2"; mv "$sb/r2" "$sb/rpms"; smoke_run "$K"; check "smoke: a very long package list still passes" test $? -eq 0

# ---- just dev-packages-bump with fake skopeo and cosign
work="$root/work"; bin="$root/bin"
mkdir -p "$bin" "$work/keys" "$work/variants/dx"
cp "$here/Justfile" "$work/Justfile"; cp "$cf" "$work/variants/dx/Containerfile"
echo key >"$work/keys/redcodeworks-toolbox-cosign.pub"
mkdir -p "$work/config"; cp "$here/config/image.env" "$work/config/image.env"
[ -d "$here/githooks" ] && cp -r "$here/githooks" "$work/githooks"
cat >"$bin/skopeo" <<'F'
#!/usr/bin/env bash
echo "skopeo $*" >>"$LOG"
case "$1" in
    inspect) printf 'manifest of %s' "${@: -1}" ;;
    list-tags) echo '{"Tags":["latest","testing","latest-20261105-aaaaaaa","latest-20261109-0969783","latest-20261112-bbbbbbb","testing-20261112-ccccccc"]}' ;;
esac
F
cat >"$bin/cosign" <<'F'
#!/usr/bin/env bash
echo "cosign $*" >>"$LOG"
exit "${COSIGN_RC:-0}"
F
chmod +x "$bin"/*
export LOG="$root/log"
REAL_JUST=$(command -v just)
bump() { (cd "$work" && PATH="$bin:$PATH" "$REAL_JUST" --justfile Justfile --working-directory . dev-packages-bump "$@") >"$root/out" 2>&1; rc=$?; }
expect_digest() { printf 'manifest of docker://ghcr.io/redcodeworks/dev-packages:%s' "$1" | sha256sum | sed 's/ .*//'; }
: >"$LOG"; bump latest-20261105-aaaaaaa
check "bump with a dated tag: exit 0, digest from the raw manifest, tag written" bash -c "[ $rc = 0 ] && grep -qx 'ARG DEV_PACKAGES_DIGEST=sha256:$(expect_digest latest-20261105-aaaaaaa)' '$work/variants/dx/Containerfile' && grep -qx 'ARG DEV_PACKAGES_TAG=latest-20261105-aaaaaaa' '$work/variants/dx/Containerfile'"
check "bump: cosign verified the digest reference with the toolbox key first" grep -qF "cosign verify --key keys/redcodeworks-toolbox-cosign.pub ghcr.io/redcodeworks/dev-packages@sha256:$(expect_digest latest-20261105-aaaaaaa)" "$LOG"
check "bump: the rest of the Containerfile is untouched" bash -c "diff <(grep -vE '^ARG DEV_PACKAGES_(TAG|DIGEST)=' '$cf') <(grep -vE '^ARG DEV_PACKAGES_(TAG|DIGEST)=' '$work/variants/dx/Containerfile')"
cp "$cf" "$work/variants/dx/Containerfile"; COSIGN_RC=1 bump latest-20261109-0969783
check "bump: a verification failure exits 1 and leaves the Containerfile unchanged" bash -c "[ $rc = 1 ] && cmp -s '$cf' '$work/variants/dx/Containerfile'"
bump 'latest;rm'
check "bump: a bad tag is refused and changes nothing" bash -c "[ $rc = 1 ] && cmp -s '$cf' '$work/variants/dx/Containerfile'"
bump
check "bump with no tag resolves latest and records the dated tag that has the same digest" bash -c "[ $rc = 0 ] && grep -qx 'ARG DEV_PACKAGES_TAG=latest' '$work/variants/dx/Containerfile' && grep -qx 'ARG DEV_PACKAGES_DIGEST=sha256:$(expect_digest latest)' '$work/variants/dx/Containerfile'"
# with this fake registry every tag has its own manifest, so no dated tag matches latest and the tag stays latest (above);
# make latest-20261109-0969783 identical to latest to see the alias found
cat >"$bin/skopeo" <<'F'
#!/usr/bin/env bash
case "$1" in
    inspect) ref="${@: -1}"; [[ "${ref}" == *:latest-20261109-0969783 ]] && ref="${ref%:*}:latest"; printf 'manifest of %s' "${ref}" ;;
    list-tags) echo '{"Tags":["latest","testing","latest-20261105-aaaaaaa","latest-20261109-0969783","testing-20261112-ccccccc"]}' ;;
esac
F
cp "$cf" "$work/variants/dx/Containerfile"; bump
check "bump latest: the matching dated tag is written for humans, testing tags are ignored" bash -c "[ $rc = 0 ] && grep -qx 'ARG DEV_PACKAGES_TAG=latest-20261109-0969783' '$work/variants/dx/Containerfile'"

echo "passed: $pass, failed: $failn"
[ "$failn" = 0 ]
