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
DRACUT_NO_XATTR=1 dracut --no-hostonly --kver "${before}" --reproducible --add ostree -f "/usr/lib/modules/${before}/initramfs.img"
chmod 0600 "/usr/lib/modules/${before}/initramfs.img"
echo "NVIDIA driver installed for kernel ${before}"
