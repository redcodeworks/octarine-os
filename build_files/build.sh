#!/bin/bash

set -ouex pipefail

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
    fuse-libs pam-u2f snapper btrfs-assistant steam-devices tailscale \
    cockpit cockpit-machines cockpit-podman cockpit-storaged \
    cockpit-networkmanager cockpit-ostree cockpit-selinux cockpit-files \
    cockpit-packagekit cockpit-sosreport cockpit-kdump \
    pcp python3-pcp \
    powertop iotop-c lm_sensors usbip \
    gnome-shell-extension-gsconnect nautilus-gsconnect nautilus-python \
    podman-compose kind podman-docker podman-tui \
    borgbackup restic rclone socat wtype \
    rocm-hip rocm-opencl rocm-smi rocminfo hipcc \
    gcc-c++ cmake ninja-build meson uv \
    guestfs-tools libguestfs libguestfs-xfs virt-v2v

dnf5 group install -y development-tools

# Remove RPMs the base ships that this image replaces, only if they are still present:
# Firefox (use the Flatpak) and toolbox (distrobox covers it)
for pkg in firefox firefox-langpacks toolbox; do
    if rpm -q "$pkg" &>/dev/null; then
        dnf5 remove -y "$pkg"
    fi
done

### Themes: Gruvbox Material (GTK3, GTK4) from github.com/redcodeworks/gnome-themes, pinned to a commit
# Bump GNOME_THEMES_REF to take a newer revision (git log in that repo). A failure here fails the build on
# purpose: shipping an image without its theme would be a visible regression. Installed as real files
# into /usr/share/themes. Flatpak apps cannot see the host's /usr/share/themes: for them, clone the repo and
# run `just pick` there (needs only just; copies the themes you choose into ~/.themes). The GNOME Shell
# themes still come from system_files/ until the repo's stock-based Shell themes are pinned here.
GNOME_THEMES_REF=9a123105003b6caba7a1bcf7b41d4443f7c71edf
themes_tmp="$(mktemp -d)"
git clone --quiet https://github.com/redcodeworks/gnome-themes.git "${themes_tmp}"
git -C "${themes_tmp}" checkout --quiet "${GNOME_THEMES_REF}"
cp -a "${themes_tmp}/gruvbox-material/themes/." /usr/share/themes/
rm -rf "${themes_tmp}"
test -f /usr/share/themes/Gruvbox-Material/gtk-3.0/gtk-dark.css
test -f /usr/share/themes/Gruvbox-Material/gtk-4.0/gtk-dark.css

### Papirus icon theme (Fedora packages). Optional: a failure here must not block the build.
dnf5 install -y --skip-unavailable papirus-icon-theme papirus-icon-theme-dark \
    || echo "WARNING: papirus-icon-theme could not be installed; continuing without it"
[ -d /usr/share/icons/Papirus-Dark ] || echo "WARNING: Papirus-Dark is not present in the image"

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
