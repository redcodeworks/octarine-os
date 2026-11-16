#!/usr/bin/env bash
# Thin test for `ujust hardware-setup` (60-custom.just): only what is silent or irreversible (kernel argument, TPM enrollment, Secure Boot key, security-key file, the plan mode).
# The menu and the step list show when the recipe is run. Nothing real changes: ujust, sudo, flatpak, systemctl, rpm-ostree,
# mokutil, lsblk, lsusb, udevadm, pamu2fcfg, distrobox and systemd-detect-virt are fakes, sysfs paths are redirected by
# environment variables. Needs: bash, just. Run: tests/hardware-setup.sh
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
justfile="$here/system_files/usr/share/ublue-os/just/60-custom.just"
root=$(mktemp -d)
trap 'rm -rf -- "$root"' EXIT
pass=0
failn=0
rc=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { failn=$((failn + 1)); echo "FAIL $1"; sed 's/^/     /' "$root/out" 2>/dev/null; echo "     rc=$rc"; }
check() { local d=$1; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }
has() { grep -qF -- "$1" "$root/out"; }
hasnt() { ! grep -qF -- "$1" "$root/out"; }
logged() { grep -qF -- "$1" "$root/log" 2>/dev/null; }
notlogged() { ! grep -qF -- "$1" "$root/log" 2>/dev/null; }
export LOG="$root/log"
bin="$root/fakebin"
mkdir -p "$bin" "$root/home"
export HOME="$root/home"
unset XDG_CONFIG_HOME

mk() { # name, body
    printf '#!/bin/bash\n%s\n' "$2" >"$bin/$1"
    chmod +x "$bin/$1"
}
mk ujust 'echo "ujust $*" >>"$LOG"; [ "${FAKE_UJUST_FAIL:-}" = "$1" ] && exit 1; exit 0'
mk sudo 'echo "sudo $*" >>"$LOG"; [ "${FAKE_SUDO_FAIL:-}" = 1 ] && exit 1; exec "$@"'
mk flatpak 'echo "flatpak $*" >>"$LOG"; [ "${FAKE_FLATPAK_FAIL:-}" = 1 ] && exit 1; exit 0'
mk systemctl 'echo "${FAKE_LACTD:-disabled}"'
mk rpm-ostree 'if [ "$1" = kargs ] && [ $# = 1 ]; then echo "${FAKE_KARGS:-quiet}"; exit 0; fi; echo "rpm-ostree $*" >>"$LOG"; exit 0'
mk id 'echo "${FAKE_GROUPS:-wheel kevin}"'
mk mokutil 'case "$1" in --sb-state) echo "SecureBoot ${FAKE_SB:-enabled}" ;; --test-key) echo "${FAKE_KEY:-is not enrolled}" ;; esac'
mk lsblk 'for f in ${FAKE_FSTYPES:-}; do echo $f; done'
mk lsusb '[ -n "${FAKE_USB:-}" ] && echo "Bus 001 Device 004: ID 1050:0407 Yubico.com YubiKey"; exit 0'
mk udevadm 'exit 0'
mk pamu2fcfg 'echo "pamu2fcfg $*" >>"$LOG"; [ "${FAKE_PAM_FAIL:-}" = 1 ] && exit 1; echo "kevin:KEYDATA"'
mk systemd-detect-virt '[ "${FAKE_VM:-}" = 1 ]'
mk sensors-detect 'exit 0'
mk distrobox 'exit 0'
export HW_EXPORT_DIR="$root/exportbin" HW_KFD="$root/m/kfd" OCTARINE_BOX_EXPORT_LIB="$here/system_files/usr/share/octarine-os/lib/box-export.sh"
export OCTARINE_MENU_LIB="$here/system_files/usr/share/octarine-os/lib/menu.sh" OCTARINE_KARGS_LIB="$here/system_files/usr/share/octarine-os/lib/kargs.sh"
export OCTARINE_UJUST="$bin/ujust" HW_RETRY_WAIT=0

osrel="$root/os-release"
echo 'IMAGE_ID="octarine-os"' >"$osrel"
export OCTARINE_OS_RELEASE="$osrel"

# a machine: AMD GPU (amdgpu loaded), amd-pstate active, TPM, EFI, LUKS volume, a security key; no NVIDIA, no dx
rm -rf "$root/m"; mkdir -p "$root/m"
card() { mkdir -p "$root/m/drm/$1/device"; echo "$2" >"$root/m/drm/$1/device/vendor"; }
card card0 0x1002
mkdir -p "$root/m/amdgpu" "$root/m/efi"
echo active >"$root/m/pstate"
: >"$root/m/tpm"
: >"$root/m/kfd"
echo "quiet" >"$root/m/cmdline"
echo 4294950911 >"$root/m/ppfm"
: >"$root/m/key.der"
mkdir -p "$root/m/modload"
export OCTARINE_SYSFS_DRM="$root/m/drm" HW_AMDGPU_MODULE="$root/m/amdgpu" HW_NVIDIA_MODULE="$root/m/no-nvidia" \
    GAMING_SETUP_PSTATE_STATUS="$root/m/pstate" OCTARINE_TPM_DEVICE="$root/m/tpm" HW_EFI="$root/m/efi" HW_SB_KEY="$root/m/key.der" \
    HW_DEV_JUST="$root/m/no-dev.just" HW_KVM="$root/m/no-kvm" OCTARINE_MODULES_LOAD_DIR="$root/m/modload" \
    HW_U2F_KEYS="$root/m/u2f_keys" HW_PPFEATUREMASK="$root/m/ppfm" HW_CMDLINE="$root/m/cmdline" HW_HIDRAW_GLOB="$root/m/hidraw*" \
    XDG_CONFIG_HOME="$root/home/.config"
export FAKE_FSTYPES="crypto_LUKS" FAKE_USB=1

run() {
    : >"$LOG"
    PATH="$bin:$PATH" just --justfile "$justfile" hardware-setup "$@" >"$root/out" 2>&1 </dev/null
    rc=$?
}
state() { grep -E "^$1 " "$root/out" | sed -E "s/^$1 +//"; }

run --yes
check "smoke: --yes exits 0 with the stubs" test "$rc" = 0
check "--yes runs the TPM recipe as 'enroll --yes' (volumes without a key only): a second --yes run touches nothing enrolled" logged "ujust luks-tpm-unlock enroll --yes"
check "--yes never touches the optional kernel argument" notlogged "rpm-ostree kargs --append"
check "--yes does not enroll the Secure Boot key (only ticked on NVIDIA images)" notlogged "enroll-secure-boot-key"
check "the security key file was written, mode 600" bash -c "grep -q KEYDATA '$root/m/u2f_keys' && [ \$(stat -c %a '$root/m/u2f_keys') = 600 ]"
run --yes
check "second run: the security key is already done and not asked again" bash -c "! grep -q pamu2fcfg '$LOG'"
run --only tpm-luks --yes
check "a named tpm-luks step re-enrolls: 'enroll --force --yes'" bash -c "grep -q 'ujust luks-tpm-unlock enroll --force --yes' '$LOG'"
run --no
check "--no prints a plan and runs nothing" bash -c "[ $rc = 0 ] && grep -q 'Plan: would run' '$root/out' && [ ! -s '$LOG' ]"
rm -f "$root/m/u2f_keys"
run --only amd-kargs --yes
check "amd-kargs appends the argument with the overdrive bit set" logged "sudo rpm-ostree kargs --append-if-missing=amdgpu.ppfeaturemask=0xffffffff"
echo "quiet amdgpu.ppfeaturemask=0xffffffff" >"$root/m/cmdline"
run --only amd-kargs --yes
check "amd-kargs is not applied again when the running command line has it" bash -c "! grep -q 'kargs --append' '$LOG'"
echo quiet >"$root/m/cmdline"
FAKE_SUDO_FAIL=1 run --only amd-kargs --yes
check "a failing sudo: no retry, FAILED, exit 1" bash -c "[ $rc = 1 ] && grep -q FAILED '$root/out' && [ \$(grep -c 'sudo rpm-ostree' '$LOG') = 1 ]"
rm -f "$root/m/u2f_keys"
FAKE_PAM_FAIL=1 run --only fido-key --yes
check "a failed key registration writes nothing" bash -c "[ $rc = 1 ] && [ ! -e '$root/m/u2f_keys' ]"
echo "existing" >"$root/m/u2f_keys"
run --only fido-key --yes
check "an existing key file is never overwritten" bash -c "[ \"\$(cat '$root/m/u2f_keys')\" = existing ] && ! grep -q pamu2fcfg '$LOG'"
echo 'IMAGE_ID="octarine-os-nvidia"' >"$root/os-release-nv"
card card1 0x10de
OCTARINE_OS_RELEASE="$root/os-release-nv" run --yes
check "NVIDIA image: --yes enrolls the Secure Boot key when it is not enrolled" logged "ujust enroll-secure-boot-key"
FAKE_KEY="is already enrolled" OCTARINE_OS_RELEASE="$root/os-release-nv" run --yes
check "NVIDIA image: an enrolled key is not enrolled again" notlogged "enroll-secure-boot-key"
echo; echo "passed: $pass, failed: $failn"
[ "$failn" = 0 ]
