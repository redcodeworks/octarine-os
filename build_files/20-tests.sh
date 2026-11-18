#!/usr/bin/bash
# Derived from ublue-os/bluefin build_files/base/20-tests.sh (Apache-2.0, https://github.com/ublue-os/bluefin); modified for octarine-os.
# Deviations: only what this image really ships is asserted. Not taken: the ublue signing-key hash check (we pull only our own images, whose
# policy 01-signature-policy.sh writes), the flatpak-add-fedora-repos.service test (our ujust flathub recipe relies on that unit), the Bluefin
# package names we do not ship (uupd; fish is optional here), fedora-logos (kept on purpose), podman-docker (optional here) and the NVIDIA
# packages (the NVIDIA variant has its own smoke test). gnome-software-rpm-ostree is not in the base image, so it is not listed.

echo "::group:: ===$(basename "$0")==="

set -eoux pipefail

IMPORTANT_PACKAGES=(
	distrobox
	flatpak
	gdm
	gnome-shell
	mutter
	pipewire
	ptyxis
	systemd
	tailscale
	wireplumber
	zsh
)

for package in "${IMPORTANT_PACKAGES[@]}"; do
	rpm -q "${package}" >/dev/null || {
		echo "Missing package: ${package}... Exiting"
		exit 1
	}
done

# these packages are supposed to be removed (EXCLUDED_PACKAGES of 04-packages.sh)
UNWANTED_PACKAGES=(
	firefox
	gnome-software
	toolbox
)

for package in "${UNWANTED_PACKAGES[@]}"; do
	if rpm -q "${package}" >/dev/null 2>&1; then
		echo "Unwanted package found: ${package}... Exiting"
		exit 1
	fi
done

# The units 17-cleanup.sh enables (tailscaled.service is deliberately not enabled; rpm-ostreed-automatic.timer is the base's)
IMPORTANT_UNITS=(
	brew-setup.service
	brew-update.timer
	rpm-ostreed-automatic.timer
)

for unit in "${IMPORTANT_UNITS[@]}"; do
	if ! systemctl is-enabled "$unit" 2>/dev/null | grep -q "^enabled$"; then
		echo "${unit} is not enabled"
		exit 1
	fi
done

systemctl --global is-enabled podman.socket | grep -q "^enabled$" || {
	echo "podman.socket (global) is not enabled"
	exit 1
}

echo "::endgroup::"
