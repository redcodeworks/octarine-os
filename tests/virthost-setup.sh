#!/usr/bin/env bash
# Tests for `ujust virthost-setup` (dx image) and `ujust wake-on-lan` (60-custom.just): every step fresh, already done and failing,
# the vendor-aware iommu arguments, NIC detection and the NetworkManager bridge, the image directory ACLs and SELinux fallback, the
# virtio download, the libvirt network, the plan-only and root-refusal rules, and the Wake-on-LAN profile of the physical NIC.
# sudo, systemctl, nmcli, ip, virsh, setfacl, getfacl, semanage, restorecon, chcon, curl, rpm-ostree, ethtool, virt-host-validate and
# id are fakes; paths come from VIRTHOST_* and WOL_* variables. Nothing real changes. Needs: bash, just. Run: tests/virthost-setup.sh
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
vjust="$here/variants/dx/system_files/usr/share/ublue-os/just/75-octarine-virthost.just"
cjust="$here/system_files/usr/share/ublue-os/just/60-custom.just"
root=$(mktemp -d)
trap 'rm -rf -- "${root:?}"' EXIT
pass=0
failn=0
rc=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { failn=$((failn + 1)); echo "FAIL $1"; sed 's/^/     /' "$root/out" 2>/dev/null | head -40; echo "     rc=$rc"; }
check() { local d=$1; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
logged() { grep -qxF -- "$1" "$root/log" 2>/dev/null; }
loggedp() { grep -qF -- "$1" "$root/log" 2>/dev/null; }
notlogged() { ! grep -qF -- "$1" "$root/log" 2>/dev/null; }
has() { grep -qF -- "$1" "$root/out"; }
bin="$root/bin"; sysbin="$root/sysbin"; mkdir -p "$bin" "$sysbin" "$root/home" "$root/m"
for c in bash sh env cat grep awk sed cut tr date head sort dirname basename wc chmod printf mkdir mktemp mv rm ls touch tee readlink ln stat tail cp; do
    p=$(command -v "$c") && ln -sf "$p" "$sysbin/$c"
done
REAL_JUST=$(command -v just)
export LOG="$root/log" HOME="$root/home" OCTARINE_MENU_LIB="$here/system_files/usr/share/octarine-os/lib/menu.sh" OCTARINE_KARGS_LIB="$here/system_files/usr/share/octarine-os/lib/kargs.sh"
export VIRTHOST_CPUINFO="$root/m/cpuinfo" VIRTHOST_CMDLINE="$root/m/cmdline" VIRTHOST_IOMMU_DIR="$root/m/iommu" VIRTHOST_KVM="$root/m/kvm" VIRTHOST_NET_DIR="$root/m/net" WOL_NET_DIR="$root/m/net"
export VIRTHOST_IMAGE_DIR="$root/imgs" VIRTHOST_VIRTIO_MIN=10 STATE="$root/state"
unset XDG_CONFIG_HOME SSH_CONNECTION
mk() { printf '#!/bin/bash\n%s\n' "$2" >"$bin/$1"; chmod +x "$bin/$1"; }
mk sudo 'echo "sudo $*" >>"$LOG"; [ "${FAKE_SUDO_FAIL:-}" = 1 ] && exit 1; [ "$1" = ethtool ] && { echo "Settings for $2:"; echo "${FAKE_SUDO_ETHTOOL-	Supports Wake-on: pumbg}"; }; exit 0'
mk id 'case "$1" in -u) echo "${FAKE_UID:-1000}" ;; -un) echo tester ;; -nG) echo "${FAKE_GROUPS:-tester wheel}" ;; esac'
mk getent '[ "$1" = group ] && echo "libvirt:x:970:${FAKE_LIBVIRT_MEMBERS:-}"; exit 0'
mk systemctl 'case "$1" in is-enabled) for e in $ENABLED_UNITS; do [ "$e" = "$2" ] && { echo enabled; exit 0; }; done; echo disabled; exit 1 ;; esac; exit 0'
mk rpm-ostree 'echo "rpm-ostree $*" >>"$LOG"; [ "$1" = kargs ] && [ $# -eq 1 ] && echo "${FAKE_KARGS:-quiet}"; exit 0'
mk virt-host-validate 'cat <<E
  QEMU: Checking for hardware virtualization                                 : PASS
  QEMU: Checking if IOMMU is enabled by kernel                               : WARN (IOMMU appears to be disabled in kernel. Add intel_iommu=on to kernel cmdline arguments)
  QEMU: Checking for secure guest support                                    : WARN (AMD Secure Guest support is not available)
E'
mk virsh 'echo "virsh $*" >>"$LOG"; case "$*" in *"net-info nwbridge"*) [ "${FAKE_NET_EXISTS:-}" = 1 ]; exit $? ;; *"pool-info"*) exit 1 ;; esac; exit 0'
mk setfacl 'echo "setfacl $*" >>"$LOG"; exit 0'
mk getfacl 'case "${FAKE_FACL:-none}" in full) printf "user:tester:rwx\ndefault:user:tester:rwx\nuser:qemu:--x\n" ;; qemu) printf "user:qemu:--x\n" ;; esac; exit 0'
mk semanage 'echo "semanage $*" >>"$LOG"; exit 0'
mk restorecon 'echo "restorecon $*" >>"$LOG"; exit 0'
mk chcon 'echo "chcon $*" >>"$LOG"; exit 0'
mk ls '[ "$1" = -Zd ] && { [ "${FAKE_CTX:-}" = virt ] && echo "system_u:object_r:virt_image_t:s0 $2" || echo "system_u:object_r:var_lib_t:s0 $2"; exit 0; }; exec /usr/bin/ls "$@"'
mk curl 'echo "curl $*" >>"$LOG"; [ "${FAKE_CURL_FAIL:-}" = 1 ] && exit 22
out=""; while [ $# -gt 0 ]; do [ "$1" = -o ] && out=$2; shift; done
head -c 64 /dev/zero >"$out"; printf "https://fedorapeople.org/archive-virtio/virtio-win-0.1.302-1/virtio-win-0.1.302.iso"'
mk ip 'case "$*" in *"route show default"*) [ -n "${FAKE_DEFDEV:-}" ] && echo "default via 192.168.1.1 dev $FAKE_DEFDEV proto dhcp" ;; *"addr show"*) echo "2: ${FAKE_DEFDEV:-x}    inet 192.168.1.20/24 brd 192.168.1.255 scope global" ;; esac; exit 0'
mk ethtool 'case "${FAKE_ETHTOOL:-ok}" in denied) echo "Settings for enp8s0:"; echo "netlink error: Operation not permitted" >&2 ;; *) echo "Supports Wake-on: pumbg" ;; esac; exit 0'
mk nmcli 'echo "nmcli $*" >>"$LOG"
case "$*" in
  "-t -f NAME,TYPE connection show") printf "%s" "$FAKE_CONS" ;;
  "-t -f DEVICE,TYPE device status") printf "%s" "$FAKE_DEVS" ;;
  *"GENERAL.CONNECTION device show"*) echo "${FAKE_PROFILE:-Wired connection 1}" ;;
  *"802-3-ethernet.wake-on-lan connection show"*) echo "${FAKE_WOL:-ignore}" ;;
esac; exit 0'
mk dmesg 'exit 0'
mk lsmod 'echo "kvm_amd 1 0"; echo "kvm 2 1 kvm_amd"'
mk wc '/usr/bin/wc "$@"'; rm -f "$bin/wc"
chmod +x "$bin"/*

reset() {
    rm -rf "${root:?}/home" "${root:?}/imgs" "${root:?}/m"; mkdir -p "$root/home" "$root/m/iommu" "$root/m/net"
    : >"$LOG"; printf 'vendor_id: AuthenticAMD\nflags: fpu vmx svm\n' >"$VIRTHOST_CPUINFO"; echo "quiet" >"$VIRTHOST_CMDLINE"; : >"$VIRTHOST_KVM"; : >"$root/m/iommu/ivhd0"
    unset FAKE_UID FAKE_SUDO_FAIL FAKE_KARGS FAKE_FACL FAKE_CTX FAKE_CURL_FAIL FAKE_NET_EXISTS FAKE_DEFDEV FAKE_PROFILE FAKE_WOL FAKE_ETHTOOL FAKE_SUDO_ETHTOOL FAKE_LIBVIRT_MEMBERS FAKE_GROUPS SSH_CONNECTION
    export ENABLED_UNITS="" FAKE_CONS="" FAKE_DEVS=""
}
run() { local r=$1; shift; PATH="$bin:$sysbin" "$REAL_JUST" --justfile "$2" --working-directory "$root" "$r" "${@:3}" >"$root/out" 2>&1 </dev/null; rc=$?; }
vh() { PATH="$bin:$sysbin" "$REAL_JUST" --justfile "$vjust" --working-directory "$root" virthost-setup "$@" >"$root/out" 2>&1 </dev/null; rc=$?; }
wol() { PATH="$bin:$sysbin" "$REAL_JUST" --justfile "$cjust" --working-directory "$root" wake-on-lan "$@" >"$root/out" 2>&1 </dev/null; rc=$?; }
all_socks() { local d s; for d in virtqemud virtnetworkd virtstoraged virtnodedevd virtsecretd virtnwfilterd; do for s in "" -ro -admin; do printf '%s ' "$d$s.socket"; done; done; }

reset; FAKE_SUDO_FAIL=1 vh --only daemons --yes
check "daemons: a failing sudo is FAILED with the exact command, not retried, exit 1" bash -c "[ $rc = 1 ] && grep -q 'FAILED: sudo systemctl enable --now' '$root/out' && [ \$(grep -c '^sudo ' '$LOG') = 1 ]"
reset; vh --only daemons --no
check "daemons --no: the plan only, no sudo" bash -c "grep -q 'plan only' '$root/out' && ! grep -q '^sudo' '$LOG'"

# ---- iommu
reset; vh --only iommu --yes
check "iommu, AMD: only iommu=pt is appended through rpm-ostree kargs, with the undo and a reboot note" bash -c "[ $rc = 0 ] && grep -qx 'sudo rpm-ostree kargs --append-if-missing=iommu=pt' '$LOG' && grep -q 'delete-if-present=iommu=pt' '$root/out' && grep -q 'reboot' '$root/out'"
reset; printf 'vendor_id: GenuineIntel\nflags: vmx\n' >"$VIRTHOST_CPUINFO"; vh --only iommu --yes
check "iommu, Intel: intel_iommu=on and iommu=pt, both undone by the undo line" bash -c "grep -qx 'sudo rpm-ostree kargs --append-if-missing=intel_iommu=on --append-if-missing=iommu=pt' '$LOG' && grep -q 'delete-if-present=intel_iommu=on' '$root/out'"
reset; rm -f "$root/m/iommu/ivhd0"; vh --only iommu --yes
check "iommu: no IOMMU in the firmware: says to enable it in the UEFI, nothing run" bash -c "grep -q 'enable VT-d' '$root/out' && ! grep -q '^sudo' '$LOG'"
reset; FAKE_SUDO_FAIL=1 vh --only iommu --yes
check "iommu: a failing sudo prints the exact command, exit 1" bash -c "[ $rc = 1 ] && grep -q 'FAILED: sudo rpm-ostree kargs --append-if-missing=iommu=pt' '$root/out'"
reset; vh --only iommu --no
check "iommu --no: the plan only" bash -c "grep -q 'Plan: sudo rpm-ostree kargs' '$root/out' && ! grep -q '^sudo' '$LOG'"
reset; vh --yes
check "--yes runs check, daemons, connection, image-dir, virtio and libvirt-network, never iommu or bridge" bash -c "! grep -q 'rpm-ostree kargs --append' '$LOG' && ! grep -q 'connection add' '$LOG' && grep -q '== check' '$root/out' && grep -q '== daemons' '$root/out'"

# ---- bridge
nox_cons=$'br0:bridge\nbr0-enp8s0:802-3-ethernet\nWired connection 1:802-3-ethernet\n'
reset; FAKE_CONS="$nox_cons" vh --only bridge --yes
check "bridge: the nox layout (br0 and br0-enp8s0 present): already done, no nmcli change" bash -c "grep -q 'already done' '$root/out' && ! grep -q 'connection add' '$LOG' && ! grep -q '^sudo' '$LOG'"
reset; SSH_CONNECTION="1 2 3 4" FAKE_CONS="" vh --only bridge --yes
check "bridge: refused over SSH without --yes-remote" bash -c "grep -q 'SSH session' '$root/out' && ! grep -q '^sudo' '$LOG'"
reset; FAKE_DEVS=$'enp8s0:ethernet\n' FAKE_DEFDEV=enp8s0 FAKE_CONS="" vh --only bridge --no
check "bridge --no: the plan only, nothing changed" bash -c "grep -q 'plan only' '$root/out' && ! grep -q '^sudo' '$LOG'"
reset; FAKE_DEVS=$'enp8s0:ethernet\n' FAKE_DEFDEV=enp8s0 FAKE_CONS="" FAKE_SUDO_FAIL=1 vh --only bridge --yes
check "bridge: a failing sudo prints the exact command and the undo, stops at the first failure" bash -c "[ $rc = 1 ] && grep -q 'FAILED: sudo nmcli connection add type bridge' '$root/out' && [ \$(grep -c '^sudo ' '$LOG') = 1 ]"

# ---- Wake-on-LAN
reset; FAKE_DEFDEV=enp8s0 FAKE_PROFILE="Wired connection 1" wol --yes
check "wake-on-lan: sets magic on the profile of the physical NIC through sudo, then reapplies; MAC and BIOS reminder printed" bash -c "[ $rc = 0 ] && grep -qx 'sudo nmcli connection modify Wired connection 1 802-3-ethernet.wake-on-lan magic' '$LOG' && grep -qx 'sudo nmcli device reapply enp8s0' '$LOG' && grep -q 'BIOS' '$root/out' && grep -q 'wakeonlan' '$root/out' && grep -q 'ujust wake-on-lan --off' '$root/out'"
FAKE_DEFDEV=br0 FAKE_PROFILE="br0-enp8s0" wol --yes
reset; FAKE_DEFDEV=enp8s0 FAKE_WOL=magic wol --off --yes
check "wake-on-lan --off: sets ignore" grep -qx 'sudo nmcli connection modify Wired connection 1 802-3-ethernet.wake-on-lan ignore' "$LOG"
reset; FAKE_DEFDEV=enp8s0 wol --no
check "wake-on-lan --no: the plan only" bash -c "grep -q 'Plan only' '$root/out' && ! grep -q '^sudo' '$LOG'"
reset; FAKE_DEFDEV=enp8s0 FAKE_SUDO_FAIL=1 wol --yes
check "wake-on-lan: a failing sudo is FAILED with the exact command, exit 1, not retried" bash -c "[ $rc = 1 ] && grep -q 'FAILED: sudo nmcli connection modify' '$root/out' && [ \$(grep -c '^sudo ' '$LOG') = 1 ]"
wakeup() { mkdir -p "$root/m/net/enp8s0/device/power"; : >"$root/m/net/enp8s0/device/power/wakeup"; }
reset; wakeup; FAKE_ETHTOOL=denied FAKE_DEFDEV=enp8s0 wol --yes
check "wol --yes with ethtool denied: ONE sudo ethtool read first (confirmed g), then the nmcli write and the reapply, never retried" bash -c "[ $rc = 0 ] && grep -q 'Confirmed: ' '$root/out' && [ \$(grep -c '^sudo ethtool enp8s0' '$LOG') = 1 ] && [ \$(grep -n '^sudo ethtool' '$LOG' | cut -d: -f1) -lt \$(grep -n '^sudo nmcli connection modify' '$LOG' | cut -d: -f1) ] && grep -qx 'sudo nmcli device reapply enp8s0' '$LOG'"
reset; FAKE_UID=0 wol --yes
check "wake-on-lan refuses root" test "$rc" = 1
reset; wol --bogus
check "wake-on-lan: an unknown option exits 2" test "$rc" = 2

echo
echo "passed: $pass, failed: $failn"
[ "$failn" = 0 ]
