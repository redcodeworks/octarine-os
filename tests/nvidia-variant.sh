#!/usr/bin/env bash
# Tests for the NVIDIA variant: the workflow triggers, the signature policy of both repositories, the kernel-matched
# akmods tag (stub skopeo), the in-image smoke checks (stub rpm, semodule) and the prune mode for released tags.
# Run: tests/nvidia-variant.sh
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
root=$(mktemp -d)
trap 'rm -rf -- "$root"' EXIT
pass=0
failn=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { failn=$((failn + 1)); echo "FAIL $1"; [ -f "$root/out" ] && sed 's/^/     /' "$root/out"; }
check() { local d=$1; shift; if "$@" >"$root/out" 2>&1; then ok "$d"; else bad "$d"; fi; }

# ---- workflow triggers
if python3 -c 'import yaml' 2>/dev/null; then
    check "workflow: only schedule and workflow_dispatch trigger the variant" python3 - "$here/.github/workflows/build-nvidia.yml" <<'PY'
import sys, yaml
w = yaml.safe_load(open(sys.argv[1]))
on = w.get(True) or w.get("on")
assert set(on) == {"schedule", "workflow_dispatch"}, set(on)
assert len(on["schedule"]) == 1 and on["schedule"][0]["cron"].split()[2:] == ["*", "*", "0"], on["schedule"]
assert w["jobs"]["build"]["if"] == "github.ref == 'refs/heads/main'"
assert w["jobs"]["sign"]["environment"] == "signing"
assert w["concurrency"]["cancel-in-progress"] is False
PY
    check "workflow: all workflow files parse" python3 - "$here" <<'PY'
import glob, sys, yaml
for f in glob.glob(sys.argv[1] + "/.github/workflows/*.yml") + glob.glob(sys.argv[1] + "/.github/actions/*/action.yml"):
    yaml.safe_load(open(f))
PY
else
    echo "skip workflow YAML checks (python3 yaml missing)"
fi
check "the default workflow never builds the variant" bash -c "! grep -q 'build-nvidia\|octarine-os-nvidia:' '$here/.github/workflows/build.yml' || ! grep -q 'variants/nvidia' '$here/.github/workflows/build.yml'"
check "the default Containerfile and build.sh stay free of the NVIDIA install" bash -c "! grep -q 'nvidia-install' '$here/Containerfile' '$here/build_files/build.sh'"

# ---- signature policy: all three repositories (default, NVIDIA, dx), from any of the image names
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
    check "policy ($n image): rule for the default repository" grep -q '"ghcr.io/redcodeworks/octarine-os"' "$root/pol-$n/etc/containers/policy.json"
    check "policy ($n image): rule for the NVIDIA repository" grep -q '"ghcr.io/redcodeworks/octarine-os-nvidia"' "$root/pol-$n/etc/containers/policy.json"
    check "policy ($n image): rule for the dx repository" grep -q '"ghcr.io/redcodeworks/octarine-os-dx"' "$root/pol-$n/etc/containers/policy.json"
    check "policy ($n image): the catch-all stays last" python3 -c "import json,sys; d=json.load(open('$root/pol-$n/etc/containers/policy.json'))['transports']['docker']; assert list(d)[-1]==''"
    check "policy ($n image): sigstore attachments enabled for the namespace" grep -q 'use-sigstore-attachments: true' "$root"/pol-$n/etc/containers/registries.d/*.yaml
done

# ---- kernel-matched akmods tag
cat >"$root/skopeo" <<'F'
#!/usr/bin/env bash
echo "$*" >>"$SK_LOG"
ref="${@: -1}"
tag="${ref##*:}"
if grep -qxF "$tag" "$SK_TAGS" 2>/dev/null; then printf 'manifest-%s' "$tag"; exit 0; fi
exit 1
F
chmod +x "$root/skopeo"
export SKOPEO="$root/skopeo" SK_LOG="$root/sklog" SK_TAGS="$root/sktags"
k=7.2.15-300.fc45.x86_64
: >"$SK_LOG"; echo "main-45-$k" >"$SK_TAGS"
out=$("$here/.github/scripts/nvidia-akmods-ref.sh" "$k" 45 2>&1); rc=$?
check "akmods: the tag with the architecture is found" test "$rc" = 0 -a "$(sed -n 's/^tag=//p' <<<"$out")" = "main-45-$k"
check "akmods: the digest is that of the raw manifest" grep -qx "digest=sha256:$(printf 'manifest-main-45-%s' "$k" | sha256sum | sed 's/ .*//')" <<<"$out"
check "akmods: ref is image@digest" grep -q '^ref=ghcr.io/ublue-os/akmods-nvidia-lts@sha256:' <<<"$out"
: >"$SK_LOG"; echo "main-45-${k%.x86_64}" >"$SK_TAGS"
out=$("$here/.github/scripts/nvidia-akmods-ref.sh" "$k" 45 2>&1); rc=$?
check "akmods: the tag without the architecture is found" test "$rc" = 0 -a "$(sed -n 's/^tag=//p' <<<"$out")" = "main-45-${k%.x86_64}"
: >"$SK_LOG"; printf 'main-45\nmain-45-7.2.14-300.fc45.x86_64\n' >"$SK_TAGS"
out=$("$here/.github/scripts/nvidia-akmods-ref.sh" "$k" 45 2>&1); rc=$?
check "akmods: no tag for this kernel fails loudly (a different kernel and the moving tag exist)" test "$rc" = 1
check "akmods: the failure says nothing is published" grep -q 'nothing is published' <<<"$out"
check "akmods: the moving main-45 tag is never even looked up" bash -c "! grep -qE 'akmods-nvidia-lts:main-45\$' '$SK_LOG'"
out=$("$here/.github/scripts/nvidia-akmods-ref.sh" "7.2.15-300.fc44.x86_64" 45 2>&1); rc=$?
check "akmods: a kernel of another Fedora release is refused" test "$rc" = 1
out=$("$here/.github/scripts/nvidia-akmods-ref.sh" "not-a-kernel" 45 2>&1); rc=$?
check "akmods: a malformed kernel is refused" test "$rc" = 1
unset SKOPEO

# ---- smoke checks inside the image (stub rpm and semodule, a fake module tree)
mkdir -p "$root/bin"
cat >"$root/bin/rpm" <<'F'
#!/usr/bin/env bash
cat "$RPM_LIST"
F
cat >"$root/bin/lsinitrd" <<'F'
#!/usr/bin/env bash
echo "usr/lib/modules/x/extra/nvidia/nvidia.ko"
F
cat >"$root/bin/semodule" <<'F'
#!/usr/bin/env bash
cat "$SEMODULES"
F
chmod +x "$root/bin"/*
export RPM_LIST="$root/rpms" SEMODULES="$root/semods"
mk_image() { # kernel dir name
    rm -rf "$root/img"
    mkdir -p "$root/img/modules/$1/extra" "$root/img/kargs" "$root/img/modprobe"
    echo ko >"$root/img/modules/$1/extra/nvidia.ko.xz"
    echo initramfs >"$root/img/modules/$1/initramfs.img"
    echo 'kargs = ["rd.driver.blacklist=nouveau", "nvidia-drm.modeset=1"]' >"$root/img/kargs/00-nvidia.toml"
    printf 'blacklist nouveau\noptions nouveau modeset=0\n' >"$root/img/modprobe/00-nouveau-blacklist.conf"
    printf 'kmod-nvidia-%s\nnvidia-driver\nnvidia-gpu-firmware\n' "$1" >"$RPM_LIST"
    echo nvidia-container >"$SEMODULES"
}
smoke() { # mode
    PATH="$root/bin:$PATH" MODULES_DIR="$root/img/modules" KARGS_FILE="$root/img/kargs/00-nvidia.toml" \
        MODPROBE_FILE="$root/img/modprobe/00-nouveau-blacklist.conf" BASE_KERNEL="$K" "$here/.github/scripts/nvidia-smoke.sh" "$1"
}
K=$k
mk_image "$K"
check "smoke present: a complete variant passes" smoke present
mk_image "$K"; rm "$root/img/modules/$K/extra/nvidia.ko.xz"
smoke present >"$root/out" 2>&1; check "smoke present: no kernel module fails" test $? -ne 0
mk_image "$K"; printf 'nvidia-gpu-firmware\n' >"$RPM_LIST"
smoke present >"$root/out" 2>&1; check "smoke present: only the firmware package is not a driver" test $? -ne 0
mk_image "7.2.14-300.fc45.x86_64"
smoke present >"$root/out" 2>&1; check "smoke present: a kernel that differs from the base fails" test $? -ne 0
mk_image "$K"; rm "$root/img/kargs/00-nvidia.toml"
smoke present >"$root/out" 2>&1; check "smoke present: a missing kargs file fails" test $? -ne 0
mk_image "$K"; : >"$SEMODULES"
smoke present >"$root/out" 2>&1; check "smoke present: a missing SELinux module fails" test $? -ne 0
mk_image "$K"; printf 'bash\nnvidia-gpu-firmware\n' >"$RPM_LIST"; rm "$root/img/modules/$K/extra/nvidia.ko.xz"
check "smoke absent: the default image (firmware package only) passes" smoke absent
mk_image "$K"
smoke absent >"$root/out" 2>&1; check "smoke absent: a driver package fails" test $? -ne 0

# ---- the in-tree backlight module is not the driver; every real driver module name counts
bl() { rm -rf "$root/img/modules/$K/extra"; mkdir -p "$root/img/modules/$K/kernel/drivers/platform/x86"; echo ko >"$root/img/modules/$K/kernel/drivers/platform/x86/nvidia-wmi-ec-backlight.ko.xz"; }
mk_image "$K"; bl; printf 'bash\n' >"$RPM_LIST"
check "smoke absent: only the stock nvidia-wmi-ec-backlight module passes" smoke absent
mk_image "$K"; bl
smoke present >"$root/smoke.out" 2>&1; check "smoke present: only the stock backlight module fails the module check" grep -q 'FAIL an NVIDIA kernel module exists' "$root/smoke.out"
for m in nvidia nvidia-drm nvidia-modeset nvidia-uvm nvidia-peermem; do
    mk_image "$K"; rm "$root/img/modules/$K/extra/nvidia.ko.xz"; echo ko >"$root/img/modules/$K/extra/$m.ko.xz"; printf 'bash\n' >"$RPM_LIST"
    smoke absent >"$root/out" 2>&1; check "smoke absent: $m.ko.xz is caught" test $? -ne 0
    mk_image "$K"; rm "$root/img/modules/$K/extra/nvidia.ko.xz"; mkdir -p "$root/img/modules/$K/extra/nvidia"; echo ko >"$root/img/modules/$K/extra/nvidia/$m.ko.xz"
    smoke present >"$root/out" 2>&1; check "smoke present: extra/nvidia/$m.ko.xz passes" test $? -eq 0
done
# initramfs check: the backlight module alone must not satisfy it
cp "$root/bin/lsinitrd" "$root/lsinitrd.real"
printf '#!/usr/bin/env bash\necho "-rw-r--r-- 1 root root 100 Jan 1 00:00 usr/lib/modules/x/kernel/drivers/platform/x86/nvidia-wmi-ec-backlight.ko.xz"\n' >"$root/bin/lsinitrd"
mk_image "$K"
smoke present >"$root/out" 2>&1; grep -q 'FAIL the initramfs contains the nvidia modules' "$root/out"; check "smoke present: the backlight module in the initramfs does not count" test $? -eq 0
printf '#!/usr/bin/env bash\necho "-rw-r--r-- 1 root root 100 Jan 1 00:00 usr/lib/modules/x/extra/nvidia/nvidia-drm.ko"\n' >"$root/bin/lsinitrd"
smoke present >"$root/out" 2>&1; check "smoke present: nvidia-drm.ko in the initramfs counts" test $? -eq 0
# a long listing with the module first: grep -q exits early and must not turn lsinitrd's SIGPIPE into a failure
cat >"$root/bin/lsinitrd" <<'F'
#!/usr/bin/env bash
echo "-rw-r--r-- 1 root root 100 Jan 1 00:00 usr/lib/modules/x/extra/nvidia/nvidia.ko.xz"
for i in $(seq 1 20000); do echo "-rw-r--r-- 1 root root 100 Jan 1 00:00 usr/lib/some/file-$i"; done
F
smoke present >"$root/out" 2>&1; check "smoke present: a long lsinitrd listing (SIGPIPE after the first match) passes" test $? -eq 0
# an lsinitrd that prints nothing, or fails, fails the check and the diagnostics say why
printf '#!/usr/bin/env bash\nexit 0\n' >"$root/bin/lsinitrd"
smoke present >"$root/smoke2.out" 2>&1; check "smoke present: an empty lsinitrd listing fails" grep -q 'FAIL the initramfs contains the nvidia modules' "$root/smoke2.out"
check "smoke present: the diagnostics show the lsinitrd exit status" grep -q 'DIAG lsinitrd exit status: 0' "$root/smoke2.out"
printf '#!/usr/bin/env bash\necho "cpio: boom" >&2\necho "-rw-r--r-- 1 root root 100 Jan 1 00:00 usr/lib/modules/x/extra/nvidia/nvidia.ko.xz"\nexit 3\n' >"$root/bin/lsinitrd"
smoke present >"$root/smoke2.out" 2>&1; check "smoke present: a failing lsinitrd fails the check" grep -q 'FAIL the initramfs contains the nvidia modules' "$root/smoke2.out"
check "smoke present: the diagnostics keep lsinitrd's stderr and status" bash -c "grep -q 'DIAG lsinitrd exit status: 3' '$root/smoke2.out' && grep -q 'DIAG   cpio: boom' '$root/smoke2.out'"
check "smoke present: the diagnostics list the nvidia lines and ls -l" bash -c "grep -q 'DIAG   .*extra/nvidia/nvidia.ko.xz' '$root/smoke2.out' && grep -q 'DIAG ls -l of the initramfs' '$root/smoke2.out'"
cp "$root/lsinitrd.real" "$root/bin/lsinitrd"

# ---- prune: released tags of the variant
d() { printf "$1%.0s" {1..64}; }
json=$(cat <<EOJ
[
 {"id":1,"name":"sha256:$(d a)","created_at":"2026-01-01T00:00:00Z","metadata":{"container":{"tags":["latest","latest-20260101-1111111","20260101"]}}},
 {"id":2,"name":"sha256:$(d b)","created_at":"2026-01-08T00:00:00Z","metadata":{"container":{"tags":["latest-20260108-2222222","20260108-2222222","latest-2222222"]}}},
 {"id":3,"name":"sha256:$(d c)","created_at":"2026-01-15T00:00:00Z","metadata":{"container":{"tags":["latest-20260115-3333333","latest-3333333"]}}},
 {"id":4,"name":"sha256:$(d d)","created_at":"2026-01-22T00:00:00Z","metadata":{"container":{"tags":["latest","latest-20260122-4444444"]}}}
]
EOJ
)
out=$(PRUNE_KIND=released KEEP=1 DRY_RUN=true python3 -I "$here/.github/scripts/prune-testing.py" <<<"$json")
check "prune released: an old dated-only build is deleted" grep -q 'DELETE image id=2 ' <<<"$out"
check "prune released: the newest dated-only build is kept (keep 1)" bash -c "! grep -q 'DELETE image id=3 ' <<<'$out'"
check "prune released: a version that still carries latest is never deleted" bash -c "! grep -qE 'DELETE image id=(1|4) ' <<<'$out'"

echo "passed: $pass, failed: $failn"
[ "$failn" = 0 ]
