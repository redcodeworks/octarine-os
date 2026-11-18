#!/usr/bin/bash
# Derived from ublue-os/bluefin build_files/base/04-packages.sh (Apache-2.0, https://github.com/ublue-os/bluefin); modified for octarine-os.
# Deviation: Bluefin lists its Fedora and COPR packages here. Ours are plain text files in packages/default (installed by install-packages.sh,
# below), so there are no package arrays in this file; the zsh check and the removal of base packages stay ours.

echo "::group:: ===$(basename "$0")==="

set -ouex pipefail

# All DNF-related operations should be done here whenever possible

# The package lists are the text files of packages/default in this repository (the Containerfile copies them to /ctx/packages), installed by
# install-packages.sh (its header is the contract; adding a package is one line in a file). In order: required-fedora (ONE strict dnf5 transaction: a name dnf5 cannot find fails the build, so a release difference stops the build
# instead of shipping an image without something that must be there), then the optional lists (optional-fedora, optional-negativo17: best effort, one transaction per
# file, retried once as a whole, then package by package). What still cannot be installed is printed as "OPTIONAL PACKAGE MISSING: <name>" and appended to
# /usr/share/octarine-os/optional-packages-missing (the file exists in every image, possibly empty); the smoke test turns each entry into a CI warning. A missing
# optional package never fails the build.
#
# What stays here, because it is the OS's policy and not a list: the smoke test's check that every REQUIRED package has the RPM
# vendor "Fedora Project" (a package from outside Fedora's own repositories, negativo17, COPR or a vendor repository, may only be in an optional list, or be a
# decision of the owner for a required-negativo17/copr file of a variant), validate-repos.sh (every enabled repository must be one the base enables), and the zsh step.
# Packages can come from any ENABLED yum repo of the image: Fedora's own, negativo17 (fedora-multimedia, disabled in the base, which the installer enables for its
# own calls only) and the base's akmods COPR. No RPM Fusion repository is installed in the base.

test -f /ctx/packages/required-fedora.txt
mkdir -p /usr/share/octarine-os
missing_file=/usr/share/octarine-os/optional-packages-missing
: > "${missing_file}"
# NO_CLEANUP: the dnf caches are cache mounts and final-cleanup.sh runs at the end; the removal of gnome-software below still needs dnf5
MISSING_FILE="${missing_file}" NO_CLEANUP=1 /ctx/install-packages.sh /ctx/packages

# zsh is installed but NOT the default login shell of new users (/etc/default/useradd stays as packaged). Choosing it
# is opt-in through the shell step of `ujust user-setup`, which needs zsh listed in /etc/shells.
if grep -qx 'SHELL=/usr/bin/zsh' /etc/default/useradd; then echo "ERROR: zsh must not be the default shell"; exit 1; fi
grep -qx /usr/bin/zsh /etc/shells || echo /usr/bin/zsh >> /etc/shells

echo "== optional packages missing:"
cat "${missing_file}"

# Beyond the compilers and linker (packages/default/required-fedora.txt) there are no build tools here (cmake, ninja, meson, the development-tools
# group): bigger builds happen in the fedora-toolbox distrobox, created by `ujust toolbox dev-toolbox` from
# /usr/share/ublue-os/distrobox/dev-toolbox.ini (or on the dx image). Nothing in this build compiles from source.

# Packages to exclude: the RPMs the base ships that this image replaces (Bluefin's EXCLUDED_PACKAGES, the same rpm -qa filter).
#   firefox, firefox-langpacks  use the Flatpak
#   toolbox                     distrobox covers it
#   gnome-software              Bazaar (a preinstalled Flatpak) is the software center; fwupd and PackageKit stay, so firmware updates
#                               remain available through `fwupdmgr`
# (gnome-software-rpm-ostree is not in the base image, so it is not listed.)
EXCLUDED_PACKAGES=(
    firefox
    firefox-langpacks
    gnome-software
    toolbox
)

# Deviation: Bluefin removes the list blindly. We preview the transaction first and fail the build if it would take anything from the
# protected list with it (the single place that list lives) or does not list a package we asked for.
PROTECTED_PKGS="gnome-shell nautilus fwupd flatpak PackageKit gdm gnome-control-center gnome-session-wayland-session ostree rpm-ostree bootc podman systemd"
readarray -t INSTALLED_EXCLUDED < <(rpm -qa --queryformat='%{NAME}\n' "${EXCLUDED_PACKAGES[@]}" 2>/dev/null || true)
if [[ "${#INSTALLED_EXCLUDED[@]}" -gt 0 ]]; then
    plan=$(dnf5 remove --assumeno "${INSTALLED_EXCLUDED[@]}" 2>&1 || true)
    echo "== removal transaction"
    echo "${plan}"
    for pkg in "${INSTALLED_EXCLUDED[@]}"; do
        grep -Eq "^[[:space:]]*${pkg}[[:space:]]" <<< "${plan}" || { echo "ERROR: the removal preview does not list ${pkg}"; exit 1; }
    done
    for pkg in ${PROTECTED_PKGS}; do
        if grep -Eq "^[[:space:]]*${pkg}[[:space:]]" <<< "${plan}"; then
            echo "ERROR: removing ${INSTALLED_EXCLUDED[*]} would also remove protected package ${pkg}"
            exit 1
        fi
    done
    dnf5 remove -y "${INSTALLED_EXCLUDED[@]}"
else
    echo "No excluded packages found to remove."
fi

echo "::endgroup::"
