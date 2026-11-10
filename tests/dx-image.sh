#!/usr/bin/env bash
# Quick checks of the developer image (octarine-os-dx): the workflow (triggers, guards, channel mapping, permissions,
# pins, tags, signing, concurrency, the plan step with stub tools), the Containerfile and package lists, the signature
# policy of all three repositories, the in-image smoke script (stub tools), the prune rule and the dev-packages pin
# (format and `just dev-packages-bump` with fake skopeo and cosign). Nothing here builds an image.
# Run: tests/dx-image.sh
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
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
    for s in job["steps"]:
        if "run" in s:
            r = subprocess.run(["bash", "-n"], input=s["run"], text=True, capture_output=True)
            assert r.returncode == 0, (name, s.get("name"), r.stderr)
PY
check "workflow: triggers are workflow_run (both builds, completed, main) and dispatch only; no schedule, push or pull request" python3 - "$wf" <<'PY'
import sys, yaml
w = yaml.safe_load(open(sys.argv[1]))
on = w.get(True) or w.get("on")
assert set(on) == {"workflow_run", "workflow_dispatch"}, set(on)
wr = on["workflow_run"]
assert wr["workflows"] == ["Build container image", "Build beta image"], wr
assert wr["types"] == ["completed"] and wr["branches"] == ["main"], wr
inp = on["workflow_dispatch"]["inputs"]
assert set(inp) == {"channel", "force"}, inp
assert inp["channel"]["options"] == ["latest", "beta"] and inp["channel"]["default"] == "latest"
assert inp["force"]["type"] == "boolean" and inp["force"]["default"] is False
PY
check "workflow: the triggering workflow names are the real ones" bash -c "grep -qx 'name: Build container image' '$here/.github/workflows/build.yml' && grep -qx 'name: Build beta image' '$here/.github/workflows/build-beta.yml'"
check "workflow: the plan job builds only on main, after a successful schedule/push/dispatch run of main, never a pull request" python3 - "$wf" <<'PY'
import sys, yaml
w = yaml.safe_load(open(sys.argv[1]))
cond = " ".join(w["jobs"]["plan"]["if"].split())
for part in ("github.ref == 'refs/heads/main'", "github.event.workflow_run.conclusion == 'success'",
             "contains(fromJSON('[\"schedule\",\"push\",\"workflow_dispatch\"]'), github.event.workflow_run.event)",
             "github.event.workflow_run.head_branch == 'main'", "github.event_name == 'workflow_dispatch'"):
    assert part in cond, (part, cond)
assert "pull_request" not in cond
assert w["jobs"]["build"]["needs"] == "plan" and w["jobs"]["build"]["if"] == "needs.plan.outputs.build == 'true'"
assert w["jobs"]["sign"]["needs"] == "build"
PY
check "workflow: the channel is beta after the beta build, latest after the default build, the input on dispatch" python3 - "$wf" <<'PY'
import sys, yaml
w = yaml.safe_load(open(sys.argv[1]))
expect = "github.event_name == 'workflow_dispatch' && inputs.channel || (github.event.workflow_run.name == 'Build beta image' && 'beta' || 'latest')"
assert expect in w["env"]["CHANNEL"], w["env"]
assert w["env"]["FORCE"].startswith("${{ github.event_name == 'workflow_dispatch' && inputs.force")
assert w["concurrency"]["group"] == "build-dx-${{ " + expect + " }}", w["concurrency"]
assert w["concurrency"]["cancel-in-progress"] is False
# the build and the later jobs take the channel from the plan job
assert w["jobs"]["build"]["env"]["CHANNEL"] == "${{ needs.plan.outputs.channel }}"
assert w["jobs"]["build"]["env"]["BASE_DIGEST"] == "${{ needs.plan.outputs.base_digest }}"
PY
check "workflow: least privilege per job, signing in the signing environment, plan only reads packages" python3 - "$wf" <<'PY'
import sys, yaml
w = yaml.safe_load(open(sys.argv[1]))
assert w["permissions"] == {"contents": "read"}
assert w["jobs"]["plan"]["permissions"] == {"contents": "read", "packages": "read"}
for n in ("build", "sign"):
    assert w["jobs"][n]["permissions"] == {"contents": "read", "packages": "write"}, n
assert w["jobs"]["sign"]["environment"] == "signing"
assert "environment" not in w["jobs"]["build"] and "environment" not in w["jobs"]["plan"]
PY
check "workflow: every third-party action is pinned by SHA with a version comment" python3 - "$wf" <<'PY'
import re, sys
for line in open(sys.argv[1]):
    m = re.search(r"uses:\s*(\S+)", line)
    if m and not m.group(1).startswith("./"):
        ref = m.group(1).split("@", 1)[1]
        assert re.fullmatch(r"[0-9a-f]{40}", ref), line
        if "ublue-os/remove-unwanted-software" not in line:  # the other workflows pin this one without a comment too
            assert re.search(r"#\s*v\d", line), line
PY
check "workflow: pushes exactly <channel> and <channel>-<date>-<sha> (one push line, nothing else)" bash -c "
  [ \$(grep -c 'podman push' '$wf') = 1 ]
  grep -q 'alias_tags=\"\${CHANNEL}-\$(date +%Y%m%d)-\$(git rev-parse --short HEAD) \${CHANNEL}\"' '$wf'
  grep -q 'podman push --digestfile=/tmp/digestfile \"octarine-os-dx:\${CHANNEL}\" \"\${DX_IMAGE}:\${tag}\"' '$wf'
  ! grep -qE 'generate-build-tags|tag-images|:testing' '$wf'"
check "workflow: every pushed digest is signed and both pushed tags are verified with cosign.pub" bash -c "
  grep -q 'cosign sign -y --new-bundle-format=false --use-signing-config=false --key env://COSIGN_PRIVATE_KEY \"\${IMAGE}@\${digest}\"' '$wf'
  grep -q 'for digest in \${DIGESTS}' '$wf'
  grep -q 'for tag in \${ALIAS_TAGS}' '$wf' && grep -q 'cosign verify --key cosign.pub \"\${IMAGE}:\${tag}\"' '$wf'
  grep -q 'alias_tags: .*steps.tags' '$wf' && grep -q 'digests: .*steps.push' '$wf'"
check "workflow: the base is verified (plan and build), the dev-packages pin is verified with the toolbox key, size guard 15 GiB, smoke test and rechunk run before the push" python3 - "$wf" <<'PY'
import sys, yaml
w = yaml.safe_load(open(sys.argv[1]))
text = lambda j: "\n".join(s.get("run", "") for s in w["jobs"][j]["steps"])
assert 'cosign verify --key cosign.pub "${base}@${digest}"' in text("plan")
assert 'cosign verify --key cosign.pub "${BASE_IMAGE}@${BASE_DIGEST}"' in text("build")
assert 'cosign verify --key keys/redcodeworks-toolbox-cosign.pub "${ref}"' in text("build")
names = [s.get("name") for s in w["jobs"]["build"]["steps"]]
for a, b in (("Check the dev-packages pin", "Build the image"), ("Check image size", "Smoke test the image"),
             ("Smoke test the image", "Rechunk with rpm-ostree"), ("Rechunk with rpm-ostree", "Push to GHCR"),
             ("Check the version is channel-neutral", "Push to GHCR")):
    assert names.index(a) < names.index(b), (a, b)
size = next(s for s in w["jobs"]["build"]["steps"] if s.get("name") == "Check image size")
assert size["env"]["MAX_IMAGE_GIB"] == 15
assert "dx-smoke.sh" in text("build") and 'just ostree-rechunk octarine-os-dx "${CHANNEL}"' in text("build")
PY
check "workflow: the build is by digest and has explicit labels (base name and digest, no inherited maintainer data)" bash -c "
  grep -q -- '--build-arg \"BASE_DIGEST=\${BASE_DIGEST}\"' '$wf'
  for l in title description source licenses vendor revision version created url documentation base.name base.digest; do grep -q -- \"--label \\\"org.opencontainers.image.\$l=\" '$wf' || { echo missing \$l; exit 1; }; done
  grep -q -- '--unsetlabel org.opencontainers.image.maintainer' '$wf'
  grep -q -- '--unsetlabel io.github.redcodeworks.octarine-os.base-index-digest' '$wf'
  grep -q 'io.github.redcodeworks.octarine-os.dx-tree=' '$wf'"
check "the other workflows do not mention the dx workflow, and the default build does not build dx" bash -c "! grep -l 'build-dx\|octarine-os-dx' '$here/.github/workflows/build.yml' '$here/.github/workflows/build-beta.yml' '$here/.github/workflows/build-nvidia.yml'"

# ---- the plan step, run with stub skopeo, cosign and git
plan_script="$root/plan.sh"
python3 - "$wf" "$plan_script" <<'PY'
import sys, yaml
w = yaml.safe_load(open(sys.argv[1]))
step = next(s for s in w["jobs"]["plan"]["steps"] if s.get("id") == "plan")
open(sys.argv[2], "w").write(step["run"])
PY
mkdir -p "$root/pbin" "$root/repo/variants/dx"
echo x >"$root/repo/variants/dx/f"
(cd "$root/repo" && git init -q . && git add -A && git -c user.email=t@t -c user.name=t commit -qm t)
cat >"$root/pbin/skopeo" <<'F'
#!/usr/bin/env bash
echo "skopeo $*" >>"$PLOG"
ref="${@: -1}"
case "$1 $2" in
    "inspect --raw") printf 'manifest of %s' "${ref}" ;;
    "inspect --config") [[ -n "${DX_CONFIG:-}" ]] && { printf '%s' "${DX_CONFIG}"; exit 0; }; exit 1 ;;
esac
F
cat >"$root/pbin/cosign" <<'F'
#!/usr/bin/env bash
echo "cosign $*" >>"$PLOG"
exit "${COSIGN_RC:-0}"
F
chmod +x "$root/pbin"/*
export PLOG="$root/plog"
plan() { # channel, force; DX_CONFIG from the caller
    : >"$PLOG"; : >"$root/gh_out"; : >"$root/gh_sum"
    (cd "$root/repo" && PATH="$root/pbin:$PATH" CHANNEL="$1" FORCE="${2:-false}" GITHUB_REPOSITORY_OWNER=redcodeworks \
        GITHUB_OUTPUT="$root/gh_out" GITHUB_STEP_SUMMARY="$root/gh_sum" bash -e "$plan_script")
}
want=$(printf 'manifest of docker://ghcr.io/redcodeworks/octarine-os:latest' | sha256sum | sed 's/ .*//')
tree=$(cd "$root/repo" && git rev-parse HEAD:variants/dx)
cfg() { printf '{"config":{"Labels":{"org.opencontainers.image.base.digest":"%s","io.github.redcodeworks.octarine-os.dx-tree":"%s"}}}' "$1" "$2"; }
unset DX_CONFIG
plan latest >"$root/out" 2>&1; check "plan: no published dx image builds" grep -qx build=true "$root/gh_out"
check "plan: the base digest is that of the raw manifest, the channel is passed on" grep -qx "base_digest=sha256:${want}" "$root/gh_out"
check "plan: the base signature was verified by digest with cosign.pub" grep -q "cosign verify --key cosign.pub ghcr.io/redcodeworks/octarine-os@sha256:${want}" "$PLOG"
export DX_CONFIG; DX_CONFIG=$(cfg "sha256:${want}" "${tree}")
plan latest >"$root/plan.out" 2>&1; check "plan: same base digest and same variants/dx tree ends green without a build" grep -qx build=false "$root/gh_out"
check "plan: the notice says base unchanged, nothing to build" grep -q 'base unchanged, nothing to build' "$root/plan.out"
plan latest true >"$root/out" 2>&1; check "plan: force builds although nothing changed" grep -qx build=true "$root/gh_out"
DX_CONFIG=$(cfg "sha256:$(printf 'a%.0s' {1..64})" "${tree}")
plan latest >"$root/out" 2>&1; check "plan: a different base digest builds" grep -qx build=true "$root/gh_out"
DX_CONFIG=$(cfg "sha256:${want}" "0000000")
plan latest >"$root/out" 2>&1; check "plan: a changed variants/dx tree builds" grep -qx build=true "$root/gh_out"
DX_CONFIG=$(cfg "sha256:${want}" "${tree}")
plan beta >"$root/out" 2>&1; check "plan: the beta channel reads octarine-os:beta" grep -q 'inspect --raw docker://ghcr.io/redcodeworks/octarine-os:beta' "$PLOG"
COSIGN_RC=1 plan latest >"$root/out" 2>&1; check "plan: an unsigned base fails the job" test $? -ne 0
plan sideways >"$root/out" 2>&1; check "plan: an unknown channel fails the job" test $? -ne 0

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
check "Containerfile: ends with bootc container lint" bash -c "tail -1 '$cf' | grep -qx 'RUN bootc container lint'"
check "dx.sh: bash syntax, strict extras install, podman.socket, kernel unchanged" bash -c "
  bash -n '$here/variants/dx/dx.sh' && grep -q 'dnf5 -y install --setopt=strict=1' '$here/variants/dx/dx.sh' &&
  grep -q 'systemctl enable podman.socket' '$here/variants/dx/dx.sh' && grep -q 'changed the kernel' '$here/variants/dx/dx.sh'"
check "extras.txt: the briefed packages, grouped with comments, no duplicates, nothing excluded" python3 - "$here/variants/dx/packages/extras.txt" <<'PY'
import sys
lines = open(sys.argv[1]).read().splitlines()
names = [l.split("#")[0].strip() for l in lines if l.split("#")[0].strip()]
assert len(names) == len(set(names)), "duplicate names"
want = """libvirt qemu-kvm cockpit-machines virt-install virtiofsd swtpm swtpm-tools dnsmasq edk2-ovmf
virt-manager virt-viewer libvirt-nss qemu-user-binfmt qemu-user-static genisoimage osbuild-selinux udica
bcc bpftop bpftrace sysprof tiptop trace-cmd numactl
git-subtree git-svn android-tools dbus-x11 ydotool cascadia-code-fonts""".split()
assert names == want, (set(names) ^ set(want))
for bad in "incus incus-agent lxc podman-machine p7zip docker-ce code".split():
    assert bad not in names, bad
assert all(not n.startswith("@") and "|" not in n and " " not in n for n in names)
for heading in ("# --- VM hosting ---", "# --- Virtualization extras ---", "# --- Tracing and performance ---", "# --- Developer extras ---"):
    assert heading in lines, heading
PY
check "no Flatpak preinstall list ships VS Code or virt-manager (dx has no flatpak dir; Boxes is in the default list)" bash -c "
  [ ! -e '$here/variants/dx/system_files/usr/share/flatpak' ] && ! grep -rqE 'visualstudio|virt_manager' '$here/system_files/usr/share/flatpak' \
  && grep -qx '\[Flatpak Preinstall org.gnome.Boxes\]' '$here/system_files/usr/share/flatpak/preinstall.d/gnome.preinstall'"
check "the default Containerfile and build.sh stay free of the dx package list" bash -c "! grep -q 'dev-packages\|variants/dx' '$here/Containerfile' '$here/build_files/build.sh'"
check "the vendored toolbox key is a public key and is described in keys/README.md" bash -c "head -1 '$here/keys/redcodeworks-toolbox-cosign.pub' | grep -qx -- '-----BEGIN PUBLIC KEY-----' && grep -q redcodeworks-toolbox-cosign.pub '$here/keys/README.md'"

# ---- signature policy: all three repositories, from any image name
policy_run() { # image name
    local t="$root/pol-$1"
    mkdir -p "$t/etc/containers/registries.d" "$t/etc/pki/containers"
    echo '{"default":[{"type":"insecureAcceptAnything"}],"transports":{"docker":{"":[{"type":"insecureAcceptAnything"}]}}}' >"$t/etc/containers/policy.json"
    sed -n '/^# --- Container signature policy/,/^# --- end signature policy ---/p' "$here/build_files/build.sh" \
        | sed -e "s#/etc/#$t/etc/#g" -e "s#/ctx/cosign.pub#$here/cosign.pub#g" >"$t/block.sh"
    IMAGE_ORG=redcodeworks IMAGE_NAME="$1" bash -e "$t/block.sh" >"$root/out" 2>&1
}
for n in octarine-os octarine-os-nvidia octarine-os-dx; do
    policy_run "$n"
    for r in octarine-os octarine-os-nvidia octarine-os-dx; do
        check "policy ($n image): sigstoreSigned rule for ghcr.io/redcodeworks/$r" python3 -c "
import json
d = json.load(open('$root/pol-$n/etc/containers/policy.json'))['transports']['docker']['ghcr.io/redcodeworks/$r']
assert d[0]['type'] == 'sigstoreSigned' and d[0]['signedIdentity'] == {'type': 'matchRepository'} and d[0]['keyPath'].endswith('.pub')"
    done
    check "policy ($n image): the catch-all stays last" python3 -c "import json; d=json.load(open('$root/pol-$n/etc/containers/policy.json'))['transports']['docker']; assert list(d)[-1]==''"
    check "policy ($n image): sigstore attachments enabled for the namespace" grep -q 'use-sigstore-attachments: true' "$root"/pol-$n/etc/containers/registries.d/*.yaml
done
check "smoke tests of the default and beta builds assert the dx rule" bash -c "grep -q 'covers the dx variant repository\" \"grep -q \$REF-dx' '$here/.github/workflows/build.yml' && grep -q 'covers the dx variant repository\" \"grep -q \$REF-dx' '$here/.github/workflows/build-beta.yml'"

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
    touch "$sb/units/libvirtd.service" "$sb/units/virtqemud.service"
    printf '[Flatpak Preinstall io.github.kolunmi.Bazaar]\nBranch=stable\n' >"$sb/pre/tools.preinstall"
    printf '[Flatpak Preinstall org.gnome.Example]\nBranch=stable\n' >"$sb/pre/gnome.preinstall"
    echo x >"$sb/share/ublue-os/just/70-octarine-dev.just"; echo 'import? "/usr/share/ublue-os/just/70-octarine-dev.just"' >"$sb/share/ublue-os/justfile"
    printf '#!/bin/sh\nexit 0\n' >"$sb/usr-bin/sdk"; chmod +x "$sb/usr-bin/sdk"
    echo 'kargs = ["iommu=pt"]' >"$sb/lib/bootc/kargs.d/10-iommu.toml"; printf 'GROUP=100\nSHELL=/bin/bash\n' >"$sb/etc/default/useradd"
    echo 'PATH="$PATH:$HOME/.cargo/bin"' >"$sb/etc/profile.d/octarine-dx-cargo.sh"; echo 'fish_add_path --append $HOME/.cargo/bin' >"$sb/share/fish/vendor_conf.d/octarine-os-30-rustup.fish"
    echo x >"$sb/share/ublue-os/just/60-custom.just"; echo x >"$sb/share/octarine-os/lib/menu.sh"; echo '[dev-toolbox]' >"$sb/share/ublue-os/distrobox/dev-toolbox.ini"
    printf 'ID=fedora\nPRETTY_NAME="octarineOS"\nIMAGE_ID="octarine-os-dx"\nIMAGE_VERSION="%s"\n' "${OS_IMAGE_VERSION:-20261110-abc1234}" >"$sb/os-release"
    echo '{"transports":{"docker":{"ghcr.io/redcodeworks/octarine-os":[],"ghcr.io/redcodeworks/octarine-os-nvidia":[],"ghcr.io/redcodeworks/octarine-os-dx":[],"":[]}}}' >"$sb/policy.json"
    printf '%s\n' rustup libvirt qemu-kvm cockpit-machines virtiofsd swtpm edk2-ovmf glib2-devel openssl-devel pam-u2f snapper tailscale borgbackup zsh distrobox fwupd flatpak gnome-shell bcc >"$sb/rpms"
}
smoke_run() { # BASE_KERNEL
    PATH="$sb/bin:$sb/sys" RPM_LIST="$sb/rpms" MODULES_DIR="$sb/modules" UNIT_DIR="$sb/units" PREINSTALL_DIR="$sb/pre" \
        POLICY_FILE="$sb/policy.json" OS_RELEASE="$sb/os-release" SHARE_DIR="$sb/share" ETC_DIR="$sb/etc" BIN_DIR="$sb/usr-bin" LIB_DIR="$sb/lib" BASE_KERNEL="$1" \
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
mk_world "$K"; rm "$sb/lib/bootc/kargs.d/10-iommu.toml"; smoke_run "$K"; check "smoke: the dx image must carry the iommu=pt karg" test $? -ne 0
mk_world "$K"; echo 'kargs = ["quiet"]' >"$sb/lib/bootc/kargs.d/10-iommu.toml"; smoke_run "$K"; check "smoke: the karg file must contain iommu=pt" test $? -ne 0
mk_world "$K"; sed -i 's#^SHELL=.*#SHELL=/usr/bin/zsh#' "$sb/etc/default/useradd"; smoke_run "$K"; check "smoke: zsh as the default shell of new users fails" test $? -ne 0
mk_world "$K"; rm "$sb/usr-bin/sdk"; smoke_run "$K"; check "smoke: the sdk wrapper is required" test $? -ne 0
mk_world "$K"; rm "$sb/etc/profile.d/octarine-dx-cargo.sh"; smoke_run "$K"; check "smoke: the cargo profile snippet is required" test $? -ne 0
mk_world "$K"; SYSTEMCTL_FAIL=podman.socket smoke_run "$K"; check "smoke: a disabled podman.socket fails" test $? -ne 0
mk_world "$K"; echo firefox >>"$sb/rpms"; smoke_run "$K"; check "smoke: firefox must stay removed" test $? -ne 0
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
  grep -q '^ARG IMAGE_VERSION' '$here/variants/dx/Containerfile' && grep -q 'set_os_release_field IMAGE_ID octarine-os-dx' '$here/variants/dx/dx.sh'"
# a long package list with the match first: grep -q on a pipe must not turn SIGPIPE into a failure
mk_world "$K"; { cat "$sb/rpms"; for i in $(seq 1 20000); do echo "pkg-$i"; done; } >"$sb/r2"; mv "$sb/r2" "$sb/rpms"; smoke_run "$K"; check "smoke: a very long package list still passes" test $? -eq 0

# ---- prune rule for the dx package
prune=$here/.github/scripts/prune-testing.py
dxj() { # channel counts: n_latest n_beta [bare-on-oldest]
    python3 - "$1" "$2" "${3:-}" <<'PY'
import json, sys
nl, nb, extra = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
vs = []
i = 0
for ch, n in (("latest", nl), ("beta", nb)):
    for k in range(1, n + 1):
        i += 1
        vs.append({"id": (100 if ch == "latest" else 200) + k, "name": "sha256:" + format(i, "02x") * 32, "created_at": f"2026-02-{k:02d}T00:00:00Z",
                   "metadata": {"container": {"tags": [f"{ch}-202602{k:02d}-{k}{k}{k}{k}{k}{k}{k}"]}}})
if extra == "bare-on-oldest":
    vs[0]["metadata"]["container"]["tags"].append("latest")
    vs[nl]["metadata"]["container"]["tags"].append("beta")
# versions of other kinds that must never be touched
vs += [{"id": 900, "name": "sha256:" + "e" * 64, "created_at": "2025-01-01T00:00:00Z", "metadata": {"container": {"tags": ["testing-aaaaaaa"]}}},
       {"id": 901, "name": "sha256:" + "f" * 64, "created_at": "2025-01-01T00:00:00Z", "metadata": {"container": {"tags": ["20250101-bbbbbbb"]}}},
       {"id": 902, "name": "sha256:" + "d" * 64, "created_at": "2025-01-01T00:00:00Z", "metadata": {"container": {"tags": []}}},
       {"id": 903, "name": "sha256:" + "9" * 64, "created_at": "2025-01-01T00:00:00Z", "metadata": {"container": {"tags": ["latest-20250101-ccccccc", "something-else"]}}},
       {"id": 904, "name": "sha256:" + "8" * 64, "created_at": "2025-01-01T00:00:00Z", "metadata": {"container": {"tags": [f"sha256-{'3' * 64}.sig"]}}}]
print(json.dumps(vs))
PY
}
out=$(dxj 5 5 | PRUNE_KIND=dx KEEP=3 DRY_RUN=true python3 -I "$prune" 2>&1)
check "prune dx: 5 latest and 5 beta builds delete the 2 oldest of each channel" bash -c "[ \$(grep -c 'DELETE image' <<<'$out') = 4 ] && for id in 101 102 201 202; do grep -q \"DELETE image id=\$id \" <<<'$out' || exit 1; done"
check "prune dx: the newest 3 of each channel are kept" bash -c "! grep -qE 'DELETE image id=(103|104|105|203|204|205) ' <<<'$out'"
check "prune dx: other tags, untagged versions and signatures of other images are untouched" bash -c "! grep -qE 'id=(900|901|902|903|904) ' <<<'$out'"
out=$(dxj 5 5 bare-on-oldest | PRUNE_KIND=dx KEEP=3 DRY_RUN=true python3 -I "$prune" 2>&1)
check "prune dx: a version holding the bare latest or beta tag is kept however old" bash -c "! grep -qE 'DELETE image id=(101|201) ' <<<'$out'"
# the oldest of beta (id 201) holds the bare beta tag, the oldest of latest (101) the bare latest tag
check "prune dx: the other old builds still go" bash -c "grep -q 'DELETE image id=102 ' <<<'$out' && grep -q 'DELETE image id=202 ' <<<'$out'"
out=$(dxj 3 2 | PRUNE_KIND=dx KEEP=3 DRY_RUN=true python3 -I "$prune" 2>&1)
check "prune dx: nothing to delete with 3 and 2 builds (keep 3)" grep -q 'Nothing to prune' <<<"$out"
out=$(dxj 5 0 | PRUNE_KIND=dx KEEP=3 DRY_RUN=true python3 -I "$prune" 2>&1)
check "prune dx: counts the channels separately (5 latest, no beta: only 2 deleted)" bash -c "[ \$(grep -c 'DELETE image' <<<'$out') = 2 ]"
sigv() { dxj 5 0 | python3 -c '
import json, sys
vs = json.load(sys.stdin)
doomed = next(v for v in vs if v["id"] == 101)
vs.append({"id": 950, "name": "sha256:" + "7" * 64, "created_at": "2026-02-01T00:00:00Z", "metadata": {"container": {"tags": ["sha256-" + doomed["name"].split(":")[1] + ".sig"]}}})
print(json.dumps(vs))'; }
out=$(sigv | PRUNE_KIND=dx KEEP=3 DRY_RUN=true python3 -I "$prune" 2>&1)
check "prune dx: the signature of a deleted image is deleted with it" grep -q 'DELETE sig   id=950 ' <<<"$out"
check "prune dx: dry run is the default" bash -c "echo '[]' | env -u DRY_RUN PRUNE_KIND=dx python3 -I '$prune' | grep -q 'Nothing to prune'"
check "prune workflow passes the dx kind with keep 3 for the -dx package only" bash -c "grep -q 'PRUNE_KIND=dx KEEP=3' '$here/.github/workflows/prune-testing.yml' && grep -q 'packages/container/\${image}-dx' '$here/.github/workflows/prune-testing.yml'"
check "the other prune kinds ignore dx-shaped tags" bash -c "dxj 5 5 | PRUNE_KIND=beta KEEP=3 DRY_RUN=true python3 -I '$prune' | grep -q 'DELETE image id=[12]0[1-5] ' && exit 1 || exit 0"

# ---- just dev-packages-bump with fake skopeo and cosign
work="$root/work"; bin="$root/bin"
mkdir -p "$bin" "$work/keys" "$work/variants/dx"
cp "$here/Justfile" "$work/Justfile"; cp "$cf" "$work/variants/dx/Containerfile"
echo key >"$work/keys/redcodeworks-toolbox-cosign.pub"
cp "$here/image-template.env" "$work/image-template.env"
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
