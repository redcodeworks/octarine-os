#!/usr/bin/env bash
# Tests for `ujust switch-image` (system_files/usr/share/ublue-os/just/60-custom.just) and the 40-nvidia.just replacement.
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

pub_all="octarine-os:latest octarine-os:beta octarine-os:testing octarine-os-dx:latest octarine-os-dx:beta octarine-os-dx:testing octarine-os-nvidia:latest"

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
FAKE_NEXT_EXTRA="iommu=pt" krun dx --yes
check "pending kernel argument with --yes: the WARNING is printed and the switch goes on" bash -c "[ $rc = 0 ] && grep -q 'WARNING' '$root/out' && grep -q -- '--yes: going on anyway' '$root/out' && grep -q 'sudo bootc switch' '$LOG'"
FAKE_NEXT_EXTRA="iommu=pt" krun dx --no
check "pending kernel argument with --no: the WARNING and the plan, nothing run" bash -c "[ $rc = 0 ] && grep -q 'WARNING' '$root/out' && grep -q 'Would run' '$root/out' && ! grep -q 'bootc switch' '$LOG'"
FAKE_NEXT_EXTRA="" krun dx --yes
check "nothing pending: no warning, the switch runs" bash -c "[ $rc = 0 ] && ! grep -q 'WARNING' '$root/out' && grep -q 'sudo bootc switch' '$LOG'"

# ---- staged but not booted: a second run must not call bootc again
STAGED="ostree-image-signed:docker://ghcr.io/redcodeworks/octarine-os-dx:latest"
run "$base" dx --yes
check "the target is already staged (not booted): nothing runs, says reboot to use it, exit 0" bash -c "[ $rc = 0 ] && grep -q 'already staged: reboot' '$root/out' && ! grep -q 'bootc' '$root/log' && ! grep -q '^sudo' '$root/log'"
run "$base" dx --no
check "staged target with --no: same message, no command" bash -c "[ $rc = 0 ] && grep -q 'already staged' '$root/out' && ! grep -q 'Would run' '$root/out'"
STAGED="ostree-image-signed:docker://ghcr.io/redcodeworks/octarine-os-dx:latest@sha256:0123456789abcdef"
run "$base" dx --yes
check "a staged digest suffix is ignored when comparing" bash -c "grep -q 'already staged' '$root/out' && ! grep -q 'bootc' '$root/log'"
STAGED="ostree-image-signed:docker://ghcr.io/redcodeworks/octarine-os-nvidia:latest"
run "$base" dx --yes
check "a DIFFERENT staged image is named and replaced by the new switch" bash -c "[ $rc = 0 ] && grep -q 'octarine-os-nvidia:latest is staged' '$root/out' && grep -q 'bootc switch --enforce-container-sigpolicy ghcr.io/redcodeworks/octarine-os-dx:latest' '$root/log'"
STAGED=""
printf '%s' '{"deployments":[{"booted":false,"staged":true,"container-image-reference":"ostree-image-signed:docker://ghcr.io/redcodeworks/octarine-os-dx:latest"},{"booted":true,"staged":false,"container-image-reference":"ostree-image-signed:docker://ghcr.io/redcodeworks/octarine-os:latest"}]}' >"$root/rpmostree.json"
unset STAGED
: >"$LOG"
PATH="$root/fakebin:$PATH" FAKE_RPMOSTREE_JSON="$root/rpmostree.json" OCTARINE_SWITCH_CURRENT_REF="$base" FAKE_PUBLISHED="$pub_all" just --justfile "$justfile" switch-image dx --yes >"$root/out" 2>&1 </dev/null; rc=$?
check "the staged deployment is read from rpm-ostree status --json when no override is set: no bootc call" bash -c "[ $rc = 0 ] && grep -q 'already staged' '$root/out' && ! grep -q 'bootc' '$root/log'"
STAGED=""

run "$base" --help
check "--help explains images, channels and the rollback" bash -c "[ $rc = 0 ]" 
check "--help names the four images and three channels" bash -c "grep -q 'nvidia-dx' '$root/out' && grep -q 'beta' '$root/out' && grep -q 'testing' '$root/out'"

run "$base"
check "no image and no terminal: exit 2 and a hint" bash -c "[ $rc = 2 ]"
check "the hint lists the images" has "default, dx, nvidia or nvidia-dx"
run "$base" bogus
check "an unknown word is rejected (exit 2)" bash -c "[ $rc = 2 ]"
run "$base" --nope
check "an unknown option is rejected (exit 2)" bash -c "[ $rc = 2 ]"

run "$base" --list
check "--list exits 0 and shows the running image" bash -c "[ $rc = 0 ]"
check "--list marks the current image and channel" has "published (current)"
check "--list shows an unpublished image as not published" bash -c "grep -E '^nvidia-dx +not published' '$root/out'"
check "--list shows beta of nvidia as not published" bash -c "grep -E '^nvidia +published +not published' '$root/out'"
notlogged "bootc"; check "--list never switches" notlogged "sudo"

run "$base" dx --no
check "default -> dx keeps the latest channel" has "Target:  ghcr.io/redcodeworks/octarine-os-dx:latest"
check "--no prints the enforced bootc command" has "Would run: sudo bootc switch --enforce-container-sigpolicy ghcr.io/redcodeworks/octarine-os-dx:latest"
check "--no runs nothing" notlogged "bootc"

run "$base" dx --yes
check "--yes runs sudo bootc switch with the enforced signature policy" logged "sudo bootc switch --enforce-container-sigpolicy ghcr.io/redcodeworks/octarine-os-dx:latest"
check "--yes tells the user to reboot and how to roll back" has "bootc rollback"

run "$base" dx
check "without --yes and no terminal the question is declined and nothing runs" bash -c "[ $rc = 0 ] && grep -q 'Left as it is' '$root/out'"
check "a declined switch runs nothing" notlogged "bootc"

run "$dx" beta --yes
check "an image-less switch to beta is rejected without a terminal" bash -c "[ $rc = 2 ]"
run "$dx" dx beta --yes
check "dx -> dx beta changes the channel only" logged "bootc switch --enforce-container-sigpolicy ghcr.io/redcodeworks/octarine-os-dx:beta"
run "ostree-image-signed:docker://ghcr.io/redcodeworks/octarine-os-dx:beta" default --no
check "an image-only switch keeps the current channel (beta)" has "Target:  ghcr.io/redcodeworks/octarine-os:beta"
run "ostree-image-signed:docker://ghcr.io/redcodeworks/octarine-os-dx:latest-20261109-abc1234" default --no
check "a pinned dated tag falls back to latest" has "Target:  ghcr.io/redcodeworks/octarine-os:latest"
run "ostree-image-signed:docker://ghcr.io/redcodeworks/octarine-os-dx:latest@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" nvidia --no
check "a digest suffix on the running image is ignored" has "Target:  ghcr.io/redcodeworks/octarine-os-nvidia:latest"
check "switching to nvidia mentions the Secure Boot key" has "enroll-secure-boot-key"
FAKE_PUBLISHED="$pub_all octarine-os-nvidia-dx:latest" run "$base" nvidia-dx --no
check "switching to nvidia-dx mentions the Secure Boot key and the signature-policy hint" bash -c "grep -q 'enroll-secure-boot-key' '$root/out' && grep -q 'signature-policy error' '$root/out' && grep -q 'Would run: sudo bootc switch --enforce-container-sigpolicy ghcr.io/redcodeworks/octarine-os-nvidia-dx:latest' '$root/out'"
FAKE_PUBLISHED="$pub_all octarine-os-nvidia-dx:latest" run "ostree-image-signed:docker://ghcr.io/redcodeworks/octarine-os-nvidia-dx:latest" dx --no
check "a running nvidia-dx is recognized as the current image" has "Current: ghcr.io/redcodeworks/octarine-os-nvidia-dx:latest"

run "$dx" dx latest --yes
check "already on the target: nothing to do" has "Already on dx (latest)."
check "already on the target: no switch" notlogged "bootc"

run "$base" nvidia beta --yes
check "an unpublished channel is refused (exit 1)" bash -c "[ $rc = 1 ] && grep -q 'is not published' '$root/out'"
check "an unpublished channel runs nothing" notlogged "bootc"
run "$base" nvidia-dx --yes
check "nvidia-dx is refused until it is published" bash -c "[ $rc = 1 ] && grep -q 'octarine-os-nvidia-dx:latest is not published' '$root/out'"
FAKE_PUBLISHED="$pub_all octarine-os-nvidia-dx:latest" run "$base" nvidia-dx --yes
check "nvidia-dx works once it is published" logged "ghcr.io/redcodeworks/octarine-os-nvidia-dx:latest"
FAKE_SKOPEO_DOWN=1 run "$base" dx --yes
check "an unreachable registry is reported, not treated as unpublished" bash -c "[ $rc = 1 ] && grep -q 'Could not reach the registry' '$root/out'"
check "an unreachable registry runs nothing" notlogged "bootc"
FAKE_SWITCH_FAIL=1 run "$base" dx --yes
check "a failed bootc switch exits 1 and says nothing changed" bash -c "[ $rc = 1 ] && grep -q 'nothing changed' '$root/out'"

run "ostree-image-signed:docker://example.org/someone/octarine-os-dx:latest" default --no
check "a fork's registry is kept" has "Target:  example.org/someone/octarine-os:latest"
run "ostree-image-signed:docker://ghcr.io/ublue-os/silverblue-main:45" dx --no
check "from a foreign image the target uses the project's registry" has "Target:  ghcr.io/redcodeworks/octarine-os-dx:latest"

# ---- the base image's toggle-nvk is gone (the assembled justfile is checked in tests/just-recipes.sh)
check "40-nvidia.just no longer rebases by string substitution" bash -c "! grep -q 'rpm-ostree rebase' '$justdir/40-nvidia.just'"
check "40-nvidia.just defines no recipe" bash -c "! grep -qE '^toggle-nvk' '$justdir/40-nvidia.just'"
check "switch-image is listed by the recipe scan" bash -c "just --justfile '$justfile' --summary | tr ' ' '\\n' | grep -qx switch-image"

# ---- Esc leaves everything as it is: exit 0, nothing run. A fake ugum that prints nothing is Esc; a terminal is faked.
cat >"$root/fakebin/ugum" <<'EOF2'
#!/bin/bash
exit 130
EOF2
chmod +x "$root/fakebin/ugum"
escrun() {
    : >"$LOG"
    PATH="$root/fakebin:$PATH" OCTARINE_MENU_FORCE_TTY=1 OCTARINE_MENU_LIB="$here/../system_files/usr/share/octarine-os/lib/menu.sh" OCTARINE_SWITCH_CURRENT_REF="$base" FAKE_PUBLISHED="$pub_all" \
        just --justfile "$justfile" switch-image "$@" >"$root/out" 2>&1 </dev/null
    rc=$?
}
escrun
check "Esc at the image menu exits 0" bash -c "[ $rc = 0 ] && grep -q 'nothing changed' '$root/out'"
check "Esc at the image menu runs nothing" notlogged "bootc"
escrun dx
check "Esc at the channel menu exits 0" bash -c "[ $rc = 0 ] && grep -q 'nothing changed' '$root/out'"
check "Esc at the channel menu runs nothing" notlogged "bootc"

# ---- nvidia images on a machine without an NVIDIA GPU
pubnv="$pub_all octarine-os-nvidia-dx:latest"
OCTARINE_SYSFS_DRM="$root/drm-amd" FAKE_PUBLISHED="$pubnv" run "$base" nvidia --yes
check "no NVIDIA GPU: --yes alone does not bypass (exit 1, says --force)" bash -c "[ $rc = 1 ] && grep -q 'no NVIDIA GPU' '$root/out' && grep -q -- '--force' '$root/out'"
check "no NVIDIA GPU: nothing switched with --yes alone" notlogged "bootc switch"
OCTARINE_SYSFS_DRM="$root/drm-amd" FAKE_PUBLISHED="$pubnv" run "$base" nvidia --yes --force
check "no NVIDIA GPU: --force proceeds" logged "bootc switch --enforce-container-sigpolicy ghcr.io/redcodeworks/octarine-os-nvidia:latest"
OCTARINE_SYSFS_DRM="$root/drm-amd" FAKE_PUBLISHED="$pubnv" run "$base" nvidia-dx --yes
check "no NVIDIA GPU: nvidia-dx is gated too" bash -c "[ $rc = 1 ] && grep -q 'no NVIDIA GPU' '$root/out'"
OCTARINE_SYSFS_DRM="$root/drm-amd" FAKE_PUBLISHED="$pubnv" run "$base" nvidia --no
check "no NVIDIA GPU: --no states it and changes nothing" bash -c "[ $rc = 0 ] && grep -q 'no NVIDIA GPU' '$root/out' && ! grep -q 'bootc switch' '$LOG'"
OCTARINE_SYSFS_DRM="$root/drm-amd" run "$base" nvidia
check "no NVIDIA GPU without a terminal: the confirmation defaults to No, nothing switched" bash -c "[ $rc = 0 ] && grep -q 'Left as it is' '$root/out' && ! grep -q 'bootc switch' '$LOG'"
OCTARINE_SYSFS_DRM="$root/drm-amd" run "$base" dx --yes
check "no NVIDIA GPU: dx and default are not gated" bash -c "[ $rc = 0 ] && ! grep -q 'no NVIDIA GPU' '$root/out'"
OCTARINE_SYSFS_DRM="$root/drm-amd" run "$base" --help
check "--help mentions --force" has "--force"

echo
echo "$pass passed, $failn failed"
[ "$failn" = 0 ]
