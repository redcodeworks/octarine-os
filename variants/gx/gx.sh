#!/usr/bin/env bash
# Builds the gx layer of octarine-os-gx: the gaming package lists (packages/gx, copied to /ctx/packages; build_files/install-packages.sh installs them
# in its own order: required Fedora, required negativo17 (Steam), required COPR (Sunshine, exact version), optional Fedora). The kernel
# must be exactly the same before and after (nothing here may pull in a new one), and no third-party repository may stay enabled (validate-repos.sh).
set -euo pipefail
# Log groups: GitHub Actions folds each "::group::" ... "::endgroup::" pair in the build log (plain text elsewhere); never nested. The trap
# closes a group left open by a failure and prints an "::error::" line outside it (exit status unchanged).
trap 'rc=$?; echo "::endgroup::"; if (( rc != 0 )); then echo "::error::gx.sh failed (exit ${rc})"; fi' EXIT

kernel_of() { rpm -q --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}\n' kernel-core; }

echo "::group::gx: gaming packages (packages/gx)"
before=$(kernel_of)
echo "Kernel of the base image: ${before}"
test -f /ctx/packages/required-fedora.txt
# dnf5-plugins provides `dnf5 copr` for the COPR list (the base ships it already: then this is a no-op that fails when it is ever missing). Not part of the installer.
dnf5 -y install --setopt=strict=1 dnf5-plugins
# What cannot be installed of the optional list is APPENDED to the file the default image's build created (the installer never truncates it).
missing_file=/usr/share/octarine-os/optional-packages-missing
test -f "${missing_file}"
MISSING_FILE="${missing_file}" /ctx/install-packages.sh /ctx/packages
# Steam comes from negativo17 (fedora-multimedia, enabled for that call only by the installer): the gaming image is not one without it
steam_from=$(dnf5 -q repoquery --installed steam --queryformat '%{from_repo}\n')
[[ "${steam_from}" == fedora-multimedia ]] || {
	echo "ERROR: steam was installed from '${steam_from}', not from fedora-multimedia (negativo17)"
	exit 1
}
echo "::endgroup::"

echo "::group::gx: files (the Steam Big Picture gamescope session)"
# gx-only files: the GDM session, its wrapper and the documented defaults (Sunshine and Steam bring their own units, udev rules and firewall services)
cp -avf /ctx/system_files/. /
test -x /usr/libexec/octarine-os/gamescope-session
test -s /usr/share/wayland-sessions/steam-gamescope.desktop
test -s /usr/share/octarine-os/gamescope-session.conf
echo "::endgroup::"

echo "::group::gx: image identity and kernel check"
# Image identity (os-release IMAGE_ID and IMAGE_VERSION): this variant's own, not the base image's. IMAGE_VERSION is the
# version of THIS build (<YYYYMMDD>-<short sha>), passed in by the workflow; a promoted tag keeps it.
set_os_release_field() {                                                  # key value: replace the line when it exists, append it otherwise
	local key="$1" value="$2" file="${OS_RELEASE_FILE:-/usr/lib/os-release}" # the override is for tests
	if grep -q "^${key}=" "${file}"; then
		sed -i "s|^${key}=.*|${key}=\"${value}\"|" "${file}"
	else
		[[ -z "$(tail -c1 "${file}")" ]] || echo >>"${file}"
		echo "${key}=\"${value}\"" >>"${file}"
	fi
	grep -qx "${key}=\"${value}\"" "${file}"
}
: "${IMAGE_VERSION:?IMAGE_VERSION build argument is missing}"
image_id="${GX_IMAGE_ID:-octarine-os-gx}"
[[ "${image_id}" =~ ^octarine-os(-nvidia|-dx)?-gx$ ]] || {
	echo "ERROR: GX_IMAGE_ID '${image_id}' is not octarine-os-gx, octarine-os-nvidia-gx or octarine-os-dx-gx"
	exit 1
}
set_os_release_field IMAGE_ID "${image_id}"
set_os_release_field IMAGE_VERSION "${IMAGE_VERSION}"
# the boot menu entry (ostree titles it from PRETTY_NAME): name, build version and kernel, so the entries can be told apart
set_os_release_field PRETTY_NAME "octarineOS ${IMAGE_VERSION} (kernel $(rpm -q --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}\n' kernel-core))"
IMAGE_ID_EXPECTED="${image_id}" bash -c '. /usr/lib/os-release && [[ "${IMAGE_ID}" == "${IMAGE_ID_EXPECTED}" ]]'

after=$(kernel_of)
[[ "${after}" == "${before}" ]] || {
	echo "ERROR: the gx install changed the kernel (${before} -> ${after})"
	exit 1
}
[[ "$(ls /usr/lib/modules | wc -l)" == 1 && "$(ls /usr/lib/modules)" == "${before}" ]] || {
	echo "ERROR: /usr/lib/modules does not hold exactly ${before}"
	exit 1
}
echo "gx layer installed for kernel ${before}"
echo "::endgroup::"

# Every repository that is enabled must be one the base enables (prints its own log group)
/ctx/validate-repos.sh

# nothing in /boot, /run, /tmp or /var that `bootc container lint --fatal-warnings` objects to (build_files/final-cleanup.sh)
/ctx/final-cleanup.sh
