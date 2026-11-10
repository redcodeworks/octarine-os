#!/usr/bin/env bash
# Checks run INSIDE an image for the NVIDIA variant.
#
#   nvidia-smoke.sh present   the variant: driver, kernel module, initramfs, kernel arguments, SELinux module
#   nvidia-smoke.sh absent    the default image: no NVIDIA driver packages or kernel modules
#
# The NVIDIA developer image (octarine-os-nvidia-dx) runs the same `present` checks with EXPECT_IMAGE_ID=octarine-os-nvidia-dx.
# Environment: EXPECT_IMAGE_ID (present: the os-release IMAGE_ID, default octarine-os-nvidia), BASE_KERNEL (present: the kernel release of the base image, which must be unchanged), and for tests
# MODULES_DIR, KARGS_FILE, MODPROBE_FILE, OS_RELEASE. Package names are not hard-coded: any installed package with "nvidia" in its
# name counts as the driver, except the firmware package (nvidia-gpu-firmware ships with Fedora's linux-firmware).
set -uo pipefail

mode="${1:?present or absent}"
modules_dir="${MODULES_DIR:-/usr/lib/modules}"
kargs_file="${KARGS_FILE:-/usr/lib/bootc/kargs.d/00-nvidia.toml}"
modprobe_file="${MODPROBE_FILE:-/usr/lib/modprobe.d/00-nouveau-blacklist.conf}"
os_release="${OS_RELEASE:-/etc/os-release}"
expect_image_id="${EXPECT_IMAGE_ID:-octarine-os-nvidia}"
local_dir="${LOCAL_DIR:-/usr/local}"
fail=0
check() { if eval "$2" >/dev/null 2>&1; then echo "PASS $1"; else echo "FAIL $1"; fail=1; fi; }

nvidia_pkgs() { rpm -qa | grep -i nvidia | grep -vi firmware; }
# The CUDA toolkit (nvcc and friends) is never part of an image: NVIDIA's license does not allow shipping it, and `ujust dev`
# installs it in a distrobox. Only the driver's own userspace (nvidia-driver-cuda*, libcuda) belongs here.
toolkit_pkgs() { local all; all=$(rpm -qa); grep -iE '^(cuda-toolkit|cuda-nvcc|cuda-compiler|nvidia-cuda-toolkit)' <<<"${all}"; }
no_toolkit_files() { [ -z "$(find "${local_dir}" -maxdepth 1 -name 'cuda*' 2>/dev/null)" ] && ! command -v nvcc; }
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
        check "pretty name" "grep -qx 'PRETTY_NAME=\"octarineOS\"' '${os_release}'"
        check "image id (${expect_image_id})" "grep -qx 'IMAGE_ID=\"${expect_image_id}\"' '${os_release}'"
        check "image version has the build's version format" "grep -qE '^IMAGE_VERSION=\"[0-9]{8}-[0-9a-f]{7,}\"\$' '${os_release}'"
        check "no CUDA toolkit package is installed" "test -z \"\$(toolkit_pkgs)\""
        check "no /usr/local/cuda* and no nvcc" "no_toolkit_files"
        # what a container needs to get the GPU through CDI (informational: whether the driver install brings them is unverified)
        for p in nvidia-container-toolkit nvidia-container-toolkit-base; do
            if rpm -q "${p}" >/dev/null 2>&1; then echo "INFO package ${p} installed"; else echo "INFO package ${p} NOT installed (needed for CDI)"; fi
        done
        for u in nvidia-cdi-refresh.path nvidia-cdi-refresh.service; do
            if systemctl is-enabled "${u}" >/dev/null 2>&1; then echo "INFO ${u} enabled"; else echo "WARNING ${u} not enabled (CDI spec is not regenerated at boot; unverified)"; fi
        done
        if command -v nvidia-ctk >/dev/null 2>&1; then echo "INFO nvidia-ctk present"; else echo "INFO nvidia-ctk NOT present (needed for CDI)"; fi
        ;;
    absent)
        check "no NVIDIA driver package in the default image" "! nvidia_pkgs | grep -q ."
        check "no NVIDIA kernel module in the default image" "! nvidia_modules | grep -q ."
        ;;
    *) echo "unknown mode ${mode}" >&2; exit 2 ;;
esac
exit "${fail}"
