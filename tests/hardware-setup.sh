#!/usr/bin/env bash
# Tests for `ujust hardware-setup` (60-custom.just). Nothing real changes: ujust, sudo, flatpak, systemctl, rpm-ostree,
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
cat >"$bin/distrobox" <<'F'
#!/bin/bash
[ "$1" = list ] || echo "distrobox $*" >>"$LOG"
if [ "$1" = list ]; then echo "ID | NAME | STATUS | IMAGE"; for b in ${FAKE_BOXES:-}; do echo "abc | $b | Up 1 hour | img"; done; exit 0; fi
if [ "$1" = enter ]; then
    box=""; while [ "$1" != -- ] && [ $# -gt 0 ]; do [ "$1" = --name ] && box=$2; shift; done; shift
    [ -z "$box" ] && box=$1 && shift && shift
    cmd="$*"
    case "$cmd" in
        "bash -lc command -v rocminfo") [ "${FAKE_ROCM_TOOLS:-}" = 1 ] && echo /usr/bin/rocminfo; exit 0 ;;
        "bash -lc command -v hipcc") [ "${FAKE_ROCM_TOOLS:-}" = 1 ] && echo /usr/bin/hipcc; exit 0 ;;
        "bash -lc command -v rocm-smi") [ "${FAKE_ROCM_TOOLS:-}" = 1 ] && [ "${FAKE_NO_SMI:-}" != 1 ] && echo /usr/bin/rocm-smi; exit 0 ;;
        "bash -lc command -v nvcc") echo /usr/local/cuda-13.3/bin/nvcc; exit 0 ;;
        "distrobox-export --bin "*)
            set -- $cmd; path=$3; dir=$5; act=${6:-}
            [ "${FAKE_EXPORT_FAIL:-}" = 1 ] && exit 1
            if [ "$act" = --unexport ]; then rm -f "$dir/$(basename "$path")"; else mkdir -p "$dir"; printf '#!/bin/sh\n# distrobox_binary\n# name: %s\n' "$box" >"$dir/$(basename "$path")"; fi
            exit 0 ;;
    esac
fi
exit 0
F
chmod +x "$bin/distrobox"
export HW_EXPORT_DIR="$root/exportbin" HW_KFD="$root/m/kfd" OCTARINE_BOX_EXPORT_LIB="$here/system_files/usr/share/octarine-os/lib/box-export.sh"
export OCTARINE_MENU_LIB="$here/system_files/usr/share/octarine-os/lib/menu.sh"
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

run --help
check "--help lists the steps, the flags and that the standalone recipes stay" bash -c "[ $rc = 0 ] && grep -q 'amd-kargs' '$root/out' && grep -q -- '--only' '$root/out' && grep -q 'standalone recipes stay' '$root/out'"
run --bogus
check "an unknown option is rejected (exit 2)" bash -c "[ $rc = 2 ]"
run --only nope
check "an unknown step is rejected (exit 2)" bash -c "[ $rc = 2 ]"

# wake-on-lan: stubs that only answer when FAKE_WOL_NIC is set (FAKE_ETHTOOL: g, none, or denied = the unprivileged "netlink error";
# WOL_NET_DIR is a temp dir, FAKE_SYSFS_WAKEUP=1 creates the sysfs wakeup file of enp8s0)
mk ip '[ "${FAKE_WOL_NIC:-}" = 1 ] && echo "default via 192.168.1.1 dev enp8s0 proto dhcp"; exit 0'
mk ethtool '[ "${FAKE_WOL_NIC:-}" = 1 ] || exit 1; case "${FAKE_ETHTOOL:-g}" in g) echo "Supports Wake-on: pumbg" ;; none) echo "Supports Wake-on: d" ;; denied) echo "Settings for enp8s0:"; echo "	Speed: 1000Mb/s"; echo "netlink error: Operation not permitted" >&2; exit 0 ;; esac'
mk nmcli 'case "$*" in *GENERAL.CONNECTION*) echo "br0-enp8s0" ;; *802-3-ethernet.wake-on-lan*) echo "${FAKE_WOL:-ignore}" ;; esac; exit 0'
export WOL_NET_DIR="$root/m/net"; mkdir -p "$root/m/net"
run --list
check "--list shows every step" bash -c "[ \$(grep -cE '^[a-z-]+ ' '$root/out') -ge 10 ]"
check "sensors available on bare metal" bash -c "[ \"$(state sensors; true)\" = '' ] || grep -E '^sensors +available' '$root/out'"
check "amd-gpu available with an AMD GPU and amdgpu loaded" bash -c "grep -E '^amd-gpu +available' '$root/out'"
check "amd-cpu-gaming available with amd-pstate active" bash -c "grep -E '^amd-cpu-gaming +available' '$root/out'"
check "nvidia not applicable: no NVIDIA GPU" bash -c "grep -E '^nvidia +not applicable \(no NVIDIA GPU\)' '$root/out'"
check "cuda not applicable without the driver" bash -c "grep -E '^cuda +not applicable' '$root/out'"
check "iommu not applicable without dx" bash -c "grep -E '^iommu +not applicable \(needs the dx image' '$root/out'"
check "the virtualization step is gone (virthost-setup owns libvirt)" bash -c "! grep -q '^virtualization' '$root/out'"
check "wake-on-lan hidden without a NIC that reports magic-packet wake" bash -c "grep -E '^wake-on-lan +not applicable \(no wired NIC' '$root/out'"
check "secure-boot available (enabled, key present)" bash -c "grep -E '^secure-boot +available' '$root/out'"
check "tpm-luks available (TPM and a LUKS volume)" bash -c "grep -E '^tpm-luks +available' '$root/out'"
check "fido-key available with a Yubico device" bash -c "grep -E '^fido-key +available' '$root/out'"

FAKE_VM=1 run --list
check "sensors hidden in a virtual machine" bash -c "grep -E '^sensors +not applicable \(this is a virtual machine\)' '$root/out'"
FAKE_FSTYPES="ext4" run --list
check "tpm-luks hidden without a LUKS volume" bash -c "grep -E '^tpm-luks +not applicable \(no LUKS volume\)' '$root/out'"
OCTARINE_TPM_DEVICE="$root/m/none" run --list
check "tpm-luks hidden without a TPM" bash -c "grep -E '^tpm-luks +not applicable \(no TPM 2.0 device\)' '$root/out'"
FAKE_SB=disabled run --list
check "secure-boot hidden when Secure Boot is off" bash -c "grep -E '^secure-boot +not applicable \(Secure Boot is not enabled\)' '$root/out'"
HW_EFI="$root/m/none" run --list
check "secure-boot hidden without UEFI" bash -c "grep -E '^secure-boot +not applicable \(not booted with UEFI\)' '$root/out'"
FAKE_USB="" run --list
check "fido-key hidden without a token" bash -c "grep -E '^fido-key +not applicable \(no security key found\)' '$root/out'"
GAMING_SETUP_PSTATE_STATUS="$root/m/none" run --list
check "amd-cpu-gaming hidden without amd-pstate active" bash -c "grep -E '^amd-cpu-gaming +not applicable' '$root/out'"
OCTARINE_SYSFS_DRM="$root/m/none" run --list
check "amd-gpu and amd-kargs hidden without an AMD GPU" bash -c "grep -E '^amd-gpu +not applicable \(no AMD GPU\)' '$root/out' && grep -E '^amd-kargs +not applicable' '$root/out'"
rm -rf "$root/m/dx"; mkdir -p "$root/m/dx"; : >"$root/m/dx/kvm"; : >"$root/m/dx/dev.just"; mkdir -p "$root/m/nvmod"
echo 'IMAGE_ID="octarine-os-dx"' >"$root/os-release-dx"
mkdir -p "$root/m/dx/iommu"; : >"$root/m/dx/iommu/dmar0"; mkdir -p "$root/m/dx/noiommu"
OCTARINE_OS_RELEASE="$root/os-release-dx" HW_IOMMU_DIR="$root/m/dx/iommu" run --list
check "iommu available on dx with an IOMMU" bash -c "grep -E '^iommu +available' '$root/out'"
OCTARINE_OS_RELEASE="$root/os-release-dx" HW_IOMMU_DIR="$root/m/dx/noiommu" run --list
check "iommu hidden on dx without an IOMMU" bash -c "grep -E '^iommu +not applicable \(no IOMMU found' '$root/out'"
OCTARINE_OS_RELEASE="$root/os-release-dx" HW_IOMMU_DIR="$root/m/dx/iommu" HW_CMDLINE="$root/m/cmdline-pt" run --list
echo "quiet iommu=pt" >"$root/m/cmdline-pt"
OCTARINE_OS_RELEASE="$root/os-release-dx" HW_IOMMU_DIR="$root/m/dx/iommu" HW_CMDLINE="$root/m/cmdline-pt" run --list
check "iommu done when iommu=pt is in the command line" bash -c "grep -E '^iommu +done' '$root/out'"
FAKE_WOL_NIC=1 run --list
check "wake-on-lan available when the NIC supports magic packets and the setting is not yet magic" bash -c "grep -E '^wake-on-lan +available' '$root/out'"
FAKE_WOL_NIC=1 FAKE_WOL=magic run --list
check "wake-on-lan done when the profile of the physical NIC already says magic" bash -c "grep -E '^wake-on-lan +done' '$root/out'"
FAKE_WOL_NIC=1 FAKE_ETHTOOL=none run --list
check "wake-on-lan hidden when ethtool shows no g" bash -c "grep -E '^wake-on-lan +not applicable' '$root/out'"
# the nox case: ethtool as a normal user answers "netlink error: Operation not permitted" (no Wake-on line): that is NOT "unsupported"
mkdir -p "$root/m/net/enp8s0/device/power"; : >"$root/m/net/enp8s0/device/power/wakeup"
FAKE_WOL_NIC=1 FAKE_ETHTOOL=denied run --list
check "ethtool denied, sysfs wakeup file present: available, says the support is not readable without root and names the sudo command" bash -c "grep -E '^wake-on-lan +available \\(support not readable without root: sudo ethtool enp8s0 shows it' '$root/out' && ! grep -q 'sudo' '$LOG'"
FAKE_WOL_NIC=1 FAKE_ETHTOOL=denied FAKE_WOL=magic run --list
check "ethtool denied, port profile already magic: done" bash -c "grep -E '^wake-on-lan +done' '$root/out'"
rm -rf "$root/m/net/enp8s0"
FAKE_WOL_NIC=1 FAKE_ETHTOOL=denied FAKE_WOL=ignore run --list
check "ethtool denied, no sysfs file and the profile not magic: not applicable (no sign of support)" bash -c "grep -E '^wake-on-lan +not applicable' '$root/out'"
FAKE_WOL_NIC=1 FAKE_ETHTOOL=denied FAKE_WOL=magic run --list
check "ethtool denied, no sysfs file but the profile says magic: done" bash -c "grep -E '^wake-on-lan +done' '$root/out'"
card card1 0x10de
HW_NVIDIA_MODULE="$root/m/nvmod" HW_DEV_JUST="$root/m/dx/dev.just" run --list
check "nvidia available with an NVIDIA GPU and done with the module loaded" bash -c "grep -E '^nvidia +done' '$root/out'"
check "cuda available once the driver is loaded and the dx recipe file exists" bash -c "grep -E '^cuda +available' '$root/out'"
FAKE_BOXES="cuda" HW_NVIDIA_MODULE="$root/m/nvmod" HW_DEV_JUST="$root/m/dx/dev.just" run --list
check "cuda is done when the distrobox cuda exists" bash -c "grep -E '^cuda +done' '$root/out'"
rm -rf "$root/m/drm/card1"

# --only on a hidden step
run --only nvidia
check "--only on a hidden step: 'not applicable: nvidia', exit 0, nothing run" bash -c "[ $rc = 0 ] && grep -q 'not applicable: nvidia (no NVIDIA GPU)' '$root/out' && [ ! -s '$LOG' ]"

# --no
run --no
check "--no prints a plan, runs nothing" bash -c "[ $rc = 0 ] && grep -q 'Plan: would run' '$root/out' && [ ! -s '$LOG' ]"
check "--no shows the undo lines" has "Undo:"

# --yes: defaults only, never amd-kargs, never done steps
run --yes
check "--yes runs sensors-setup with --yes" logged "ujust sensors-setup --yes"
check "--yes installs LACT (system scope, Flathub)" logged "flatpak install -y --system flathub io.github.ilya_zlobintsev.LACT"
check "--yes runs the LACT daemon setup unattended" logged "flatpak run --env=LACT_UNATTENDED_SETUP=true io.github.ilya_zlobintsev.LACT"
check "--yes runs gaming-setup gamemode" logged "ujust gaming-setup gamemode --yes"
check "--yes runs the TPM recipe and the security-key step" bash -c "grep -q 'ujust luks-tpm-unlock' '$LOG' && grep -q pamu2fcfg '$LOG'"
check "--yes never touches the optional kernel argument" notlogged "rpm-ostree kargs --append"
check "--yes does not enroll the Secure Boot key (only ticked on NVIDIA images)" notlogged "enroll-secure-boot-key"
check "the security key file was written, mode 600" bash -c "grep -q KEYDATA '$root/m/u2f_keys' && [ \$(stat -c %a '$root/m/u2f_keys') = 600 ]"
check "the summary lists steps and undo lines" bash -c "grep -q '== Summary' '$root/out' && grep -q 'To undo' '$root/out'"

# idempotence
run --yes
check "second run: fido-key and sensors... fido is already done and not asked again" bash -c "! grep -q pamu2fcfg '$LOG'"
echo x >"$root/m/modload/octarine-sensors.conf"
run --only sensors
check "--only on a done step says already done and runs nothing" bash -c "grep -q 'Already done' '$root/out' && ! grep -q 'ujust sensors-setup' '$LOG'"

# the optional kernel argument
rm -f "$root/m/u2f_keys" "$root/m/modload/octarine-sensors.conf"
run --only amd-kargs --yes
check "amd-kargs appends the argument with the overdrive bit set (0xfff7bfff | 0x4000 = 0xffffffff)" logged "sudo rpm-ostree kargs --append-if-missing=amdgpu.ppfeaturemask=0xffffffff"
check "amd-kargs prints the undo and says reboot" bash -c "grep -q 'delete-if-present' '$root/out' && grep -q 'Reboot' '$root/out'"
echo "quiet amdgpu.ppfeaturemask=0xffffffff" >"$root/m/cmdline"
run --only amd-kargs --yes
check "amd-kargs is done when the running command line has it" bash -c "grep -q 'Already done' '$root/out' && ! grep -q 'kargs --append' '$LOG'"
echo quiet >"$root/m/cmdline"
FAKE_SUDO_FAIL=1 run --only amd-kargs --yes
check "a failing sudo: no retry, FAILED, exit 1, re-run hint" bash -c "[ $rc = 1 ] && grep -q FAILED '$root/out' && [ \$(grep -c 'sudo rpm-ostree' '$LOG') = 1 ] && grep -q 'ujust hardware-setup --only amd-kargs' '$root/out'"

# failures stay soft
FAKE_FLATPAK_FAIL=1 run --only amd-gpu --yes
check "LACT install failure is retried once, then FAILED with exit 1" bash -c "[ $rc = 1 ] && [ \$(grep -c 'flatpak install' '$LOG') = 2 ] && grep -q FAILED '$root/out'"
FAKE_UJUST_FAIL=sensors-setup run --yes
check "one failing step does not stop the others (exit 1, later steps ran)" bash -c "[ $rc = 1 ] && grep -q 'ujust luks-tpm-unlock' '$LOG' && grep -q FAILED '$root/out'"
rm -f "$root/m/u2f_keys"
FAKE_PAM_FAIL=1 run --only fido-key --yes
check "a failed key registration writes nothing" bash -c "[ $rc = 1 ] && [ ! -e '$root/m/u2f_keys' ]"
echo "existing" >"$root/m/u2f_keys"
run --only fido-key --yes
check "an existing key file is never overwritten" bash -c "grep -q 'Already done' '$root/out' && [ \"\$(cat '$root/m/u2f_keys')\" = existing ] && ! grep -q pamu2fcfg '$LOG'"
rm -f "$root/m/u2f_keys"

# NVIDIA image pre-ticks secure-boot; the nvidia step picks nvidia-dx on dx
echo 'IMAGE_ID="octarine-os-nvidia"' >"$root/os-release-nv"
card card1 0x10de
OCTARINE_OS_RELEASE="$root/os-release-nv" run --yes
check "NVIDIA image: --yes enrolls the Secure Boot key when it is not enrolled" logged "ujust enroll-secure-boot-key"
FAKE_KEY="is already enrolled" OCTARINE_OS_RELEASE="$root/os-release-nv" run --yes
check "NVIDIA image: an enrolled key is not enrolled again" notlogged "enroll-secure-boot-key"
run --only nvidia --yes
check "default image: nvidia step runs switch-image nvidia" logged "ujust switch-image nvidia --yes"
OCTARINE_OS_RELEASE="$root/os-release-dx" run --only nvidia --yes
check "dx image: nvidia step runs switch-image nvidia-dx" logged "ujust switch-image nvidia-dx --yes"
HW_NVIDIA_MODULE="$root/m/nvmod" HW_DEV_JUST="$root/m/dx/dev.just" run --only cuda --yes
check "cuda step runs ujust dev --only cuda" logged "ujust dev --only cuda --yes"
OCTARINE_OS_RELEASE="$root/os-release-dx" HW_IOMMU_DIR="$root/m/dx/iommu" run --only iommu --yes
check "iommu step only delegates: ujust virthost-setup --only iommu" logged "ujust virthost-setup --only iommu --yes"
FAKE_WOL_NIC=1 run --only wake-on-lan --yes
check "wake-on-lan step only delegates: ujust wake-on-lan" logged "ujust wake-on-lan --yes"
rm -rf "$root/m/drm/card1"

# ---- rocm and the opt-in export
check "rocm: the ini installs the five Fedora packages from the toolbox image, no extra repository" bash -c "grep -q 'additional_packages=\"rocminfo rocm-smi rocm-hip rocm-opencl hipcc\"' '$here/system_files/usr/share/ublue-os/distrobox/rocm.ini' && grep -q '^image=registry.fedoraproject.org/fedora-toolbox:45' '$here/system_files/usr/share/ublue-os/distrobox/rocm.ini' && ! grep -qi 'copr\|repo=' '$here/system_files/usr/share/ublue-os/distrobox/rocm.ini'"
rm -rf "$root/exportbin"
run --list
check "rocm available with an AMD GPU, /dev/kfd and distrobox" bash -c "grep -E '^rocm +available' '$root/out'"
check "rocm-export hidden while the box does not exist" bash -c "grep -E '^rocm-export +not applicable \(the rocm box does not exist yet\)' '$root/out'"
HW_KFD="$root/m/nokfd" run --list
check "rocm hidden without /dev/kfd" bash -c "grep -E '^rocm +not applicable \(no /dev/kfd' '$root/out'"
OCTARINE_SYSFS_DRM="$root/m/none" run --list
check "rocm hidden without an AMD GPU" bash -c "grep -E '^rocm +not applicable \(no AMD GPU\)' '$root/out'"
run --only rocm --yes
check "rocm creates the box through ujust toolbox rocm and prints checks and undo" bash -c "grep -q 'ujust toolbox rocm' '$LOG' && grep -q 'distrobox enter rocm -- rocminfo' '$root/out' && grep -q 'distrobox rm --force rocm' '$root/out'"
check "rocm exports nothing by default" bash -c "[ ! -d '$root/exportbin' ] && ! grep -q 'distrobox-export' '$LOG'"
check "rocm says the GPU support is unverified" bash -c "grep -q 'not verified' '$root/out'"
FAKE_BOXES=rocm FAKE_ROCM_TOOLS=1 run --only rocm --yes
check "rocm is done when the box has rocminfo" bash -c "grep -q 'Already done' '$root/out' && ! grep -q 'ujust toolbox rocm' '$LOG'"
FAKE_BOXES=rocm FAKE_ROCM_TOOLS=1 run --list
check "--list with an existing rocm box: never enters or starts it, says so" bash -c "[ $rc = 0 ] && grep -E '^rocm +available \(the rocm box exists; not checked in plan mode' '$root/out' && ! grep -qE 'distrobox enter|podman start|distrobox start' '$LOG'"
FAKE_BOXES=rocm FAKE_ROCM_TOOLS=1 run --no --only rocm
check "--no with an existing rocm box: pure (no distrobox enter, no podman start), the plan notes it was not checked" bash -c "[ $rc = 0 ] && grep -q 'not checked in plan mode' '$root/out' && grep -qE '^rocm +planned' '$root/out' && ! grep -qE 'distrobox enter|podman start|distrobox start' '$LOG'"
FAKE_BOXES=rocm FAKE_ROCM_TOOLS=1 run --no
check "--no (all steps) with an existing rocm box: no distrobox enter or podman start" bash -c "[ $rc = 0 ] && ! grep -qE 'distrobox enter|podman start|distrobox start' '$LOG'"
FAKE_BOXES=rocm FAKE_ROCM_TOOLS=1 run --only rocm --yes --export
check "rocm --export exports exactly hipcc, rocminfo and rocm-smi, real paths from the box" bash -c "[ \"\$(ls '$root/exportbin' | LC_ALL=C sort | tr '\n' ' ')\" = 'hipcc rocm-smi rocminfo ' ] && grep -q 'distrobox-export --bin /usr/bin/hipcc --export-path $root/exportbin' '$LOG'"
FAKE_BOXES=rocm FAKE_ROCM_TOOLS=1 run --only rocm-export --yes
check "already exported wrappers are recognized, nothing re-exported" bash -c "grep -q 'Already done' '$root/out' && ! grep -q 'distrobox-export' '$LOG'"
FAKE_BOXES=rocm FAKE_ROCM_TOOLS=1 run --only rocm-export --yes --unexport
check "--unexport removes only the wrappers of the rocm box" bash -c "[ -z \"\$(ls '$root/exportbin')\" ] && grep -q 'unexported' '$root/out'"
mkdir -p "$root/exportbin"; echo "mine" >"$root/exportbin/hipcc"
FAKE_BOXES=rocm FAKE_ROCM_TOOLS=1 run --only rocm-export --yes --export
check "a foreign hipcc in ~/.local/bin is shown and skipped; the others are still exported" bash -c "grep -q 'not ours' '$root/out' && [ \"\$(cat '$root/exportbin/hipcc')\" = mine ] && [ -f '$root/exportbin/rocminfo' ] && [ -f '$root/exportbin/rocm-smi' ]"
FAKE_BOXES=rocm FAKE_ROCM_TOOLS=1 run --only rocm-export --yes --unexport
check "--unexport leaves the foreign file alone" bash -c "[ \"\$(cat '$root/exportbin/hipcc')\" = mine ] && [ ! -e '$root/exportbin/rocminfo' ]"
rm -rf "$root/exportbin"
FAKE_BOXES=rocm FAKE_ROCM_TOOLS=1 FAKE_NO_SMI=1 run --only rocm-export --yes --export
check "a missing binary in the box is skipped with a message" bash -c "grep -q 'skipped: rocm-smi is not installed in the box rocm' '$root/out' && [ -f '$root/exportbin/hipcc' ] && [ ! -e '$root/exportbin/rocm-smi' ]"
rm -rf "$root/exportbin"
FAKE_BOXES=cuda run --only cuda-export --yes --export
check "cuda-export exports nvcc only, real versioned path resolved in the box (nvidia-smi never)" bash -c "[ -f '$root/exportbin/nvcc' ] && [ \$(ls '$root/exportbin' | wc -l) = 1 ] && grep -q 'distrobox-export --bin /usr/local/cuda-13.3/bin/nvcc' '$LOG'"
rm -rf "$root/exportbin"
FAKE_EXPORT_FAIL=1 FAKE_BOXES=rocm FAKE_ROCM_TOOLS=1 run --only rocm-export --yes
check "a failing export is FAILED with exit 1" bash -c "[ $rc = 1 ] && grep -q FAILED '$root/out'"
rm -rf "$root/exportbin"
FAKE_BOXES=rocm FAKE_ROCM_TOOLS=1 run --no --only rocm-export
check "--no shows the plan for the export step and changes nothing" bash -c "[ ! -d '$root/exportbin' ] && grep -q 'Plan' '$root/out'"
check "the rocm step is not ticked by default (--yes alone installs nothing in a box)" bash -c "$(declare -f run) ; : >'$LOG'; PATH='$bin':\$PATH just --justfile '$justfile' hardware-setup --yes </dev/null >/dev/null 2>&1; ! grep -q 'toolbox rocm' '$LOG'"

# no terminal and no flags: one question per step, empty answers take the defaults
run
check "without a terminal: per-step questions, nothing ticked-by-default is asked twice, exit 0" bash -c "[ $rc = 0 ]"
check "the optional step defaults to No (nothing appended)" notlogged "kargs --append"

# menu: Esc exits 0
mk gum 'exit 0'
OCTARINE_MENU_FORCE_TTY=1 run
check "terminal menu with nothing chosen: exit 0 and nothing changed" bash -c "[ $rc = 0 ] && [ ! -s '$LOG' ]"
rm -f "$bin/gum"

# nothing applies
OCTARINE_SYSFS_DRM="$root/m/none" GAMING_SETUP_PSTATE_STATUS="$root/m/none" OCTARINE_TPM_DEVICE="$root/m/none" HW_EFI="$root/m/none" FAKE_VM=1 FAKE_USB="" run
check "nothing applies: a clear message, exit 0" bash -c "[ $rc = 0 ] && grep -q 'No hardware-specific step applies' '$root/out'"

echo
echo "passed: $pass, failed: $failn"
[ "$failn" = 0 ]
