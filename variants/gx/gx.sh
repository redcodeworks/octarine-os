#!/usr/bin/env bash
# Builds the gx layer of octarine-os-gx: the shared gaming lists (bind-mounted at /gaming-packages from the pinned gaming-packages image), one dnf5 call
# per source class (Fedora, RPM Fusion, COPR), then variants/gx/packages/extras.txt and the gx-only files. The kernel must be exactly the same before and
# after (nothing here may pull in a new one), and no third-party repository may stay enabled.
set -euo pipefail
# Log groups: GitHub Actions folds each "::group::" ... "::endgroup::" pair in the build log (plain text elsewhere); never nested. The trap
# closes a group left open by a failure and prints an "::error::" line outside it (exit status unchanged).
# The same trap removes the override file that enables the Steam repository (see the RPM Fusion step), however the script ends.
override=/etc/dnf/repos.override.d/99-gx-steam.repo
trap 'rc=$?; rm -f "${override}"; echo "::endgroup::"; if (( rc != 0 )); then echo "::error::gx.sh failed (exit ${rc})"; fi' EXIT

kernel_of() { rpm -q --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}\n' kernel-core; }
# the installers clean up after themselves only when asked: one cleanup at the end of this script (their cleanup would drop the dnf metadata between the calls)
export NO_CLEANUP=1

echo "::group::gx: Fedora packages"
before=$(kernel_of)
echo "Kernel of the base image: ${before}"
for f in install.sh install-copr.sh fedora.txt rpmfusion.txt copr.txt; do test -s "/gaming-packages/${f}"; done
# dnf5-plugins provides `dnf5 copr` (the base ships it already: then this is a no-op that fails when it is ever missing)
dnf5 -y install --setopt=strict=1 dnf5-plugins
bash /gaming-packages/install.sh /gaming-packages/fedora.txt
echo "::endgroup::"

echo "::group::gx: RPM Fusion nonfree (Steam)"
# The image has no RPM Fusion repository. Fedora's own package fedora-workstation-repositories ships /usr/share/dnf5/repos.d/rpmfusion-nonfree-steam.repo
# (DISABLED, with the key of the distribution-gpg-keys package). The repository is enabled for the Steam transaction only, through an override file that is
# removed again, so the repository file stays as shipped (enabled=0) and validate-repos.sh needs no allow-list entry. The package must really come from RPM
# Fusion: the transaction output names the repository (checked below with `dnf5 repoquery --installed`).
dnf5 -y install --setopt=strict=1 fedora-workstation-repositories
steam_repo=/usr/share/dnf5/repos.d/rpmfusion-nonfree-steam.repo
test -s "${steam_repo}"
mkdir -p /etc/dnf/repos.override.d
# priority=10 (default 99): the base enables negativo17's multimedia repository, which ships its own, newer `steam` (a different package, from the
# same Valve tarball) and would win by version; with the lower number only the RPM Fusion repository is considered for the names it carries (steam)
printf '[rpmfusion-nonfree-steam]\nenabled=1\npriority=10\n' > "${override}"
# (output to a variable first: `producer | grep -q` dies of SIGPIPE under pipefail)
repos=$(dnf5 repolist --enabled)
[[ "${repos}" == *$'\nrpmfusion-nonfree-steam '* ]] || { echo "ERROR: the override did not enable rpmfusion-nonfree-steam"; echo "${repos}"; exit 1; }
bash /gaming-packages/install.sh /gaming-packages/rpmfusion.txt
rm -f "${override}"
steam_from=$(dnf5 -q repoquery --installed steam --queryformat '%{from_repo}\n')
[[ "${steam_from}" == rpmfusion-nonfree-steam ]] || { echo "ERROR: steam was installed from '${steam_from}', not from rpmfusion-nonfree-steam"; exit 1; }
# The package was only the carrier of the repository file and the key: remove it again (with fedora-third-party, which it pulls in and whose boot service
# fedora-third-party-refresh would otherwise ship enabled), so no google-chrome or NVIDIA repository file (all disabled) and no extra boot service stays in the image
dnf5 -y remove fedora-workstation-repositories fedora-third-party
for f in "${steam_repo}" /etc/systemd/system/multi-user.target.wants/fedora-third-party-refresh.service; do
    [[ ! -e "${f}" && ! -L "${f}" ]] || { echo "ERROR: ${f} is still there after removing the repository package"; exit 1; }
done
repos=$(dnf5 repolist --enabled)
[[ "${repos}" != *$'\nrpmfusion'* ]] || { echo "ERROR: an RPM Fusion repository is still enabled"; echo "${repos}"; exit 1; }
echo "::endgroup::"

echo "::group::gx: COPR packages (Sunshine, exact version)"
# install-copr.sh enables the COPR, installs the exact name-version-release of the list in one strict transaction and disables the COPR again
bash /gaming-packages/install-copr.sh /gaming-packages/copr.txt
echo "::endgroup::"

echo "::group::gx: extra packages and files"
mapfile -t extras < <(sed -e 's/[[:space:]]*#.*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e '/^$/d' /ctx/extras.txt)
if [[ "${#extras[@]}" -gt 0 ]]; then
    echo "Installing ${#extras[@]} extra packages"
    dnf5 -y install --setopt=strict=1 "${extras[@]}"
else
    echo "variants/gx/packages/extras.txt lists no package"
fi
dnf5 clean all
rm -rf /var/cache/libdnf5 /var/cache/dnf /var/log/dnf5.log* /var/log/dnf.log* /root/.cache /root/.ssh /root/.viminfo 2>/dev/null || true

# (no gx-only files: Sunshine and Steam bring their own units, udev rules and firewall services; a gx `system_files` tree would be copied here)
echo "::endgroup::"

echo "::group::gx: image identity and kernel check"
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
image_id="${GX_IMAGE_ID:-octarine-os-gx}"
[[ "${image_id}" == octarine-os-gx ]] || { echo "ERROR: GX_IMAGE_ID '${image_id}' is not octarine-os-gx"; exit 1; }
set_os_release_field IMAGE_ID "${image_id}"
set_os_release_field IMAGE_VERSION "${IMAGE_VERSION}"
IMAGE_ID_EXPECTED="${image_id}" bash -c '. /usr/lib/os-release && [[ "${IMAGE_ID}" == "${IMAGE_ID_EXPECTED}" ]]'

after=$(kernel_of)
[[ "${after}" == "${before}" ]] || { echo "ERROR: the gx install changed the kernel (${before} -> ${after})"; exit 1; }
[[ "$(ls /usr/lib/modules | wc -l)" == 1 && "$(ls /usr/lib/modules)" == "${before}" ]] || { echo "ERROR: /usr/lib/modules does not hold exactly ${before}"; exit 1; }
echo "gx layer installed for kernel ${before}"
echo "::endgroup::"

# Every repository that is enabled must be one the base enables (prints its own log group)
/ctx/validate-repos.sh

# nothing in /boot, /run, /tmp or /var that `bootc container lint --fatal-warnings` objects to (build_files/final-cleanup.sh)
/ctx/final-cleanup.sh
