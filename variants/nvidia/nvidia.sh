#!/usr/bin/env bash
# Adds the proprietary NVIDIA driver to octarine-os (image-template recipe "Adding NVIDIA drivers"): runs the
# nvidia-install.sh of the akmods image, then writes what that script does not (nouveau blacklist, kernel
# arguments) and rebuilds the initramfs. The kernel must be exactly the same before and after.
set -euo pipefail
# Log groups: GitHub Actions folds each "::group::" ... "::endgroup::" pair in the build log (plain text elsewhere); never nested. The trap
# closes a group left open by a failure and prints an "::error::" line outside it (exit status unchanged).
trap 'rc=$?; echo "::endgroup::"; if (( rc != 0 )); then echo "::error::nvidia.sh failed (exit ${rc})"; fi' EXIT

kernel_of() { rpm -q --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}\n' kernel-core; }

echo "::group::nvidia: driver install"
before=$(kernel_of)
test "$(ls /usr/lib/modules | wc -l)" = 1
kver=$(ls /usr/lib/modules)
[[ "${kver}" == "${before}" ]] || { echo "ERROR: /usr/lib/modules holds ${kver} but kernel-core is ${before}"; exit 1; }
echo "Kernel of the base image: ${before}"

test -x /tmp/akmods-rpms/ublue-os/nvidia-install.sh
IMAGE_NAME=silverblue /tmp/akmods-rpms/ublue-os/nvidia-install.sh

echo "::endgroup::"
echo "::group::nvidia: image identity and kernel check"
# Image identity (os-release IMAGE_ID and IMAGE_VERSION): this variant's own, not the base image's. IMAGE_VERSION is the
# version of THIS build (<YYYYMMDD>-<short sha>), passed in by the workflow; a promoted tag keeps it.
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
# the two fields are written after the dracut run below (dracut copies os-release into the initramfs; a per-build IMAGE_VERSION there changed it every build)

after=$(kernel_of)
[[ "${after}" == "${before}" ]] || { echo "ERROR: the NVIDIA install changed the kernel (${before} -> ${after})"; exit 1; }
test "$(ls /usr/lib/modules | wc -l)" = 1
[[ "$(ls /usr/lib/modules)" == "${before}" ]] || { echo "ERROR: kernel module directory changed"; exit 1; }

echo "::endgroup::"
echo "::group::nvidia: CDI, kernel arguments and initramfs"
# CDI (how a container gets the GPU, also what `ujust dev --only cuda` in the dx image uses): the akmods nvidia-install.sh
# above installs the full nvidia-container-toolkit and enables nvidia-cdi-refresh.service/.path (per the ublue-os/akmods
# sources, read 2026-11-10; the spec is written to /var/run/cdi/nvidia.yaml at boot). This is only a guarded fallback for when
# neither toolkit package is there: try the base package once (a warning on failure). The units are enabled when they exist.
if ! rpm -q nvidia-container-toolkit >/dev/null 2>&1 && ! rpm -q nvidia-container-toolkit-base >/dev/null 2>&1; then
    dnf5 -y install nvidia-container-toolkit-base || echo "WARNING: nvidia-container-toolkit-base is not installed; CDI needs it (nvidia-ctk cdi generate)"
fi
for u in nvidia-cdi-refresh.path nvidia-cdi-refresh.service; do
    if [[ -e "/usr/lib/systemd/system/${u}" ]]; then systemctl enable "${u}" || echo "WARNING: could not enable ${u}"; else echo "NOTE: ${u} does not exist in this image"; fi
done

# nvidia-install.sh writes neither of these (UNVERIFIED for Fedora; the shape Bluefin LTS uses). bootc merges this
# kargs.d file with the ones the base image already has (if any).
cat >/usr/lib/modprobe.d/00-nouveau-blacklist.conf <<'EOM'
blacklist nouveau
options nouveau modeset=0
EOM
cat >/usr/lib/bootc/kargs.d/00-nvidia.toml <<'EOM'
kargs = ["rd.driver.blacklist=nouveau", "modprobe.blacklist=nouveau", "nvidia-drm.modeset=1"]
EOM

# The boot and LUKS screens run from the initramfs, which must carry the modules (99-nvidia.conf was edited by the script)
img="/usr/lib/modules/${before}/initramfs.img"
show_img() { echo "initramfs $1: $(stat -c 'size=%s mtime=%y' "${img}" 2>&1)"; }
show_img "before dracut"
# dracut logs "dracut-install: ERROR: installing '/root' to '/root'" and "No /dev/log" in the build container; the
# exit status decides, not the log text: a non-zero status fails the build with the message below.
rc=0
DRACUT_NO_XATTR=1 dracut --no-hostonly --kver "${before}" --reproducible --add ostree -f "${img}" || rc=$?
echo "dracut exit status: ${rc}"
show_img "after dracut"
[[ "${rc}" == 0 ]] || { echo "ERROR: dracut failed with status ${rc}, the initramfs is not trustworthy"; exit 1; }
chmod 0600 "${img}"

set_os_release_field IMAGE_ID octarine-os-nvidia
set_os_release_field IMAGE_VERSION "${IMAGE_VERSION}"
bash -c '. /usr/lib/os-release && [[ "${IMAGE_ID}" == octarine-os-nvidia ]]'
# The build log itself shows whether the modules landed (listing to a file: no SIGPIPE from head)
lst=$(mktemp)
lsinitrd_rc=0
lsinitrd "${img}" >"${lst}" 2>&1 || lsinitrd_rc=$?
echo "lsinitrd exit status: ${lsinitrd_rc}; nvidia entries of the new initramfs (max 20):"
grep -i nvidia "${lst}" | head -20 || true
rm -f "${lst}"
echo "NVIDIA driver installed for kernel ${before}"
echo "::endgroup::"

# nvidia-install.sh enables the ublue-os staging COPR (for supergfxctl) and "disables" it again with `dnf5 config-manager setopt`,
# which only writes enabled=0 into /etc/dnf/repos.override.d; the COPR's own file in /etc/yum.repos.d keeps enabled=1, and
# validate-repos.sh's file scan (which does not apply overrides) then names it (CI failure 2026-11-14). Nothing needs the repo at
# runtime (supergfxctl is already installed). Make the repo file itself say enabled=0 (the setopt is repeated for dnf5's own answer).
staging="copr:copr.fedorainfracloud.org:ublue-os:staging"
dnf5 config-manager setopt "${staging}.enabled=0"
for f in /etc/yum.repos.d/*.repo; do
    [[ -f "${f}" ]] || continue
    if grep -qF "[${staging}]" "${f}"; then
        sed -i -E 's/^(enabled[[:space:]]*=[[:space:]]*)(1|[Tt]rue)[[:space:]]*$/\10/' "${f}"
        echo "staging COPR disabled in ${f}"
    fi
done

# Every repository that is enabled must be one the base enables (prints its own log group)
/ctx/validate-repos.sh

# nothing in /boot, /run, /tmp or /var that `bootc container lint --fatal-warnings` objects to (build_files/final-cleanup.sh)
/ctx/final-cleanup.sh
