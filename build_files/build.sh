#!/bin/bash

set -ouex pipefail

# Copy the contents of system_files/ of the git repo to /
cp -avf "/ctx/system_files"/. /

### Install packages

# Packages can be installed from any enabled yum repo on the image.
# RPMfusion repos are available by default in ublue main images
# List of rpmfusion packages can be found here:
# https://mirrors.rpmfusion.org/mirrorlist?path=free/fedora/updates/43/x86_64/repoview/index.html&protocol=https&redirect=1

# distrobox, ffmpeg and pam-u2f already ship in silverblue-main (dnf5 skips them).
# Its multimedia stack comes from negativo17, so the RPM Fusion *-freeworld
# packages from the host are not used: gstreamer1-plugins-bad/-ugly below are
# the negativo17 equivalents (they replace the -free variants), and there is
# no negativo17 equivalent of mesa-va-drivers-freeworld.
dnf5 install -y \
    gstreamer1-plugins-bad gstreamer1-plugins-ugly \
    niri noctalia \
    libvirt qemu-kvm \
    fuse-libs pam-u2f snapper steam-devices tailscale \
    cockpit cockpit-machines cockpit-podman cockpit-storaged \
    cockpit-networkmanager cockpit-ostree cockpit-selinux cockpit-files \
    cockpit-packagekit cockpit-sosreport cockpit-kdump

dnf5 group install -y development-tools

# Remove the Firefox RPM (use a Flatpak browser instead), only if the base still ships it
for pkg in firefox firefox-langpacks; do
    if rpm -q "$pkg" &>/dev/null; then
        dnf5 remove -y "$pkg"
    fi
done

# Use a COPR Example:
#
# dnf5 -y copr enable ublue-os/staging
# dnf5 -y install package
# Disable COPRs so they don't end up enabled on the final image:
# dnf5 -y copr disable ublue-os/staging

#### Example for enabling a System Unit File

systemctl enable podman.socket
systemctl enable tailscaled
systemctl enable cockpit.socket
