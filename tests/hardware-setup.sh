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
mk solaar 'exit 0'
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
check "the security key file was written, mode 600" bash -c "grep -q KEYDATA '$root/m/u2f_keys' && [ \$(stat -c %a '$root/m/u2f_keys') = 600 ]"
rm -f "$root/m/u2f_keys"
run --only amd-kargs --yes
check "amd-kargs appends the argument with the overdrive bit set" logged "sudo rpm-ostree kargs --append-if-missing=amdgpu.ppfeaturemask=0xffffffff"
echo "quiet amdgpu.ppfeaturemask=0xffffffff" >"$root/m/cmdline"
run --only amd-kargs --yes
check "amd-kargs is not applied again when the running command line has it" bash -c "! grep -q 'kargs --append' '$LOG'"
echo quiet >"$root/m/cmdline"
FAKE_SUDO_FAIL=1 run --only amd-kargs --yes
check "a failing sudo: no retry, FAILED, exit 1" bash -c "[ $rc = 1 ] && grep -q FAILED '$root/out' && [ \$(grep -c 'sudo rpm-ostree' '$LOG') = 1 ]"
echo "existing" >"$root/m/u2f_keys"
run --only fido-key --yes
check "an existing key file is never overwritten" bash -c "[ \"\$(cat '$root/m/u2f_keys')\" = existing ] && ! grep -q pamu2fcfg '$LOG'"
echo 'IMAGE_ID="octarine-os-nvidia"' >"$root/os-release-nv"
card card1 0x10de
OCTARINE_OS_RELEASE="$root/os-release-nv" run --yes
check "NVIDIA image: --yes enrolls the Secure Boot key when it is not enrolled" logged "ujust enroll-secure-boot-key"
# the Solaar toggle at login: enabled = ~/.config/autostart/solaar.desktop exists (a copy of the template), disabled = it does not; no sudo
tpl="$root/m/solaar-autostart.desktop"
printf '[Desktop Entry]\nName=Solaar\nExec=solaar --window=hide --battery-icon=regular\nType=Application\n' >"$tpl"
export HW_SOLAAR_TEMPLATE="$tpl"
sf="$root/home/.config/autostart/solaar.desktop"; rm -f "$sf"
run --yes
check "--yes never changes Solaar" bash -c "[ ! -e '$sf' ]"
run --list
check "--list shows Solaar disabled" bash -c "grep -q '^solaar .*disabled' '$root/out'"
run --only solaar
check "--only solaar (disabled) enables it: a copy of the template, no sudo, the way back is printed" bash -c "cmp -s '$tpl' '$sf' && ! grep -q '^sudo' '$LOG' && grep -q 'solaar --off\\|--solaar off' '$root/out'"
run --list
check "--list shows Solaar enabled" bash -c "grep -q '^solaar .*enabled' '$root/out'"
run --only solaar --no
check "--no plans the flip (turn off) and changes nothing" bash -c "grep -q 'would turn Solaar at login off' '$root/out' && [ -e '$sf' ]"
run --solaar on
check "--solaar on when enabled: already enabled, nothing changes" bash -c "grep -q 'already enabled' '$root/out' && [ -e '$sf' ] && [ $rc = 0 ]"
run --only solaar
check "--only solaar (enabled) disables it: the file is deleted by the step" bash -c "[ ! -e '$sf' ] && grep -q 'disabled' '$root/out'"
run --solaar off
check "--solaar off when disabled: already disabled, nothing created" bash -c "grep -q 'already disabled' '$root/out' && [ ! -e '$sf' ]"
run --solaar on
check "--solaar on alone runs only that step (no menu) and enables it" bash -c "[ -e '$sf' ] && ! grep -q '== sensors' '$root/out'"
run --solaar maybe
check "--solaar with another value is refused (exit 2)" test "$rc" = 2
rm -f "$sf"; HW_SOLAAR_CMD=solaar-not-here run --only solaar
check "solaar not installed: the step is hidden (not applicable), exit 0, nothing created" bash -c "[ $rc = 0 ] && grep -q 'not applicable: solaar' '$root/out' && [ ! -e '$sf' ]"
echo; echo "passed: $pass, failed: $failn"
[ "$failn" = 0 ]
