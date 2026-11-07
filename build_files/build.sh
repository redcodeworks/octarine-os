#!/bin/bash

set -ouex pipefail

# Copy the contents of system_files/ of the git repo to /
cp -avf "/ctx/system_files"/. /

# sudo ignores sudoers.d files that are not mode 0440; git does not track modes
chmod 0440 /etc/sudoers.d/10-timestamp-timeout
visudo -c

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
    cockpit-packagekit cockpit-sosreport cockpit-kdump \
    pcp python3-pcp \
    powertop iotop-c lm_sensors usbip \
    nautilus-gsconnect nautilus-python \
    podman-compose kind podman-docker podman-tui \
    borgbackup restic rclone socat wtype \
    rocm-hip rocm-opencl rocm-smi rocminfo hipcc \
    gnome-shell-extension-caffeine gnome-shell-extension-user-theme \
    gnome-shell-extension-appindicator gnome-shell-extension-dash-to-dock \
    gnome-shell-extension-blur-my-shell gnome-shell-extension-gsconnect \
    gnome-shell-extension-auto-move-windows

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

# Only what has to run by default. sshd, tailscaled, cockpit.socket and the snapper
# timers are installed but left off; enable them on demand, e.g.
#   sudo systemctl enable --now tailscaled
# libvirt relies on its packaged presets and socket activation, and the base image
# already enables automatic update staging (rpm-ostreed-automatic.timer).
systemctl enable \
    pmcd.service pmlogger.service \
    flatpak-preinstall.service

# Rootless Podman API socket for every user (socket-activated, so it costs nothing until used)
systemctl --global enable podman.socket

# The base image enables mcelog, which is useless on AMD CPUs (masked on the host too)
systemctl mask mcelog.service
