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
# ROCm (rocminfo rocm-smi rocm-hip rocm-opencl hipcc, about 3 GiB with its LLVM dependencies) stays in the shared list, which also
# builds the owner's fedora-toolbox, but is NOT part of the dx images: `ujust hardware-setup` (step rocm) provides it in a
# rootless distrobox instead. EXCLUDE takes exact package names (see dev-packages/install.sh in the fedora-toolbox repo).
EXCLUDE="rocminfo rocm-smi rocm-hip rocm-opencl hipcc" bash /dev-packages/install.sh
for p in rocminfo rocm-smi rocm-hip rocm-opencl hipcc; do
    if rpm -q "${p}" >/dev/null 2>&1; then echo "ERROR: ${p} must not be installed in the dx image"; exit 1; fi
done

# The extras (grouped list, one strict transaction; names the shared list or the base already installed are skipped)
mapfile -t extras < <(sed -e 's/[[:space:]]*#.*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e '/^$/d' /ctx/extras.txt)
[[ "${#extras[@]}" -gt 0 ]] || { echo "ERROR: /ctx/extras.txt lists no package"; exit 1; }
echo "Installing ${#extras[@]} extra packages"
dnf5 -y install --setopt=strict=1 "${extras[@]}"
dnf5 clean all
rm -rf /var/cache/libdnf5 /var/cache/dnf /var/log/dnf5.log* /var/log/dnf.log* /root/.cache 2>/dev/null || true

# dx-only files (the `ujust dev` recipe file, the sdk wrapper, the cargo PATH snippet)
cp -avf /ctx/system_files/. /

# `ujust dev` exists only in this image: ublue-os-just's /usr/share/ublue-os/justfile imports every file of its own package
# plus the optional 60-custom.just, so the dx-only recipe file is imported by a line appended here (not in the default image)
ujust_main=/usr/share/ublue-os/justfile
dev_import='import? "/usr/share/ublue-os/just/70-octarine-dev.just"'
test -f "${ujust_main}"
test -s /usr/share/ublue-os/just/70-octarine-dev.just
if ! grep -qxF "${dev_import}" "${ujust_main}"; then
    [[ -z "$(tail -c1 "${ujust_main}")" ]] || echo >> "${ujust_main}"
    echo "${dev_import}" >> "${ujust_main}"
fi
grep -qxF "${dev_import}" "${ujust_main}"
chmod 0755 /usr/bin/sdk

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
# the same layer sits on the default image (octarine-os-dx) and on the NVIDIA variant (octarine-os-nvidia-dx)
image_id="${DX_IMAGE_ID:-octarine-os-dx}"
[[ "${image_id}" =~ ^octarine-os(-nvidia)?-dx$ ]] || { echo "ERROR: DX_IMAGE_ID '${image_id}' is not octarine-os-dx or octarine-os-nvidia-dx"; exit 1; }
set_os_release_field IMAGE_ID "${image_id}"
set_os_release_field IMAGE_VERSION "${IMAGE_VERSION}"
IMAGE_ID_EXPECTED="${image_id}" bash -c '. /usr/lib/os-release && [[ "${IMAGE_ID}" == "${IMAGE_ID_EXPECTED}" ]]'

after=$(kernel_of)
[[ "${after}" == "${before}" ]] || { echo "ERROR: the dx install changed the kernel (${before} -> ${after})"; exit 1; }
[[ "$(ls /usr/lib/modules | wc -l)" == 1 && "$(ls /usr/lib/modules)" == "${before}" ]] || { echo "ERROR: /usr/lib/modules does not hold exactly ${before}"; exit 1; }
echo "dx layer installed for kernel ${before}"
