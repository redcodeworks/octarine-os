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
export LOG="$root/log" HOME="$root/home" OCTARINE_MENU_LIB="$here/system_files/usr/share/octarine-os/lib/menu.sh"
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

# ---- shape
reset; vh --help
check "help: exit 0, names every step and flag" bash -c "[ $rc = 0 ] && for w in check daemons iommu connection image-dir virtio bridge libvirt-network --image-dir --nic --yes --no --only; do grep -q -- \"\$w\" '$root/out' || exit 1; done"
reset; vh --bogus; check "unknown option exits 2" test "$rc" = 2
reset; vh --only nosuch; check "unknown step exits 2" test "$rc" = 2
reset; FAKE_UID=0 vh --only check; check "root is refused" bash -c "[ $rc = 1 ] && grep -q 'not as root' '$root/out'"
check "the recipe lives in the dx recipe file only: the default image's recipe files have no virthost-setup" bash -c "! grep -q '^virthost-setup' '$here/system_files/usr/share/ublue-os/just/'*.just && grep -q '^virthost-setup' '$vjust'"
check "recipe: group Setup and a one-line description" bash -c "just --justfile '$vjust' --list | grep -q 'Turn this machine into a KVM/libvirt host'"
check "dx.sh imports the recipe file" grep -q '75-octarine-virthost.just' "$here/variants/dx/dx.sh"

# ---- check
reset; vh --only check
check "check: flag, /dev/kvm and virt-host-validate summarized; the IOMMU warning points at the iommu step" bash -c "[ $rc = 0 ] && grep -q 'virtualization flag: present' '$root/out' && grep -q 'present' '$root/out' && grep -q 'see the iommu step' '$root/out' && grep -q 'informational' '$root/out' && ! grep -q '^sudo' '$LOG'"
reset; printf 'vendor_id: GenuineIntel\nflags: fpu\n' >"$VIRTHOST_CPUINFO"; rm -f "$VIRTHOST_KVM"; vh --only check
check "check: no vmx or svm flag says to enable it in the UEFI; a missing /dev/kvm is reported" bash -c "grep -q 'Enable VT-x' '$root/out' && grep -q 'missing' '$root/out'"

# ---- daemons
reset; ENABLED_UNITS="$(all_socks)" vh --only daemons
check "daemons: all modular sockets enabled and libvirtd not: already done, no sudo" bash -c "grep -q 'already done' '$root/out' && ! grep -q '^sudo' '$LOG'"
reset; ENABLED_UNITS="virtqemud.socket" vh --only daemons --yes
check "daemons: the missing sockets are enabled with --now through sudo, once, and libvirtd is never enabled" bash -c "[ $rc = 0 ] && grep -q '^sudo systemctl enable --now .*virtnetworkd.socket' '$LOG' && ! grep -q 'enable.*libvirtd' '$LOG' && [ \$(grep -c '^sudo systemctl enable' '$LOG') = 1 ]"
reset; ENABLED_UNITS="$(all_socks) libvirtd.socket" vh --only daemons --yes
check "daemons: an enabled libvirtd.socket is disabled (it excludes the modular sockets)" bash -c "grep -q '^sudo systemctl disable --now libvirtd.socket' '$LOG' && ! grep -q 'enable --now' '$LOG'"
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
reset; echo "quiet iommu=pt" >"$VIRTHOST_CMDLINE"; vh --only iommu --yes
check "iommu: already in /proc/cmdline: already done, no sudo" bash -c "grep -q 'already set' '$root/out' && ! grep -q '^sudo' '$LOG'"
reset; FAKE_KARGS="quiet iommu=pt" vh --only iommu --yes
check "iommu: already staged in rpm-ostree kargs (not yet booted): already done" bash -c "grep -q 'already set' '$root/out' && ! grep -q '^sudo' '$LOG'"
reset; FAKE_SUDO_FAIL=1 vh --only iommu --yes
check "iommu: a failing sudo prints the exact command, exit 1" bash -c "[ $rc = 1 ] && grep -q 'FAILED: sudo rpm-ostree kargs --append-if-missing=iommu=pt' '$root/out'"
reset; vh --only iommu --no
check "iommu --no: the plan only" bash -c "grep -q 'Plan: sudo rpm-ostree kargs' '$root/out' && ! grep -q '^sudo' '$LOG'"
reset; vh --yes
check "--yes runs check, daemons, connection, image-dir, virtio and libvirt-network, never iommu or bridge" bash -c "! grep -q 'rpm-ostree kargs --append' '$LOG' && ! grep -q 'connection add' '$LOG' && grep -q '== check' '$root/out' && grep -q '== daemons' '$root/out'"

# ---- connection
reset; vh --only connection --yes
check "connection: usermod -aG libvirt through sudo (once), uri_default written, the log-in-again note" bash -c "[ $rc = 0 ] && grep -qx 'sudo usermod -aG libvirt tester' '$LOG' && grep -qx 'uri_default = \"qemu:///system\"' '$HOME/.config/libvirt/libvirt.conf' && grep -q 'log in again\\|Log in again\\|log in' '$root/out'"
reset; FAKE_GROUPS="tester libvirt" mkdir -p "$HOME/.config/libvirt"; printf 'uri_default = "qemu:///system"\n' >"$HOME/.config/libvirt/libvirt.conf"; FAKE_GROUPS="tester libvirt" vh --only connection --yes
check "connection: group and URI already set: already done, no sudo" bash -c "grep -q 'already done' '$root/out' && ! grep -q '^sudo' '$LOG'"
reset; mkdir -p "$HOME/.config/libvirt"; printf 'uri_aliases = ["a=b"]\nuri_default = "qemu:///session"\n' >"$HOME/.config/libvirt/libvirt.conf"; FAKE_LIBVIRT_MEMBERS=tester vh --only connection --yes
check "connection: a different libvirt.conf is changed after a timestamped backup and keeps its other lines; no LIBVIRT_DEFAULT_URI anywhere" bash -c "ls '$HOME'/.config/libvirt/libvirt.conf.bak-* >/dev/null && grep -qx 'uri_aliases = \\[\"a=b\"\\]' '$HOME/.config/libvirt/libvirt.conf' && grep -qx 'uri_default = \"qemu:///system\"' '$HOME/.config/libvirt/libvirt.conf' && ! grep -rq LIBVIRT_DEFAULT_URI '$vjust'"
reset; FAKE_SUDO_FAIL=1 vh --only connection --yes
check "connection: a failing sudo is FAILED with the command and writes no conf" bash -c "[ $rc = 1 ] && grep -q 'FAILED: sudo usermod' '$root/out' && [ ! -e '$HOME/.config/libvirt/libvirt.conf' ]"

# ---- image-dir
reset; vh --only image-dir --image-dir /var/lib/libvirt/images --yes
check "image-dir, default directory: ACL for the user and a default ACL for new files, no recursion, no -b, no SELinux change" bash -c "[ $rc = 0 ] && grep -q '^sudo setfacl -m u:tester:rwx /var/lib/libvirt/images' '$LOG' && grep -q '^sudo setfacl -d -m u:tester:rwx /var/lib/libvirt/images' '$LOG' && ! grep -E ' -R| -b| -k|semanage|restorecon|chcon|u:qemu' '$LOG'"
reset; mkdir -p "$VIRTHOST_IMAGE_DIR"; FAKE_FACL=full FAKE_CTX=virt vh --only image-dir --yes
check "image-dir: ACL and virt_image_t already right: already done, no sudo" bash -c "grep -q 'already done' '$root/out' && ! grep -q '^sudo' '$LOG'"
reset; cust="$root/mnt/data/images"; vh --only image-dir --image-dir "$cust" --yes
check "image-dir, custom directory: created, user ACL, qemu search access on every parent, semanage fcontext plus restorecon" bash -c "[ $rc = 0 ] && grep -q '^sudo mkdir -p $cust' '$LOG' && grep -q '^sudo setfacl -m u:qemu:x $root/mnt/data' '$LOG' && grep -q '^sudo setfacl -m u:qemu:x $root/mnt\$' '$LOG' && grep -q '^sudo semanage fcontext -a -t virt_image_t $cust(/.\\*)?' '$LOG' && grep -q '^sudo restorecon -R $cust' '$LOG'"
reset; FAKE_FACL=qemu vh --only image-dir --image-dir "$cust" --yes
check "image-dir: a parent that already has the qemu ACL is left alone" bash -c "! grep -q 'setfacl -m u:qemu:x' '$LOG'"
reset; mv "$bin/semanage" "$root/semanage.off"; vh --only image-dir --image-dir "$cust" --yes; mv "$root/semanage.off" "$bin/semanage"
check "image-dir: without semanage the fallback is chcon, said not to be persistent" bash -c "grep -q '^sudo chcon -R -t virt_image_t $cust' '$LOG' && grep -q 'NOT persistent' '$root/out'"
reset; vh --only image-dir --image-dir "$cust" --pool images --yes
check "image-dir: --pool defines, builds, starts and autostarts a dir pool through the libvirt group" bash -c "grep -q 'pool-define-as --name images --type dir --target $cust' '$LOG' && grep -q 'pool-build images' '$LOG' && grep -q 'pool-start images' '$LOG' && grep -q 'pool-autostart images' '$LOG'"
reset; FAKE_SUDO_FAIL=1 vh --only image-dir --yes
check "image-dir: a failing sudo is FAILED and says how to re-run" bash -c "[ $rc = 1 ] && grep -q 'FAILED' '$root/out' && grep -q 'ujust virthost-setup --only image-dir' '$root/out'"

# ---- virtio
reset; mkdir -p "$VIRTHOST_IMAGE_DIR"; vh --only virtio --yes
check "virtio: downloads the STABLE link over https only into the image directory, keeps the versioned name, a symlink and the recorded sha256" bash -c "[ $rc = 0 ] && grep -q 'stable-virtio/virtio-win.iso' '$LOG' && grep -q -- \"--proto =https --proto-redir =https --retry 3 -C -\" '$LOG' && [ -f '$VIRTHOST_IMAGE_DIR/virtio-win-0.1.302.iso' ] && [ -L '$VIRTHOST_IMAGE_DIR/virtio-win.iso' ] && grep -q 'virtio-win-0.1.302.iso' '$VIRTHOST_IMAGE_DIR/virtio-win-0.1.302.iso.sha256' && grep -q 'No checksum or signature is published' '$root/out' && [ ! -e '$VIRTHOST_IMAGE_DIR/virtio-win.iso.part' ]"
reset; mkdir -p "$VIRTHOST_IMAGE_DIR"; vh --only virtio --yes --virtio latest
check "virtio --virtio latest uses the latest-virtio link" grep -q 'latest-virtio/virtio-win.iso' "$LOG"
reset; mkdir -p "$VIRTHOST_IMAGE_DIR"; : >"$VIRTHOST_IMAGE_DIR/virtio-win-0.1.285.iso"; vh --only virtio --yes
check "virtio: an existing virtio-win ISO is skipped (already done), no curl" bash -c "grep -q 'already done' '$root/out' && ! grep -q '^curl' '$LOG'"
reset; mkdir -p "$VIRTHOST_IMAGE_DIR"; : >"$VIRTHOST_IMAGE_DIR/virtio-win-0.1.285.iso"; vh --only virtio --yes --force
check "virtio --force downloads again" grep -q '^curl' "$LOG"
reset; mkdir -p "$VIRTHOST_IMAGE_DIR"; FAKE_CURL_FAIL=1 vh --only virtio --yes
check "virtio: offline or blocked: FAILED, the URL to fetch by hand, no partial file left, exit 1" bash -c "[ $rc = 1 ] && grep -q 'Fetch it by hand: https://fedorapeople.org' '$root/out' && [ -z \"\$(ls '$VIRTHOST_IMAGE_DIR')\" ]"
reset; vh --only virtio --yes
check "virtio: without the image directory it says to run image-dir first" has "image-dir"
check "virtio never layers the virtio-win RPM or adds a repository" bash -c "! grep -E 'rpm-ostree install|dnf|\\.repo' '$vjust'"

# ---- bridge
nox_cons=$'br0:bridge\nbr0-enp8s0:802-3-ethernet\nWired connection 1:802-3-ethernet\n'
reset; FAKE_CONS="$nox_cons" vh --only bridge --yes
check "bridge: the nox layout (br0 and br0-enp8s0 present): already done, no nmcli change" bash -c "grep -q 'already done' '$root/out' && ! grep -q 'connection add' '$LOG' && ! grep -q '^sudo' '$LOG'"
reset; SSH_CONNECTION="1 2 3 4" FAKE_CONS="" vh --only bridge --yes
check "bridge: refused over SSH without --yes-remote" bash -c "grep -q 'SSH session' '$root/out' && ! grep -q '^sudo' '$LOG'"
reset; FAKE_DEVS=$'enp8s0:ethernet\nwlp3s0:wifi\n' FAKE_DEFDEV=enp8s0 FAKE_CONS=$'Wired connection 1:802-3-ethernet\n' FAKE_PROFILE="Wired connection 1" vh --only bridge --yes
check "bridge fresh: bridge profile, port profile with port-type bridge and controller, the old profile autoconnect off, then both brought up (current syntax)" bash -c "[ $rc = 0 ] && grep -qx 'sudo nmcli connection add type bridge con-name br0 ifname br0 bridge.stp no connection.autoconnect-ports yes ipv4.method auto ipv6.method auto' '$LOG' && grep -qx 'sudo nmcli connection add type ethernet con-name br0-enp8s0 ifname enp8s0 connection.port-type bridge connection.controller br0' '$LOG' && grep -qx 'sudo nmcli connection modify Wired connection 1 connection.autoconnect no' '$LOG' && grep -qx 'sudo nmcli connection up br0' '$LOG' && grep -qx 'sudo nmcli connection up br0-enp8s0' '$LOG' && ! grep -E 'slave-type|master' '$LOG'"
check "bridge fresh: the plan shows NIC, profile and address, and the undo restores the old profile" bash -c "grep -q 'NIC enp8s0' '$root/out' && grep -q 'connection.autoconnect yes' '$root/out' && grep -q 'connection delete br0' '$root/out'"
reset; FAKE_DEVS=$'wlp3s0:wifi\n' FAKE_CONS="" vh --only bridge --yes
check "bridge: only Wi-Fi: refused with the reason, nothing run" bash -c "grep -q 'Wi-Fi' '$root/out' && ! grep -q '^sudo' '$LOG'"
reset; FAKE_DEVS=$'enp8s0:ethernet\nenp9s0:ethernet\n' FAKE_CONS="" vh --only bridge --yes
check "bridge: several wired NICs and no default route: the candidates are listed and --nic is asked for, nothing run" bash -c "grep -q 'Candidates: enp8s0 enp9s0' '$root/out' && grep -q -- '--nic IFACE' '$root/out' && ! grep -q '^sudo' '$LOG'"
reset; FAKE_DEVS=$'enp8s0:ethernet\nenp9s0:ethernet\n' FAKE_CONS="" vh --only bridge --yes --nic enp9s0
check "bridge: --nic names the port" grep -q 'con-name br0-enp9s0 ifname enp9s0' "$LOG"
reset; FAKE_DEVS=$'enp8s0:ethernet\n' FAKE_DEFDEV=enp8s0 FAKE_CONS="" vh --only bridge --no
check "bridge --no: the plan only, nothing changed" bash -c "grep -q 'plan only' '$root/out' && ! grep -q '^sudo' '$LOG'"
reset; FAKE_DEVS=$'enp8s0:ethernet\n' FAKE_DEFDEV=enp8s0 FAKE_CONS="" FAKE_SUDO_FAIL=1 vh --only bridge --yes
check "bridge: a failing sudo prints the exact command and the undo, stops at the first failure" bash -c "[ $rc = 1 ] && grep -q 'FAILED: sudo nmcli connection add type bridge' '$root/out' && [ \$(grep -c '^sudo ' '$LOG') = 1 ]"
reset; FAKE_DEVS=$'enp8s0:ethernet\n' FAKE_DEFDEV=enp8s0 FAKE_CONS="" SSH_CONNECTION="1 2 3 4" vh --only bridge --yes --yes-remote
check "bridge: --yes-remote allows it over SSH" grep -q 'connection add type bridge' "$LOG"

# ---- libvirt-network
reset; FAKE_CONS="$nox_cons" vh --only libvirt-network --yes
check "libvirt-network: defines nwbridge on br0 from a temp XML, starts and autostarts it; the default network is not touched" bash -c "[ $rc = 0 ] && grep -q 'virsh -c qemu:///system net-define' '$LOG' && grep -q 'net-start nwbridge' '$LOG' && grep -q 'net-autostart nwbridge' '$LOG' && ! grep -q 'default' '$LOG' && grep -q 'net-undefine nwbridge' '$root/out'"
reset; FAKE_NET_EXISTS=1 FAKE_CONS="$nox_cons" vh --only libvirt-network --yes
check "libvirt-network: nwbridge exists: already done" bash -c "grep -q 'already done' '$root/out' && ! grep -q 'net-define' '$LOG'"
reset; FAKE_CONS="" vh --only libvirt-network --yes
check "libvirt-network: no host bridge: says to run the bridge step first" bash -c "grep -q 'bridge step first' '$root/out' && ! grep -q 'net-define' '$LOG'"
reset; FAKE_CONS=$'xbr:bridge\n' vh --only libvirt-network --yes --bridge xbr
check "libvirt-network: --bridge names an existing bridge" bash -c "grep -q 'net-define' '$LOG'"

# ---- Wake-on-LAN
reset; FAKE_DEFDEV=enp8s0 FAKE_PROFILE="Wired connection 1" wol --yes
check "wake-on-lan: sets magic on the profile of the physical NIC through sudo, then reapplies; MAC and BIOS reminder printed" bash -c "[ $rc = 0 ] && grep -qx 'sudo nmcli connection modify Wired connection 1 802-3-ethernet.wake-on-lan magic' '$LOG' && grep -qx 'sudo nmcli device reapply enp8s0' '$LOG' && grep -q 'BIOS' '$root/out' && grep -q 'wakeonlan' '$root/out' && grep -q 'ujust wake-on-lan --off' '$root/out'"
reset; mkdir -p "$root/m/net/br0/bridge" "$root/m/net/br0/brif/enp8s0"; echo "aa:bb:cc:dd:ee:ff" >"$root/m/net/enp8s0.addr"; mkdir -p "$root/m/net/enp8s0"; echo "aa:bb:cc:dd:ee:ff" >"$root/m/net/enp8s0/address"
FAKE_DEFDEV=br0 FAKE_PROFILE="br0-enp8s0" wol --yes
check "wake-on-lan on a bridge: the default route is br0, the setting goes on the PORT profile of the physical NIC (br0-enp8s0), the MAC is the NIC's" bash -c "grep -qx 'sudo nmcli connection modify br0-enp8s0 802-3-ethernet.wake-on-lan magic' '$LOG' && grep -qx 'sudo nmcli device reapply enp8s0' '$LOG' && grep -q 'aa:bb:cc:dd:ee:ff' '$root/out'"
reset; FAKE_DEFDEV=enp8s0 FAKE_WOL=magic wol --yes
check "wake-on-lan: already magic: already done, no sudo" bash -c "grep -q 'Already done' '$root/out' && ! grep -q '^sudo' '$LOG'"
reset; FAKE_DEFDEV=enp8s0 FAKE_WOL=magic wol --off --yes
check "wake-on-lan --off: sets ignore" grep -qx 'sudo nmcli connection modify Wired connection 1 802-3-ethernet.wake-on-lan ignore' "$LOG"
reset; FAKE_DEFDEV=enp8s0 wol --no
check "wake-on-lan --no: the plan only" bash -c "grep -q 'Plan only' '$root/out' && ! grep -q '^sudo' '$LOG'"
reset; FAKE_DEFDEV=enp8s0 FAKE_WOL=magic wol --status
check "wake-on-lan --status shows the setting and the MAC, changes nothing" bash -c "grep -q 'wake-on-lan setting: magic' '$root/out' && ! grep -q '^sudo' '$LOG'"
reset; FAKE_DEFDEV=enp8s0 FAKE_SUDO_FAIL=1 wol --yes
check "wake-on-lan: a failing sudo is FAILED with the exact command, exit 1, not retried" bash -c "[ $rc = 1 ] && grep -q 'FAILED: sudo nmcli connection modify' '$root/out' && [ \$(grep -c '^sudo ' '$LOG') = 1 ]"
reset; mk ethtool 'echo "Supports Wake-on: d"'; FAKE_DEFDEV=enp8s0 wol --yes; mk ethtool 'case "${FAKE_ETHTOOL:-ok}" in denied) echo "Settings for enp8s0:"; echo "netlink error: Operation not permitted" >&2 ;; *) echo "Supports Wake-on: pumbg" ;; esac; exit 0'
check "wake-on-lan: a NIC without g does nothing" bash -c "[ $rc = 0 ] && grep -q 'does not report magic-packet wake' '$root/out' && ! grep -q '^sudo' '$LOG'"
# ---- wake-on-lan when ethtool is not readable as a normal user (nox: "netlink error: Operation not permitted", no Wake-on line)
wakeup() { mkdir -p "$root/m/net/enp8s0/device/power"; : >"$root/m/net/enp8s0/device/power/wakeup"; }
reset; wakeup; mkdir -p "$root/m/net/br0/bridge" "$root/m/net/br0/brif"; : >"$root/m/net/br0/brif/enp8s0"; FAKE_ETHTOOL=denied FAKE_DEFDEV=br0 FAKE_PROFILE="br0-enp8s0" wol --status
check "wol, ethtool denied, sysfs wakeup file: NOT 'unsupported'; --status says support unknown, no sudo" bash -c "[ $rc = 0 ] && grep -q 'support: unknown' '$root/out' && grep -q 'not readable without root' '$root/out' && ! grep -q 'does not report' '$root/out' && ! grep -q '^sudo' '$LOG'"
reset; wakeup; FAKE_ETHTOOL=denied FAKE_DEFDEV=enp8s0 wol --no
check "wol --no with ethtool denied: the plan names the one read-only sudo ethtool, then the write; nothing runs" bash -c "[ $rc = 0 ] && grep -q 'sudo ethtool enp8s0' '$root/out' && grep -q 'sudo nmcli connection modify' '$root/out' && grep -q 'Plan only' '$root/out' && ! grep -q '^sudo' '$LOG'"
reset; wakeup; FAKE_ETHTOOL=denied FAKE_DEFDEV=enp8s0 wol --yes
check "wol --yes with ethtool denied: ONE sudo ethtool read first (confirmed g), then the nmcli write and the reapply, never retried" bash -c "[ $rc = 0 ] && grep -q 'Confirmed: ' '$root/out' && [ \$(grep -c '^sudo ethtool enp8s0' '$LOG') = 1 ] && [ \$(grep -n '^sudo ethtool' '$LOG' | cut -d: -f1) -lt \$(grep -n '^sudo nmcli connection modify' '$LOG' | cut -d: -f1) ] && grep -qx 'sudo nmcli device reapply enp8s0' '$LOG'"
reset; wakeup; FAKE_SUDO_ETHTOOL="	Supports Wake-on: d" FAKE_ETHTOOL=denied FAKE_DEFDEV=enp8s0 wol --yes
check "wol with ethtool denied, the sudo read shows no g: nothing is written, exit 0" bash -c "[ $rc = 0 ] && grep -q 'does not report magic-packet wake support' '$root/out' && ! grep -q 'sudo nmcli' '$LOG'"
reset; wakeup; FAKE_SUDO_FAIL=1 FAKE_ETHTOOL=denied FAKE_DEFDEV=enp8s0 wol --yes
check "wol with ethtool denied and the sudo read failing: FAILED with the exact command, nothing written, one sudo call, exit 1" bash -c "[ $rc = 1 ] && grep -q 'FAILED: sudo ethtool enp8s0' '$root/out' && [ \$(grep -c '^sudo' '$LOG') = 1 ]"
reset; wakeup; mkdir -p "$root/m/net/br0/bridge" "$root/m/net/br0/brif"; : >"$root/m/net/br0/brif/enp8s0"; FAKE_ETHTOOL=denied FAKE_WOL=magic FAKE_DEFDEV=br0 FAKE_PROFILE="br0-enp8s0" wol --yes
check "wol, nox layout (bridge br0, port profile already magic, ethtool denied): already done, no sudo at all" bash -c "[ $rc = 0 ] && grep -q 'Already done' '$root/out' && ! grep -q '^sudo' '$LOG'"
reset; FAKE_ETHTOOL=denied FAKE_DEFDEV=enp8s0 wol --yes
check "wol, ethtool denied, no sysfs file and the profile not magic: no sign of support, nothing to do, no sudo" bash -c "[ $rc = 0 ] && grep -q 'no sign that it works' '$root/out' && ! grep -q '^sudo' '$LOG'"
reset; wakeup; FAKE_ETHTOOL=denied FAKE_DEFDEV=enp8s0 FAKE_WOL=magic wol --off --yes
check "wol --off with ethtool denied needs no ethtool read, only the nmcli write" bash -c "[ $rc = 0 ] && ! grep -q '^sudo ethtool' '$LOG' && grep -q 'wake-on-lan ignore' '$LOG'"
reset; FAKE_UID=0 wol --yes
check "wake-on-lan refuses root" test "$rc" = 1
reset; wol --bogus
check "wake-on-lan: an unknown option exits 2" test "$rc" = 2
check "wake-on-lan is in 60-custom.just above the toolbox recipe, group Setup" bash -c "awk '/^wake-on-lan \\*args:/{w=NR} /^toolbox \\*args:/{t=NR} END{exit !(w && t && w<t)}' '$cjust'"

# ---- no sudo outside the named steps and no stray tools
check "no pkexec or run0 in the recipes, and sudo only appears as the run_sudo helper or in the printed commands" bash -c "! grep -E '(pkexec|run0)' '$vjust' && ! grep -nE '^[[:space:]]+sudo ' '$vjust'"

echo
echo "passed: $pass, failed: $failn"
[ "$failn" = 0 ]
