#!/usr/bin/env bash
# Builds the dx layer of octarine-os-dx: the shared developer list (bind-mounted at /dev-packages from the pinned
# dev-packages image), then variants/dx/packages/extras.txt, the dx-only files and podman.socket. The kernel must be
# exactly the same before and after (nothing here may pull in a new one).
set -euo pipefail

kernel_of() { rpm -q --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}\n' kernel-core; }
before=$(kernel_of)
echo "Kernel of the base image: ${before}"

# The shared developer list: one strict dnf5 install, then the installer cleans the dnf caches
test -f /dev-packages/install.sh
bash /dev-packages/install.sh

# The extras (grouped list, one strict transaction; names the shared list or the base already installed are skipped)
mapfile -t extras < <(sed -e 's/[[:space:]]*#.*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e '/^$/d' /ctx/extras.txt)
[[ "${#extras[@]}" -gt 0 ]] || { echo "ERROR: /ctx/extras.txt lists no package"; exit 1; }
echo "Installing ${#extras[@]} extra packages"
dnf5 -y install --setopt=strict=1 "${extras[@]}"
dnf5 clean all
rm -rf /var/cache/libdnf5 /var/cache/dnf /var/log/dnf5.log* /var/log/dnf.log* /root/.cache 2>/dev/null || true

# dx-only files (the VS Code Flatpak preinstall list)
cp -avf /ctx/system_files/. /

# Docker-compatible API socket for developer tools (rootful); the default image already enables the user one globally
systemctl enable podman.socket

# Image identity (os-release IMAGE_ID and IMAGE_VERSION): this variant's own, not the base image's. IMAGE_VERSION is the
# version of THIS build (<YYYYMMDD>-<short sha>, `beta-` prefixed on the beta channel), passed in by the workflow; a promoted tag keeps it.
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
: "${IMAGE_VERSION:?IMAGE_VERSION build argument is missing}"
set_os_release_field IMAGE_ID octarine-os-dx
set_os_release_field IMAGE_VERSION "${IMAGE_VERSION}"
bash -c '. /usr/lib/os-release && [[ "${IMAGE_ID}" == octarine-os-dx ]]'

after=$(kernel_of)
[[ "${after}" == "${before}" ]] || { echo "ERROR: the dx install changed the kernel (${before} -> ${after})"; exit 1; }
[[ "$(ls /usr/lib/modules | wc -l)" == 1 && "$(ls /usr/lib/modules)" == "${before}" ]] || { echo "ERROR: /usr/lib/modules does not hold exactly ${before}"; exit 1; }
echo "dx layer installed for kernel ${before}"
