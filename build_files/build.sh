#!/bin/bash

set -ouex pipefail

# Which Fedora release is the base image? The log must say what this build started from.
echo "== base image os-release"
cat /usr/lib/os-release

# --- Guard: refuse to build if secrets or personal key material ended up in system_files ---
# A security key registration (pam_u2f's u2f_keys) or a private key copied here would be baked into a
# public image. Check names first, then content (this also catches a renamed copy).
forbidden=$(find /ctx/system_files \( -name 'u2f_keys' -o -name 'u2f_mappings' -o -name 'Yubico' \
    -o -name '*.key' -o -name '*.p12' -o -name '*.pfx' -o -name 'id_rsa*' -o -name 'id_ed25519*' \
    -o -name 'id_ecdsa*' -o -name 'authorized_keys' -o -name '.env' \) -print)
forbidden+=$'\n'$(grep -rIlE -e '-----BEGIN [A-Z ]*PRIVATE KEY-----' \
    -e ',(es256|eddsa|rs256),\+?(presence|verification|pin)?' /ctx/system_files || true)
forbidden=$(echo "$forbidden" | sed '/^$/d')
if [[ -n "$forbidden" ]]; then
    echo "Refusing to build: sensitive files found in system_files:" >&2
    echo "$forbidden" >&2
    exit 1
fi

# Copy the contents of system_files/ of the git repo to /
cp -avf "/ctx/system_files"/. /

# sudo ignores sudoers.d files that are not mode 0440; git does not track modes
chmod 0440 /etc/sudoers.d/10-timestamp-timeout
visudo -c

# --- Container signature policy for this image's own registry path ---
# Needs IMAGE_ORG and IMAGE_NAME (Containerfile build args) and cosign.pub from the repo root.
# Everything is derived from them, so a fork only changes image-template.env and cosign.pub.
if [[ -n "${IMAGE_ORG:-}" && -n "${IMAGE_NAME:-}" && -f /ctx/cosign.pub ]]; then
    org="${IMAGE_ORG,,}"
    name="${IMAGE_NAME,,}"
    ref="ghcr.io/${org}/${name}"
    key="/etc/pki/containers/${org}-${name}.pub"
    install -Dm644 /ctx/cosign.pub "${key}"
    printf 'docker:\n  ghcr.io/%s:\n    use-sigstore-attachments: true\n' "${org}" \
        >"/etc/containers/registries.d/${org}-${name}.yaml"
    python3 - "${ref}" "${key}" <<'PY'
import json
import sys

ref, key = sys.argv[1], sys.argv[2]
path = "/etc/containers/policy.json"
policy = json.load(open(path))
scopes = policy["transports"]["docker"]
catch_all = scopes.pop("", None)
scopes[ref] = [{"type": "sigstoreSigned", "keyPath": key, "signedIdentity": {"type": "matchRepository"}}]
if catch_all is not None:
    scopes[""] = catch_all
with open(path, "w") as f:
    json.dump(policy, f, indent=4)
    f.write("\n")
PY
else
    echo "IMAGE_ORG, IMAGE_NAME or cosign.pub missing: not adding a signature policy for this image"
fi
# --- end signature policy ---

### Install packages
#
# Release-specific parts of this script (the base tag in the Containerfile decides the Fedora release):
# the package names below, since a package can be renamed, retired or not yet built for a release
# (niri, noctalia, btrfs-assistant, the rocm-*/hipcc set, the cockpit-* modules, usbip, nautilus-python
# and the gnome-shell-extension-* names are the likeliest); the negativo17 gstreamer replacement of the
# -free variants; and the removal list further down. dnf5 stops with an error on a name it cannot find
# (no --skip-unavailable here) and the smoke test checks the results, so a release difference should
# fail the build instead of shipping an image without something.

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
    niri noctalia fish \
    libvirt qemu-kvm \
    fuse-libs pam-u2f snapper btrfs-assistant steam-devices tailscale \
    cockpit cockpit-machines cockpit-podman cockpit-storaged \
    cockpit-networkmanager cockpit-ostree cockpit-selinux cockpit-files \
    cockpit-packagekit cockpit-sosreport cockpit-kdump \
    pcp python3-pcp \
    powertop iotop-c lm_sensors usbip \
    gnome-shell-extension-gsconnect gnome-shell-extension-user-theme \
    nautilus-gsconnect nautilus-python \
    podman-compose kind podman-docker podman-tui \
    borgbackup restic rclone socat wtype \
    rocm-hip rocm-opencl rocm-smi rocminfo hipcc \
    guestfs-tools libguestfs libguestfs-xfs virt-v2v

# No compilers or build tools (gcc, make, cmake, ninja, meson, the development-tools group):
# builds happen in the fedora-toolbox distrobox, created by `ujust toolbox dev-toolbox` from
# /usr/share/ublue-os/distrobox/dev-toolbox.ini. Nothing here compiles from source.

# Remove RPMs the base ships that this image replaces, only if they are still present:
# Firefox (use the Flatpak) and toolbox (distrobox covers it)
for pkg in firefox firefox-langpacks toolbox; do
    if rpm -q "$pkg" &>/dev/null; then
        dnf5 remove -y "$pkg"
    fi
done

# gnome-software: Bazaar (a preinstalled Flatpak) is the software centre; fwupd and PackageKit stay, so
# firmware updates remain available through `fwupdmgr`. Preview the transaction first and fail the build if it
# would take anything from the protected list with it (the single place that list lives).
PROTECTED_PKGS="gnome-shell nautilus fwupd flatpak PackageKit gdm gnome-control-center gnome-session-wayland-session ostree rpm-ostree bootc podman systemd"
if rpm -q gnome-software &>/dev/null; then
    plan=$(dnf5 remove --assumeno gnome-software 2>&1 || true)
    echo "== gnome-software removal transaction"
    echo "${plan}"
    grep -Eq '^[[:space:]]*gnome-software[[:space:]]' <<< "${plan}" || { echo "ERROR: the removal preview does not list gnome-software"; exit 1; }
    for pkg in ${PROTECTED_PKGS}; do
        if grep -Eq "^[[:space:]]*${pkg}[[:space:]]" <<< "${plan}"; then
            echo "ERROR: removing gnome-software would also remove protected package ${pkg}"
            exit 1
        fi
    done
    dnf5 remove -y gnome-software
fi

# Name shown by the OS (GRUB, login screen, About). Only PRETTY_NAME changes: ID, NAME and
# VERSION_ID stay as they are, because update tooling and third-party software read them.
sed -i 's/^PRETTY_NAME=.*/PRETTY_NAME="Octarine_OS"/' /usr/lib/os-release
grep -qx 'PRETTY_NAME="Octarine_OS"' /usr/lib/os-release
echo "== resulting os-release"
cat /usr/lib/os-release

### Themes and icons are NOT part of the image: install them per user from their own repos with
# `ujust gnome-themes install-themes` / `install-icons` (github.com/redcodeworks/gnome-themes).

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

# Homebrew (files from the pinned ublue-os/brew image, copied in by the Containerfile). The first-boot
# extraction (brew-setup, skipped when a prefix exists) and the 6-hourly `brew update` are on; the 8-hourly
# `brew upgrade` timer is off, because upgrades stay under the owner's soak policy. The presets come from
# 01-homebrew.preset (enable all three) and our 00-octarine-brew.preset (disable the upgrade timer; the
# lowest file name wins in systemd presets).
systemctl preset brew-setup.service brew-update.timer brew-upgrade.timer

# Rootless Podman API socket for every user (socket-activated, so it costs nothing until used)
systemctl --global enable podman.socket

# The base image enables mcelog, which is useless on AMD CPUs (masked on the host too)
systemctl mask mcelog.service
