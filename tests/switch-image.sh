#!/usr/bin/env bash
# Tests for `ujust switch-image` (system_files/usr/share/ublue-os/just/60-custom.just).
# No network and nothing is switched: skopeo, sudo and bootc are fakes, the running image comes from
# OCTARINE_SWITCH_CURRENT_REF, and the published set from FAKE_PUBLISHED. Needs: bash, just, jq.
# Run: tests/switch-image.sh
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
justdir="$here/../system_files/usr/share/ublue-os/just"
justfile="$justdir/60-custom.just"
root=$(mktemp -d)
trap 'rm -rf -- "$root"' EXIT
pass=0
failn=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { failn=$((failn + 1)); echo "FAIL $1"; sed 's/^/     /' "$root/out" 2>/dev/null; echo "     rc=$rc"; }
check() { local d=$1; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
has() { grep -qF -- "$1" "$root/out"; }
hasnt() { ! grep -qF -- "$1" "$root/out"; }
logged() { grep -qF -- "$1" "$root/log" 2>/dev/null; }
notlogged() { ! grep -qF -- "$1" "$root/log" 2>/dev/null; }

mkdir -p "$root/fakebin"
export LOG="$root/log"
cat >"$root/fakebin/skopeo" <<'EOF2'
#!/bin/bash
# skopeo inspect --raw docker://REG/NAME:TAG ; published when NAME:TAG is in FAKE_PUBLISHED
ref=${@: -1}
ref=${ref#docker://}
nt=${ref##*/}
if [ "${FAKE_SKOPEO_DOWN:-}" = 1 ]; then echo "dial tcp: lookup ghcr.io: no such host" >&2; exit 1; fi
case " ${FAKE_PUBLISHED:-} " in *" $nt "*) echo '{}'; exit 0 ;; esac
echo "manifest unknown" >&2
exit 1
EOF2
cat >"$root/fakebin/sudo" <<'EOF2'
#!/bin/bash
echo "sudo $*" >>"$LOG"
[ "${FAKE_SWITCH_FAIL:-}" = 1 ] && exit 1
exit 0
EOF2
cat >"$root/fakebin/bootc" <<'EOF2'
#!/bin/bash
echo "bootc $*" >>"$LOG"
EOF2
cat >"$root/fakebin/rpm-ostree" <<'EOF2'
#!/bin/bash
echo "rpm-ostree $*" >>"$LOG"
cat "$FAKE_RPMOSTREE_JSON"
EOF2
chmod +x "$root/fakebin/"*

mkdir -p "$root/drm-nvidia/card0/device" "$root/drm-amd/card0/device"
echo 0x10de >"$root/drm-nvidia/card0/device/vendor"
echo 0x1002 >"$root/drm-amd/card0/device/vendor"
export OCTARINE_SYSFS_DRM="$root/drm-nvidia"

pub_all="octarine-os:latest octarine-os:testing octarine-os-dx:latest octarine-os-dx:testing octarine-os-nvidia:latest"

run() { # current ref, args...
    local cur=$1
    shift
    : >"$LOG"
    PATH="$root/fakebin:$PATH" OCTARINE_SWITCH_CURRENT_REF="$cur" OCTARINE_SWITCH_STAGED_REF="${STAGED-}" FAKE_PUBLISHED="${FAKE_PUBLISHED:-$pub_all}" \
        just --justfile "$justfile" switch-image "$@" >"$root/out" 2>&1 </dev/null
    rc=$?
}
rc=0
base="ostree-image-signed:docker://ghcr.io/redcodeworks/octarine-os:latest"
dx="ostree-image-signed:docker://ghcr.io/redcodeworks/octarine-os-dx:latest"

# ---- a pending kernel-argument change (rpm-ostree kargs applied, not rebooted) would be replaced by the switch: warn, ask (default no), --yes goes on
mkdir -p "$root/kbin"
cat >"$root/kbin/rpm-ostree" <<'EOF2'
#!/bin/bash
case "$1" in
    kargs) echo "root=UUID=1 rw quiet ${FAKE_NEXT_EXTRA-}" ;;
    status) echo '{"deployments":[{"booted":false},{"booted":true}]}' ;;
esac
EOF2
chmod +x "$root/kbin/rpm-ostree"
echo "root=UUID=1 rw quiet" >"$root/cmdline"
krun() { # args...
    : >"$LOG"
    PATH="$root/kbin:$root/fakebin:$PATH" OCTARINE_KARGS_LIB="$here/../system_files/usr/share/octarine-os/lib/kargs.sh" OCTARINE_CMDLINE="$root/cmdline"         OCTARINE_SWITCH_CURRENT_REF="$base" FAKE_PUBLISHED="$pub_all" just --justfile "$justfile" switch-image "$@" >"$root/out" 2>&1 </dev/null
    rc=$?
}
FAKE_NEXT_EXTRA="iommu=pt" krun dx
check "pending kernel argument, asked (default no): WARNING with the change, nothing switched, exit 0" bash -c "[ $rc = 0 ] && grep -q 'WARNING: a pending kernel-argument change would be lost by this switch' '$root/out' && grep -q '+iommu=pt' '$root/out' && grep -q 'Left as it is' '$root/out' && ! grep -q 'bootc switch' '$LOG'"
FAKE_NEXT_EXTRA="" krun dx --yes
check "nothing pending: no warning, the switch runs" bash -c "[ $rc = 0 ] && ! grep -q 'WARNING' '$root/out' && grep -q 'sudo bootc switch' '$LOG'"

# ---- staged but not booted: a second run must not call bootc again
STAGED="ostree-image-signed:docker://ghcr.io/redcodeworks/octarine-os-dx:latest"
run "$base" dx --yes
check "the target is already staged (not booted): nothing runs, says reboot to use it, exit 0" bash -c "[ $rc = 0 ] && grep -q 'already staged: reboot' '$root/out' && ! grep -q 'bootc' '$root/log' && ! grep -q '^sudo' '$root/log'"

STAGED=""
run "$base" dx --yes
check "--yes runs sudo bootc switch with the enforced signature policy" logged "sudo bootc switch --enforce-container-sigpolicy ghcr.io/redcodeworks/octarine-os-dx:latest"
run "$base" nvidia testing --yes
check "an unpublished channel is refused (exit 1)" bash -c "[ $rc = 1 ] && grep -q 'is not published' '$root/out'"
check "an unpublished channel runs nothing" notlogged "bootc"
FAKE_SKOPEO_DOWN=1 run "$base" dx --yes
check "an unreachable registry is reported, not treated as unpublished" bash -c "[ $rc = 1 ] && grep -q 'Could not reach the registry' '$root/out'"
check "an unreachable registry runs nothing" notlogged "bootc"

# ---- gx (the gamer image): known by name, not published yet
run "$base" gx --yes
check "gx is refused as not published (exit 1), nothing runs, the target is the gx repository" bash -c "[ $rc = 1 ] && grep -q 'octarine-os-gx:latest is not published' '$root/out'"
check "gx not published: bootc is not called" notlogged "bootc"
FAKE_PUBLISHED="$pub_all octarine-os-gx:latest" run "$base" gx --yes
check "gx published: the switch runs with the enforced signature policy" logged "sudo bootc switch --enforce-container-sigpolicy ghcr.io/redcodeworks/octarine-os-gx:latest"
run "$base" --list
check "--list has a gx row that says not published" bash -c "grep -E '^gx +not published +not published' '$root/out'"

# ---- dx-gx (experimental): `fx` is only an alias for the same repository
FAKE_PUBLISHED="$pub_all octarine-os-dx-gx:latest" run "$base" fx --yes
check "fx switches to octarine-os-dx-gx (alias, same repository)" logged "sudo bootc switch --enforce-container-sigpolicy ghcr.io/redcodeworks/octarine-os-dx-gx:latest"
run "$base" dx-gx --yes
check "dx-gx not published: refused, bootc is not called" bash -c "[ $rc = 1 ] && grep -q 'octarine-os-dx-gx:latest is not published' '$root/out'"

# ---- nvidia images on a machine without an NVIDIA GPU
pubnv="$pub_all octarine-os-nvidia-dx:latest"
OCTARINE_SYSFS_DRM="$root/drm-amd" FAKE_PUBLISHED="$pubnv" run "$base" nvidia --yes
check "no NVIDIA GPU: --yes alone does not bypass (exit 1, says --force)" bash -c "[ $rc = 1 ] && grep -q 'no NVIDIA GPU' '$root/out' && grep -q -- '--force' '$root/out'"
check "no NVIDIA GPU: nothing switched with --yes alone" notlogged "bootc switch"
OCTARINE_SYSFS_DRM="$root/drm-amd" FAKE_PUBLISHED="$pubnv" run "$base" nvidia --yes --force
check "no NVIDIA GPU: --force proceeds" logged "bootc switch --enforce-container-sigpolicy ghcr.io/redcodeworks/octarine-os-nvidia:latest"

echo
echo "$pass passed, $failn failed"
[ "$failn" = 0 ]
