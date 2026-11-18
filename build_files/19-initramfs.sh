#!/usr/bin/bash
# Derived from ublue-os/bluefin build_files/base/19-initramfs.sh (Apache-2.0, https://github.com/ublue-os/bluefin); modified for octarine-os.
# Deviation: the Plymouth watermark check after dracut (the initramfs carries our Plymouth theme).

echo "::group:: ===$(basename "$0")==="

set -oue pipefail

KERNEL_SUFFIX=""
QUALIFIED_KERNEL="$(rpm -qa | grep -P 'kernel-(|'"$KERNEL_SUFFIX"'-)(\d+\.\d+\.\d+)' | sed -E 's/kernel-(|'"$KERNEL_SUFFIX"'-)//')"
export DRACUT_NO_XATTR=1
/usr/bin/dracut --no-hostonly --kver "$QUALIFIED_KERNEL" --reproducible -v --add ostree -f "/lib/modules/$QUALIFIED_KERNEL/initramfs.img"
chmod 0600 "/lib/modules/$QUALIFIED_KERNEL/initramfs.img"
lsinitrd "/lib/modules/$QUALIFIED_KERNEL/initramfs.img" | grep -F 'usr/share/plymouth/themes/octarine/watermark.png'

echo "::endgroup::"
