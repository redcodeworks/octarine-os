#!/usr/bin/env bash
# Builds the dx layer of octarine-os-dx: the shared developer list (bind-mounted at /dev-packages from the pinned
# dev-packages image), then variants/dx/packages/extras.txt, the dx-only files and podman.socket. The kernel must be
# exactly the same before and after (nothing here may pull in a new one).
set -euo pipefail
# Log groups: GitHub Actions folds each "::group::" ... "::endgroup::" pair in the build log (plain text elsewhere); never nested. The trap
# closes a group left open by a failure and prints an "::error::" line outside it (exit status unchanged).
trap 'rc=$?; echo "::endgroup::"; if (( rc != 0 )); then echo "::error::dx.sh failed (exit ${rc})"; fi' EXIT

kernel_of() { rpm -q --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}\n' kernel-core; }
echo "::group::dx: shared developer packages"
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

echo "::endgroup::"
echo "::group::dx: extra packages"
# The extras (grouped list, one strict transaction; names the shared list or the base already installed are skipped)
mapfile -t extras < <(sed -e 's/[[:space:]]*#.*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e '/^$/d' /ctx/extras.txt)
[[ "${#extras[@]}" -gt 0 ]] || { echo "ERROR: /ctx/extras.txt lists no package"; exit 1; }
echo "Installing ${#extras[@]} extra packages"
dnf5 -y install --setopt=strict=1 "${extras[@]}"
dnf5 clean all
rm -rf /var/cache/libdnf5 /var/cache/dnf /var/log/dnf5.log* /var/log/dnf.log* /root/.cache 2>/dev/null || true
echo "::endgroup::"

echo "::group::dx: files, recipes and the datastore signature policy"

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

# `ujust datastore-install`, `datastore` and `datastore-setup`: the thin recipes of the opt-in datastore (the signed bundle is fetched on demand; the image ships no
# datastore unit). Their container signature policy: the key of the fedora-toolbox repository, which signs the bundle, for exactly that repository.
# --- datastore bundle signature policy ---
test -s /ctx/toolbox-cosign.pub
bundle_ref=ghcr.io/redcodeworks/datastore-images
bundle_key=/etc/pki/containers/redcodeworks-toolbox.pub
install -Dm644 /ctx/toolbox-cosign.pub "${bundle_key}"
printf 'docker:\n  %s:\n    use-sigstore-attachments: true\n' "${bundle_ref}" >/etc/containers/registries.d/redcodeworks-datastore-images.yaml
python3 - "${bundle_key}" "${bundle_ref}" <<'PY'
import json
import sys

key, ref = sys.argv[1:]
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
# --- end datastore bundle signature policy ---
store_import='import? "/usr/share/ublue-os/just/72-octarine-datastore.just"'
test -s /usr/share/ublue-os/just/72-octarine-datastore.just
if ! grep -qxF "${store_import}" "${ujust_main}"; then echo "${store_import}" >> "${ujust_main}"; fi
grep -qxF "${store_import}" "${ujust_main}"
virthost_import='import? "/usr/share/ublue-os/just/75-octarine-virthost.just"'
test -s /usr/share/ublue-os/just/75-octarine-virthost.just
if ! grep -qxF "${virthost_import}" "${ujust_main}"; then echo "${virthost_import}" >> "${ujust_main}"; fi
grep -qxF "${virthost_import}" "${ujust_main}"

# Docker-compatible API socket for developer tools (rootful); the default image already enables the user one globally
systemctl enable podman.socket
echo "::endgroup::"

echo "::group::dx: image identity and kernel check"

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
echo "::endgroup::"

# Every repository that is enabled must be one the base enables (prints its own log group)
/ctx/validate-repos.sh

# nothing in /boot, /run, /tmp or /var that `bootc container lint --fatal-warnings` objects to (build_files/final-cleanup.sh)
/ctx/final-cleanup.sh
