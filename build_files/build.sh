#!/bin/bash

set -ouex pipefail

# Log sections: every step below sits in a "::group::" ... "::endgroup::" pair, which GitHub Actions folds in the build log (anywhere
# else it is just a line of text). Groups are never nested (Actions does not nest them), so the scripts this one runs print their own
# and are called between two of ours. When the build fails inside a group, this trap closes it and prints an "::error::" line outside
# it, so the failure is not folded away (the exit status is unchanged).
trap 'rc=$?; if (( rc != 0 )); then echo "::endgroup::"; echo "::error::build.sh failed (exit ${rc})"; fi' EXIT

# Which Fedora release is the base image? The log must say what this build started from.
echo "::group::Base image"
echo "== base image os-release"
cat /usr/lib/os-release
echo "::endgroup::"

# --- Guard: refuse to build if secrets or personal key material ended up in system_files ---
echo "::group::Guard: secrets in system_files"
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
echo "::endgroup::"

echo "::group::System files"

# Base recipe files that our own file of the same name wraps: keep the base copy as <name>-base.just. Our file imports it and
# overrides single recipes (between two imported files the FIRST import wins, so a later file could not override them).
# A missing base file fails the build, which is the signal that the base changed its layout.
for f in 00-default 10-update 30-distrobox; do
    mv "/usr/share/ublue-os/just/${f}.just" "/usr/share/ublue-os/just/${f}-base.just"
done

# Copy the contents of system_files/ of the git repo to /
cp -avf "/ctx/system_files"/. /

# Our 15-luks.just, 40-nvidia.just and 50-akmods.just overwrite the base files of the same name (only 00-default, 10-update and
# 30-distrobox are renamed and imported). The base's toggle-nvk (builds image names that do not exist, rebases without the
# signature policy) lived in 40-nvidia.just: it must be gone.
if grep -rqE '^toggle-nvk' /usr/share/ublue-os/just/; then echo "ERROR: the base toggle-nvk recipe is still installed"; exit 1; fi

# sudo ignores sudoers.d files that are not mode 0440; git does not track modes
chmod 0440 /etc/sudoers.d/10-timestamp-timeout
visudo -c

# System-wide GNOME defaults: compile the keyfiles in /etc/dconf/db/*.d (ours is distro.d/90-octarine-os) into the binary
# databases dconf reads. /etc/dconf/profile/user already lists system-db:distro after the user database, so a user's
# own setting always wins. A bad keyfile makes dconf exit non-zero and fails the build (set -e).
dconf update
test /etc/dconf/db/distro -nt /etc/dconf/db/distro.d/90-octarine-os
echo "::endgroup::"

# --- Container signature policy for this image's registry path and its sibling ---
echo "::group::Container signature policy"
# Needs IMAGE_ORG and IMAGE_NAME (Containerfile build args) and cosign.pub from the repo root.
# Everything is derived from them, so a fork only changes config/image.env and cosign.pub. The default image and
# the NVIDIA variant (<name>-nvidia, built weekly from the same files) and the developer image (<name>-dx, built from
# the published default image) and the NVIDIA developer image (<name>-nvidia-dx, the dx layer on the NVIDIA variant) all
# get a rule for ALL FOUR repositories, so a machine on any of them can switch to another with
# --enforce-container-sigpolicy. A machine can switch to a repository only once it has booted an image that carries its rule.
if [[ -n "${IMAGE_ORG:-}" && -n "${IMAGE_NAME:-}" && -f /ctx/cosign.pub ]]; then
    org="${IMAGE_ORG,,}"
    name="${IMAGE_NAME,,}"
    base_name="${name%-dx}"
    base_name="${base_name%-nvidia}"
    refs="ghcr.io/${org}/${base_name} ghcr.io/${org}/${base_name}-nvidia ghcr.io/${org}/${base_name}-dx ghcr.io/${org}/${base_name}-nvidia-dx"
    key="/etc/pki/containers/${org}-${name}.pub"
    install -Dm644 /ctx/cosign.pub "${key}"
    printf 'docker:\n  ghcr.io/%s:\n    use-sigstore-attachments: true\n' "${org}" \
        >"/etc/containers/registries.d/${org}-${name}.yaml"
    python3 - "${key}" ${refs} <<'PY'
import json
import sys

key, refs = sys.argv[1], sys.argv[2:]
path = "/etc/containers/policy.json"
policy = json.load(open(path))
scopes = policy["transports"]["docker"]
catch_all = scopes.pop("", None)
for ref in refs:
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
echo "::endgroup::"

### Install packages

#
# Release-specific parts of this script (the base tag in the Containerfile decides the Fedora release):
# the package names below, since a package can be renamed, retired or not yet built for a release
# (niri, noctalia, btrfs-assistant, the cockpit-* modules, usbip, nautilus-python
# and the gnome-shell-extension-* names are the likeliest); the negativo17 gstreamer replacement of the
# -free variants; and the removal list further down.
#
# Two tiers. CRITICAL packages go in one dnf5 transaction without --skip-unavailable: dnf5 stops with an
# error on a name it cannot find, so a release difference fails the build instead of shipping an image
# without something that must be there (the smoke test checks them again). OPTIONAL packages are installed
# afterwards, one transaction per group; dnf5 transactions are atomic, so a failed group changes nothing
# (and a dependency that would conflict with a critical package fails the group instead of replacing it).
# When a group fails its packages are retried one by one, and whatever still cannot be installed is
# listed in /usr/share/octarine-os/optional-packages-missing (one name per line, the file exists in every
# image, possibly empty), printed as "OPTIONAL PACKAGE MISSING: <name>", and the smoke test turns each
# entry into a CI warning. A missing optional package never fails the build.
#
# Standing policy: a package from outside Fedora's own repositories (negativo17, RPM Fusion, COPR, vendor
# repos) may only be installed in an optional group, never in the critical transaction. The smoke test
# enforces it: every critical package must have the RPM vendor "Fedora Project", else the build fails
# naming the package. Optional packages are exempt.
#
# fish is optional: nothing in the image depends on it and it is never a login shell (bash stays the login
# shell; zsh is installed but opt-in: `ujust user-setup` offers it). A user who configures their own terminal to
# start fish needs it installed, which is their own setting.

# Packages can be installed from any enabled yum repo on the image.
# RPMfusion repos are available by default in ublue main images
# List of rpmfusion packages can be found here:
# https://mirrors.rpmfusion.org/mirrorlist?path=free/fedora/updates/<release>/x86_64/repoview/index.html&protocol=https&redirect=1

# distrobox, ffmpeg, pam-u2f and solaar-udev already ship in silverblue-main (dnf5 skips them; solaar-udev is listed anyway so it stays
# if the base drops it). solaar (the Logitech device manager, GTK, Python) is the new one: 5.7 MiB plus three small Python dependencies.
# Its multimedia stack comes from negativo17, so the RPM Fusion *-freeworld
# packages from the host are not used: gstreamer1-plugins-bad/-ugly (group `codecs`, optional because they
# come from negativo17) are the negativo17 equivalents and replace the base's -free variants. They are
# optional, so a failed transaction leaves the -free GStreamer packages in place (dnf5 is atomic). There
# is no negativo17 equivalent of mesa-va-drivers-freeworld.
#
# gcc, gcc-c++, make and binutils (the linker ld, ar, as) are in the critical tier since 2026-11-14 (the owner's decision: compilers
# and a linker are useful on any image, not only on a developer one; Bluefin's list is gcc, gcc-c++ and make). binutils is already in
# the base and a dependency of gcc; it is named anyway so it stays when the base drops it. dnf5 adds glibc-devel, libstdc++-devel,
# libxcrypt-devel and kernel-headers as dependencies. The dx and NVIDIA dx images inherit them (the dx layer installs the shared
# developer list on top; dnf5 skips what is already installed). cmake, ninja, meson and the development-tools group are still not here.
#
# CRITICAL (keep in step with the smoke tests in .github/workflows/build.yml; tests/compilers.sh checks it):
echo "::group::Packages: critical"
dnf5 install -y \
    pam-u2f snapper fuse-libs tailscale \
    gnome-shell-extension-user-theme borgbackup steam-devices zsh jq skopeo solaar solaar-udev \
    gcc gcc-c++ make binutils

# zsh is installed but NOT the default login shell of new users (/etc/default/useradd stays as packaged). Choosing it
# is opt-in through the shell step of `ujust user-setup`, which needs zsh listed in /etc/shells.
if grep -qx 'SHELL=/usr/bin/zsh' /etc/default/useradd; then echo "ERROR: zsh must not be the default shell"; exit 1; fi
grep -qx /usr/bin/zsh /etc/shells || echo /usr/bin/zsh >> /etc/shells
echo "::endgroup::"

# OPTIONAL packages, in separate dnf5 transactions BY SOURCE, each in its own log group (policy; the owner, 2026-11-16):
#   (a) Fedora critical: above, one transaction, a missing name fails the build.
#   (b) Fedora optional groups: one transaction per group, from Fedora's own repositories.
#   (c) trusted third party (negativo17, RPM Fusion): optional groups of their own, one transaction per group.
#   (d) COPR: one transaction per COPR, `dnf5 -y copr enable <owner/project>` right before and `copr disable` right after, the package pinned to an exact
#       version-release (a COPR is not ours and floats nothing into the image), optional only. Empty today: no pin machinery until one is used.
# Fedora and trusted third party float; any other COPR or vendor repository is pinned and optional only (validate-repos.sh fails the build on an
# enabled repository it does not know).
mkdir -p /usr/share/octarine-os
missing_file=/usr/share/octarine-os/optional-packages-missing
: > "${missing_file}"

# --- optional install functions (tests/optional-packages.sh cuts this block out of the script) ---
# <label> <group> <package>...: one transaction for the group. When it fails, once more as a whole, then its packages one by one;
# what still cannot be installed is listed in the missing file. Never fails the build.
install_optional() {
    local label=$1 group=$2; shift 2
    local pkgs=("$@") pkg
    echo "::group::Packages: ${label} ${group}"
    if dnf5 install -y "${pkgs[@]}"; then
        echo "::endgroup::"
        return 0
    fi
    # one more try of the WHOLE group first: a mirror hiccup should not leave the image without its packages for up to a week (SCHEDULED_REBUILD_MAX_AGE_DAYS)
    echo "WARNING: optional group ${group} failed, retrying it once as a whole"
    sleep 20
    dnf5 clean expire-cache > /dev/null 2>&1 || true
    if dnf5 install -y "${pkgs[@]}"; then
        echo "::endgroup::"
        return 0
    fi
    echo "WARNING: optional group ${group} failed as a whole twice, retrying its packages one by one"
    for pkg in "${pkgs[@]}"; do
        if ! dnf5 install -y "${pkg}"; then
            echo "${pkg}" >> "${missing_file}"
            echo "OPTIONAL PACKAGE MISSING: ${pkg}"
        fi
    done
    echo "::endgroup::"
}
# <label> "<group>:<space separated packages>"...: one install_optional transaction per entry
install_optional_groups() {
    local label=$1 entry pkgs; shift
    for entry in "$@"; do
        read -r -a pkgs <<< "${entry#*:}"
        install_optional "${label}" "${entry%%:*}" "${pkgs[@]}"
    done
}
# The session packages are not optional in practice: an image without niri or noctalia is a broken image, so a build that lost them FAILS (a coming Fedora that no longer has
# them fails here too, which is what it is for). The rest of the list stays soft.
check_session_packages() {
    local pkg
    for pkg in niri noctalia; do
        if grep -qx "${pkg}" "${missing_file}"; then echo "ERROR: the session package ${pkg} is missing after the retries: failing the build instead of shipping an image without it"; exit 1; fi
    done
}
# --- end optional install functions ---

# (b) Fedora optional groups
fedora_optional_groups=(
    "misc:fish gum niri noctalia btrfs-assistant nautilus-python wtype socat gnome-shell-extension-gsconnect gnome-shell-extension-appindicator gnome-shell-extension-auto-move-windows gnome-shell-extension-caffeine gnome-shell-extension-dash-to-dock gpaste gnome-shell-extension-gpaste nautilus-gsconnect powertop iotop-c lm_sensors usbip restic rclone gtk4-layer-shell"
    "cockpit:cockpit cockpit-podman cockpit-storaged cockpit-networkmanager cockpit-ostree cockpit-selinux cockpit-files cockpit-packagekit cockpit-sosreport cockpit-kdump"
    "pcp:pcp python3-pcp"
    "containers:podman-compose kind podman-docker podman-tui"
    "libguestfs:guestfs-tools libguestfs libguestfs-xfs virt-v2v"
)
install_optional_groups "Fedora optional group" "${fedora_optional_groups[@]}"

# (c) trusted third party. Today: the negativo17 multimedia stack (fedora-multimedia, enabled by the base), whose GStreamer plugins replace the -free variants
third_party_optional_groups=(
    "codecs:gstreamer1-plugins-bad gstreamer1-plugins-ugly"
)
install_optional_groups "Trusted third party optional group" "${third_party_optional_groups[@]}"

# (d) COPR, pinned to an exact version-release, optional only: "<owner/project>:<name>-<version>-<release>". Empty today.
#   Example: "ublue-os/staging:somepackage-1.2.3-1.fc45"
copr_optional=()
for entry in "${copr_optional[@]}"; do
    repo=${entry%%:*}
    pkg=${entry#*:}
    if dnf5 -y copr enable "${repo}"; then
        install_optional "COPR ${repo}" pinned "${pkg}"
    else
        echo "${pkg}" >> "${missing_file}"
        echo "OPTIONAL PACKAGE MISSING: ${pkg} (COPR ${repo} could not be enabled)"
    fi
    dnf5 -y copr disable "${repo}" || true
done

echo "== optional packages missing:"
cat "${missing_file}"
check_session_packages

# Beyond the compilers and linker above (critical list) there are no build tools here (cmake, ninja, meson, the development-tools
# group): bigger builds happen in the fedora-toolbox distrobox, created by `ujust toolbox dev-toolbox` from
# /usr/share/ublue-os/distrobox/dev-toolbox.ini (or on the dx image). Nothing in this build compiles from source.

echo "::group::Remove base packages"
# Remove RPMs the base ships that this image replaces, only if they are still present:
# Firefox (use the Flatpak) and toolbox (distrobox covers it)
for pkg in firefox firefox-langpacks toolbox; do
    if rpm -q "$pkg" &>/dev/null; then
        dnf5 remove -y "$pkg"
    fi
done

# gnome-software: Bazaar (a preinstalled Flatpak) is the software center; fwupd and PackageKit stay, so
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
echo "::endgroup::"

echo "::group::Branding and image identity"
# Name shown by the OS (GRUB, login screen, About). Only PRETTY_NAME changes: ID, NAME and
# VERSION_ID stay as they are, because update tooling and third-party software read them.
sed -i 's/^PRETTY_NAME=.*/PRETTY_NAME="octarineOS"/' /usr/lib/os-release
grep -qx 'PRETTY_NAME="octarineOS"' /usr/lib/os-release

# Image identity: IMAGE_ID and IMAGE_VERSION (the fields os-release(5) defines for this). The version is the build's own
# channel-neutral one (<YYYYMMDD>-<short sha>, passed in by `just build`), the same string as the OCI version label; a promoted image (testing -> latest) is the same
# image, so it keeps exactly these fields.
set_os_release_field() { # key value: replace the line when it exists, append it otherwise
    local key="$1" value="$2" file="${OS_RELEASE_FILE:-/usr/lib/os-release}"  # the override is for tests
    if grep -q "^${key}=" "${file}"; then
        sed -i "s|^${key}=.*|${key}=\"${value}\"|" "${file}"
    else
        [[ -z "$(tail -c1 "${file}")" ]] || echo >> "${file}"
        echo "${key}=\"${value}\"" >> "${file}"
    fi
    grep -qx "${key}=\"${value}\"" "${file}"
}
set_os_release_field IMAGE_ID octarine-os
set_os_release_field IMAGE_VERSION "${IMAGE_VERSION:-unknown}"
bash -c '. /usr/lib/os-release && [[ "${IMAGE_ID}" == octarine-os ]]'
echo "== resulting os-release"
cat /usr/lib/os-release

# --- Branding: logo on the GDM login screen and the Plymouth boot screen ---
# GDM: system_files ships zz-octarine-login-screen.gschema.override; compile the schemas so it takes effect.
# glib-compile-schemas exits non-zero on a bad override (set -e fails the build).
glib-compile-schemas /usr/share/glib-2.0/schemas
test "$(GSETTINGS_BACKEND=memory gsettings --schemadir /usr/share/glib-2.0/schemas get org.gnome.login-screen logo)" \
    = "'/usr/share/octarine-os/logo/octarine-logo.png'"

# Plymouth: own theme "octarine" = bgrt (firmware logo plus spinner) with our watermark. The spinner assets are
# copied from the installed spinner theme (not vendored); the fedora-logos package file stays untouched.
theme=/usr/share/plymouth/themes/octarine
rm -rf "${theme}"
mkdir -p "${theme}"
cp -a /usr/share/plymouth/themes/spinner/. "${theme}/"
rm -f "${theme}/spinner.plymouth"
install -m644 /usr/share/octarine-os/logo/octarine-logo.png "${theme}/watermark.png"
sed -e '/^Name\[/d' -e 's/^Name=.*/Name=Octarine/' \
    -e "s#^ImageDir=.*#ImageDir=${theme}#" \
    /usr/share/plymouth/themes/bgrt/bgrt.plymouth >"${theme}/octarine.plymouth"
grep -qx "ImageDir=${theme}" "${theme}/octarine.plymouth"
grep -qx 'ModuleName=two-step' "${theme}/octarine.plymouth"
grep -qx 'Theme=octarine' /etc/plymouth/plymouthd.conf

# The initramfs carries the Plymouth theme (boot and LUKS passphrase screens), so regenerate it for the image's
# kernel, the way Universal Blue images do (dracut with the ostree module). Riskiest step: CI cannot boot it.
test "$(ls /usr/lib/modules | wc -l)" = 1
kver=$(ls /usr/lib/modules)
DRACUT_NO_XATTR=1 dracut --no-hostonly --kver "${kver}" --reproducible -v --add ostree \
    -f "/usr/lib/modules/${kver}/initramfs.img"
chmod 0600 "/usr/lib/modules/${kver}/initramfs.img"
lsinitrd "/usr/lib/modules/${kver}/initramfs.img" | grep -F 'usr/share/plymouth/themes/octarine/watermark.png'
# --- end branding ---
echo "::endgroup::"

# --- Prebuilt binaries: sched_ext schedulers and the extest libraries (the two scripts print their own log groups) ---
# Two signed files-only images from the fedora-toolbox repository, pinned by digest in the Containerfile and bind-mounted
# at /binaries/<name> (the image pinned by digest in the Containerfile); install-binaries.sh installs them (checks, layout and licenses are described there). Installed only:
# no unit, no preset, nothing is started.
/ctx/install-binaries.sh

# The sched_ext scheduler registry and unit drop-ins, generated from the manifest that install-binaries.sh just installed
# (scx@.service, its helpers and the polkit rule come from system_files). Nothing is enabled: the preset says disable.
/ctx/gen-schedulers.sh
echo "::group::Checks of the scheduler files"
for f in scx-preflight scx-wait-idle scx-run scx-verify gamemode-start gamemode-end; do test -x "/usr/libexec/octarine-os/${f}"; done
test -f /usr/lib/systemd/system/scx@.service
test -f /usr/share/polkit-1/rules.d/50-octarine-scx.rules
! grep -q "@INSTANCES@" /usr/share/polkit-1/rules.d/50-octarine-scx.rules
echo "::endgroup::"

### Themes and icons are NOT part of the image: install them per user from their own repos with
# `ujust gnome-candy install-theme` / `install-icon` (github.com/redcodeworks/candy-for-gnome).

#### Example for enabling a System Unit File

# Only what has to run by default. sshd, tailscaled, cockpit.socket and the snapper
# timers are installed but left off; enable them on demand, e.g.
#   sudo systemctl enable --now tailscaled
# The VM-hosting set (libvirt, QEMU, cockpit-machines) is not in this image; the dx variant installs it and relies on
# libvirt's packaged presets and socket activation. The base image already enables automatic update staging (rpm-ostreed-automatic.timer).
# The Flatpak preinstall list is installed by `ujust flatpak-preinstall` from a desktop session, not by a boot unit:
# a root service has no session bus, and on a stock-installed machine the fedora OCI remote needs one.
echo "::group::Services and presets"
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
test -f /usr/lib/systemd/system/mcelog.service.d/50-octarine-intel-only.conf
echo "::endgroup::"

# --- Every repository that is enabled must be one the base enables (see validate-repos.sh; prints its own log group) ---
/ctx/validate-repos.sh

# --- Last step: nothing in /boot, /run, /tmp or /var that `bootc container lint --fatal-warnings` objects to (see final-cleanup.sh; prints its own log group) ---
/ctx/final-cleanup.sh
