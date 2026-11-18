#!/usr/bin/bash
# Derived from ublue-os/bluefin build_files/base/17-cleanup.sh (Apache-2.0, https://github.com/ublue-os/bluefin); modified for octarine-os.
# Deviation: Bluefin enables its systemd units and disables third-party repos here. Ours enables only what runs by default; the
# repository check is validate-repos.sh (an allow-list, called by build.sh) and the /var, /boot and /tmp cleanup is final-cleanup.sh.

echo "::group:: ===$(basename "$0")==="

set -eoux pipefail


# Only what has to run by default. sshd, tailscaled, cockpit.socket and the snapper
# timers are installed but left off; enable them on demand, e.g.
#   sudo systemctl enable --now tailscaled
# The VM-hosting set (libvirt, QEMU, cockpit-machines) is not in this image; the dx variant installs it and relies on
# libvirt's packaged presets and socket activation. The base image already enables automatic update staging (rpm-ostreed-automatic.timer).
# The Flatpak preinstall list is installed by `ujust flatpak-preinstall` from a desktop session, not by a boot unit:
# a root service has no session bus, and on a stock-installed machine the fedora OCI remote needs one.

# pcp is an optional package: enable its units only when it was installed
if rpm -q pcp &>/dev/null; then
    systemctl enable pmcd.service pmlogger.service
fi

# Homebrew (files from the pinned ublue-os/brew image, copied in by the Containerfile). The first-boot
# extraction (brew-setup, skipped when a prefix exists) and the 6-hourly `brew update` are on; the 8-hourly
# `brew upgrade` timer is off, because upgrades stay under the owner's soak policy. The presets come from
# 01-homebrew.preset (enable all three) and our 00-octarine-brew.preset (disable the upgrade timer; the
# lowest file name wins in systemd presets).
systemctl preset brew-setup.service brew-update.timer brew-upgrade.timer

# Rootless Podman API socket for every user (socket-activated, so it costs nothing until used)
systemctl --global enable podman.socket

# The base image enables mcelog. It is no longer masked for everybody: the packaged unit skips itself without /dev/mcelog
# and when edac_mce_amd is loaded, and our drop-in (50-octarine-intel-only.conf) skips it on any non-Intel CPU, so AMD machines
# get no failed unit and Intel machines keep machine-check logging.

echo "::endgroup::"
