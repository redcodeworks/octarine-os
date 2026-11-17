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
# the NVIDIA variant (<name>-nvidia, built on request from the same files) and the developer image (<name>-dx, built from
# the published default image) and the NVIDIA developer image (<name>-nvidia-dx, the dx layer on the NVIDIA variant) all
# get a rule for ALL SEVEN repositories (the fifth is the gamer variant <name>-gx, the sixth <name>-nvidia-gx, the gx layer on the NVIDIA variant, the seventh <name>-dx-gx, the experimental gx layer on the dx image (alias `fx` in switch-image is no repository): their rules make a machine that boots
# this image able to switch to it later), so a machine on any of them can switch to another with
# --enforce-container-sigpolicy. A machine can switch to a repository only once it has booted an image that carries its rule.
if [[ -n "${IMAGE_ORG:-}" && -n "${IMAGE_NAME:-}" && -f /ctx/cosign.pub ]]; then
    org="${IMAGE_ORG,,}"
    name="${IMAGE_NAME,,}"
    base_name="${name%-dx}"
    base_name="${base_name%-gx}"
    base_name="${base_name%-nvidia}"
    refs="ghcr.io/${org}/${base_name} ghcr.io/${org}/${base_name}-nvidia ghcr.io/${org}/${base_name}-dx ghcr.io/${org}/${base_name}-nvidia-dx ghcr.io/${org}/${base_name}-gx ghcr.io/${org}/${base_name}-nvidia-gx ghcr.io/${org}/${base_name}-dx-gx"
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

# The package lists are not in this repository: they are the `packages/` directory of the pinned octarine-bins image (bind-mounted at /binaries by the Containerfile,
# the same mount the binaries come from), installed by that image's own installer, /binaries/packages/install.sh (the contract is in octarine-bins's CLAUDE.md,
# "The package lists"). In order: required-fedora (ONE strict dnf5 transaction: a name dnf5 cannot find fails the build, so a release difference stops the build
# instead of shipping an image without something that must be there), then the optional lists (optional-fedora, optional-negativo17: best effort, one transaction per
# file, retried once as a whole, then package by package). What still cannot be installed is printed as "OPTIONAL PACKAGE MISSING: <name>" and appended to
# /usr/share/octarine-os/optional-packages-missing (the file exists in every image, possibly empty); the smoke test turns each entry into a CI warning. A missing
# optional package never fails the build, except niri and noctalia (check_session_packages below).
#
# What stays here, because it is the OS's policy and not a list: the niri/noctalia hard failure, the smoke test's check that every REQUIRED package has the RPM
# vendor "Fedora Project" (a package from outside Fedora's own repositories, negativo17, COPR or a vendor repository, may only be in an optional list, or be a
# decision of the owner for a required-negativo17/copr file of a variant), validate-repos.sh (every enabled repository must be one the base enables), and the zsh step.
# Packages can come from any ENABLED yum repo of the image: Fedora's own, negativo17 (fedora-multimedia, disabled in the base, which the installer enables for its
# own calls only) and the base's akmods COPR. No RPM Fusion repository is installed in the base.
echo "::group::Packages: the lists of the octarine-bins image"
test -f /binaries/packages/install.sh
mkdir -p /usr/share/octarine-os
missing_file=/usr/share/octarine-os/optional-packages-missing
: > "${missing_file}"
# NO_CLEANUP: the dnf caches are cache mounts and final-cleanup.sh runs at the end; the removal of gnome-software below still needs dnf5
MISSING_FILE="${missing_file}" NO_CLEANUP=1 bash /binaries/packages/install.sh
echo "::endgroup::"

# zsh is installed but NOT the default login shell of new users (/etc/default/useradd stays as packaged). Choosing it
# is opt-in through the shell step of `ujust user-setup`, which needs zsh listed in /etc/shells.
echo "::group::Packages: zsh and the session packages"
if grep -qx 'SHELL=/usr/bin/zsh' /etc/default/useradd; then echo "ERROR: zsh must not be the default shell"; exit 1; fi
grep -qx /usr/bin/zsh /etc/shells || echo /usr/bin/zsh >> /etc/shells

# The session packages are not optional in practice: an image without niri or noctalia is a broken image, so a build that lost them FAILS (a coming Fedora that no longer has
# them fails here too, which is what it is for). The rest of the optional lists stays soft.
check_session_packages() {
    local pkg
    for pkg in niri noctalia; do
        if grep -qx "${pkg}" "${missing_file}"; then echo "ERROR: the session package ${pkg} is missing after the retries: failing the build instead of shipping an image without it"; exit 1; fi
    done
}
echo "== optional packages missing:"
cat "${missing_file}"
check_session_packages
echo "::endgroup::"

# Beyond the compilers and linker (the required list of octarine-bins) there are no build tools here (cmake, ninja, meson, the development-tools
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

# The local SELinux module (system_files/usr/share/octarine-os/selinux/octarine-local.cil: three narrow rules, the reasons and the upstream references are
# in the file). It goes in AFTER every package step: the rules name types of pcp and tuned, so the install fails when those packages (or a renamed type)
# are not there, and that failure is meant to fail the build (set -e, no `|| true`). semodule writes the module into the policy store, /etc/selinux/targeted/active
# (priority 400), which the image carries as /usr/etc.
echo "::group::SELinux: local policy module"
semodule -i /usr/share/octarine-os/selinux/octarine-local.cil
modules=$(semodule -l)
grep -qx 'octarine-local' <<< "${modules}" || { echo "ERROR: semodule -i succeeded but octarine-local is not listed"; exit 1; }
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
# The signed files-only octarine-bins image (built by the octarine-bins repository), pinned by digest in the Containerfile and bind-mounted
# at /binaries; install-binaries.sh installs them (checks, layout and licenses are described there). Installed only:
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
