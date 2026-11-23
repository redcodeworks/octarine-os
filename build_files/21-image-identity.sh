#!/usr/bin/bash
# Our own step (Bluefin writes this in 00-image-info.sh): IMAGE_ID and IMAGE_VERSION, AFTER 19-initramfs.sh.

echo "::group:: ===$(basename "$0")==="

set -eoux pipefail

# Image identity: IMAGE_ID and IMAGE_VERSION (the fields os-release(5) defines for this), written AFTER dracut: dracut copies os-release into the initramfs
# (usr/lib/initrd-release), so a per-build IMAGE_VERSION there made the initramfs differ in every build; nothing reads IMAGE_VERSION from the initramfs. The version is the build's own
# channel-neutral one (<YYYYMMDD>-<short sha>, passed in by `just build`), the same string as the OCI version label; a promoted image (testing -> latest) is the same
# image, so it keeps exactly these fields.
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
set_os_release_field IMAGE_ID octarine-os
set_os_release_field IMAGE_VERSION "${IMAGE_VERSION:-unknown}"
bash -c '. /usr/lib/os-release && [[ "${IMAGE_ID}" == octarine-os ]]'
echo "== resulting os-release"
cat /usr/lib/os-release

echo "::endgroup::"
