#!/usr/bin/bash
# Derived from ublue-os/bluefin build_files/base/04-packages.sh (Apache-2.0, https://github.com/ublue-os/bluefin); modified for octarine-os.
# Deviation: Bluefin lists its Fedora and COPR packages here. Ours come from the pinned octarine-bins image (its own installer runs
# below), so there are no package arrays in this file; the zsh and session checks and the removal of base packages stay ours.

echo "::group:: ===$(basename "$0")==="

set -ouex pipefail

# All DNF-related operations should be done here whenever possible

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

test -f /binaries/packages/install.sh
mkdir -p /usr/share/octarine-os
missing_file=/usr/share/octarine-os/optional-packages-missing
: > "${missing_file}"
# NO_CLEANUP: the dnf caches are cache mounts and final-cleanup.sh runs at the end; the removal of gnome-software below still needs dnf5
MISSING_FILE="${missing_file}" NO_CLEANUP=1 bash /binaries/packages/install.sh

# zsh is installed but NOT the default login shell of new users (/etc/default/useradd stays as packaged). Choosing it
# is opt-in through the shell step of `ujust user-setup`, which needs zsh listed in /etc/shells.
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

# Beyond the compilers and linker (the required list of octarine-bins) there are no build tools here (cmake, ninja, meson, the development-tools
# group): bigger builds happen in the fedora-toolbox distrobox, created by `ujust toolbox dev-toolbox` from
# /usr/share/ublue-os/distrobox/dev-toolbox.ini (or on the dx image). Nothing in this build compiles from source.

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
