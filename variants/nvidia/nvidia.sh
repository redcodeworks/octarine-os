#!/usr/bin/env bash
# Adds the proprietary NVIDIA driver to octarine-os (image-template recipe "Adding NVIDIA drivers"): runs the
# nvidia-install.sh of the akmods image, then writes what that script does not (nouveau blacklist, kernel
# arguments) and rebuilds the initramfs. The kernel must be exactly the same before and after.
set -euo pipefail

kernel_of() { rpm -q --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}\n' kernel-core; }

before=$(kernel_of)
test "$(ls /usr/lib/modules | wc -l)" = 1
kver=$(ls /usr/lib/modules)
[[ "${kver}" == "${before}" ]] || { echo "ERROR: /usr/lib/modules holds ${kver} but kernel-core is ${before}"; exit 1; }
echo "Kernel of the base image: ${before}"

test -x /tmp/akmods-rpms/ublue-os/nvidia-install.sh
IMAGE_NAME=silverblue /tmp/akmods-rpms/ublue-os/nvidia-install.sh

after=$(kernel_of)
[[ "${after}" == "${before}" ]] || { echo "ERROR: the NVIDIA install changed the kernel (${before} -> ${after})"; exit 1; }
test "$(ls /usr/lib/modules | wc -l)" = 1
[[ "$(ls /usr/lib/modules)" == "${before}" ]] || { echo "ERROR: kernel module directory changed"; exit 1; }

# nvidia-install.sh writes neither of these (UNVERIFIED for Fedora; the shape Bluefin LTS uses). bootc merges this
# kargs.d file with the ones the base image already has (for example 10-iommu.toml).
cat >/usr/lib/modprobe.d/00-nouveau-blacklist.conf <<'EOM'
blacklist nouveau
options nouveau modeset=0
EOM
cat >/usr/lib/bootc/kargs.d/00-nvidia.toml <<'EOM'
kargs = ["rd.driver.blacklist=nouveau", "modprobe.blacklist=nouveau", "nvidia-drm.modeset=1"]
EOM

# The boot and LUKS screens run from the initramfs, which must carry the modules (99-nvidia.conf was edited by the script)
img="/usr/lib/modules/${before}/initramfs.img"
show_img() { echo "initramfs $1: $(stat -c 'size=%s mtime=%y' "${img}" 2>&1)"; }
show_img "before dracut"
# dracut logs "dracut-install: ERROR: installing '/root' to '/root'" and "No /dev/log" in the build container; the
# exit status decides, not the log text: a non-zero status fails the build with the message below.
rc=0
DRACUT_NO_XATTR=1 dracut --no-hostonly --kver "${before}" --reproducible --add ostree -f "${img}" || rc=$?
echo "dracut exit status: ${rc}"
show_img "after dracut"
[[ "${rc}" == 0 ]] || { echo "ERROR: dracut failed with status ${rc}, the initramfs is not trustworthy"; exit 1; }
chmod 0600 "${img}"
# The build log itself shows whether the modules landed (listing to a file: no SIGPIPE from head)
lst=$(mktemp)
lsinitrd_rc=0
lsinitrd "${img}" >"${lst}" 2>&1 || lsinitrd_rc=$?
echo "lsinitrd exit status: ${lsinitrd_rc}; nvidia entries of the new initramfs (max 20):"
grep -i nvidia "${lst}" | head -20 || true
rm -f "${lst}"
echo "NVIDIA driver installed for kernel ${before}"
