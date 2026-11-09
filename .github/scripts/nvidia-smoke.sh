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
nvidia_modules() { find "${modules_dir}" -name 'nvidia*.ko*' 2>/dev/null; }

case "${mode}" in
    present)
        kver=$(ls "${modules_dir}" | head -1)
        check "an NVIDIA driver package is installed" "nvidia_pkgs | grep -q ."
        check "an NVIDIA kernel module exists for the kernel" "nvidia_modules | grep -q ."
        check "exactly one kernel is installed" "test \"\$(ls '${modules_dir}' | wc -l)\" = 1"
        check "the kernel is the one of the base image (${BASE_KERNEL:-unset})" "test -n '${BASE_KERNEL:-}' && test '${kver}' = '${BASE_KERNEL:-}'"
        check "the initramfs for the kernel exists" "test -s '${modules_dir}/${kver}/initramfs.img'"
        if command -v lsinitrd >/dev/null 2>&1; then
            check "the initramfs contains the nvidia modules" "lsinitrd '${modules_dir}/${kver}/initramfs.img' | grep -qi nvidia"
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
