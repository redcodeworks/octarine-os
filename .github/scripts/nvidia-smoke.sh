#!/usr/bin/env bash
# Checks run INSIDE an image for the NVIDIA variant.
#
#   nvidia-smoke.sh present   the variant: driver, kernel module, initramfs, kernel arguments, SELinux module
#   nvidia-smoke.sh absent    the default image: no NVIDIA driver packages or kernel modules
#
# Environment: BASE_KERNEL (present: the kernel release of the base image, which must be unchanged), and for tests
# MODULES_DIR, KARGS_FILE, MODPROBE_FILE. Package names are not hard-coded: any installed package with "nvidia" in its
# name counts as the driver, except the firmware package (nvidia-gpu-firmware ships with Fedora's linux-firmware).
set -uo pipefail

mode="${1:?present or absent}"
modules_dir="${MODULES_DIR:-/usr/lib/modules}"
kargs_file="${KARGS_FILE:-/usr/lib/bootc/kargs.d/00-nvidia.toml}"
modprobe_file="${MODPROBE_FILE:-/usr/lib/modprobe.d/00-nouveau-blacklist.conf}"
fail=0
check() { if eval "$2" >/dev/null 2>&1; then echo "PASS $1"; else echo "FAIL $1"; fail=1; fi; }

nvidia_pkgs() { rpm -qa | grep -i nvidia | grep -vi firmware; }
# Exact names of the proprietary driver's modules, anywhere under the modules directory. A glob like nvidia*.ko* also
# matches the stock kernel's nvidia-wmi-ec-backlight.ko.xz (a laptop backlight helper, no relation to the driver).
nvidia_re='nvidia(-drm|-modeset|-uvm|-peermem)?\.ko(\.[a-z0-9]+)?'
nvidia_modules() { find "${modules_dir}" -type f 2>/dev/null | grep -E "/${nvidia_re}\$"; }
# lsinitrd lists "mode owner size date path": match the module file names, not the word nvidia
# The listing goes to a file first: with pipefail, "lsinitrd | grep -q" fails whenever grep exits at the first match and
# lsinitrd (a long bash script) dies of SIGPIPE (status 141), which made a good initramfs fail this check.
initrd_list() { # initramfs, output file; the exit status is lsinitrd's
    lsinitrd "$1" >"$2" 2>"$2.err"
}
initrd_has_nvidia() {
    local list rc
    list=$(mktemp) || return 1
    initrd_list "$1" "${list}"; rc=$?
    # a failing lsinitrd is not proof of absence, but an empty listing is no proof of presence either
    if [ "${rc}" -eq 0 ] && grep -qE "(^|[ /])${nvidia_re}( |\$)" "${list}"; then rm -f "${list}" "${list}.err"; return 0; fi
    rm -f "${list}" "${list}.err"
    return 1
}
# Printed when the initramfs check fails, so the log explains itself (stderr is kept here, unlike in the check)
initrd_diagnose() {
    local img=$1 list rc
    list=$(mktemp) || return 0
    initrd_list "${img}" "${list}"; rc=$?
    echo "DIAG lsinitrd exit status: ${rc}"
    echo "DIAG lsinitrd stderr:"; head -20 "${list}.err" | sed 's/^/DIAG   /'
    echo "DIAG first 5 lines of lsinitrd:"; head -5 "${list}" | sed 's/^/DIAG   /'
    echo "DIAG lsinitrd lines matching nvidia (max 20):"; grep -i nvidia "${list}" | head -20 | sed 's/^/DIAG   /'
    echo "DIAG ls -l of the initramfs:"; ls -l "${img}" 2>&1 | sed 's/^/DIAG   /'
    rm -f "${list}" "${list}.err"
}

case "${mode}" in
    present)
        kver=$(ls "${modules_dir}" | head -1)
        check "an NVIDIA driver package is installed" "nvidia_pkgs | grep -q ."
        check "an NVIDIA kernel module exists for the kernel" "nvidia_modules | grep -q ."
        check "exactly one kernel is installed" "test \"\$(ls '${modules_dir}' | wc -l)\" = 1"
        check "the kernel is the one of the base image (${BASE_KERNEL:-unset})" "test -n '${BASE_KERNEL:-}' && test '${kver}' = '${BASE_KERNEL:-}'"
        check "the initramfs for the kernel exists" "test -s '${modules_dir}/${kver}/initramfs.img'"
        if command -v lsinitrd >/dev/null 2>&1; then
            before_fail=${fail}
            check "the initramfs contains the nvidia modules" "initrd_has_nvidia '${modules_dir}/${kver}/initramfs.img'"
            if [ "${fail}" != "${before_fail}" ]; then initrd_diagnose "${modules_dir}/${kver}/initramfs.img"; fi
        else
            echo "INFO lsinitrd not available: initramfs content not checked"
        fi
        check "kernel arguments file blacklists nouveau and sets modeset" "grep -q nvidia-drm.modeset=1 '${kargs_file}' && grep -q rd.driver.blacklist=nouveau '${kargs_file}'"
        check "nouveau is blacklisted for modprobe" "grep -qx 'blacklist nouveau' '${modprobe_file}'"
        check "the NVIDIA SELinux module is installed" "semodule -l | grep -qi nvidia"
        ;;
    absent)
        check "no NVIDIA driver package in the default image" "! nvidia_pkgs | grep -q ."
        check "no NVIDIA kernel module in the default image" "! nvidia_modules | grep -q ."
        ;;
    *) echo "unknown mode ${mode}" >&2; exit 2 ;;
esac
exit "${fail}"
