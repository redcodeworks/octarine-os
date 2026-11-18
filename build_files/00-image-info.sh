#!/usr/bin/bash
# Derived from ublue-os/bluefin build_files/base/00-image-info.sh (Apache-2.0, https://github.com/ublue-os/bluefin); modified for octarine-os.
# Deviation: Bluefin writes image-info.json and rewrites os-release here. We do neither at this point: the image identity (IMAGE_ID,
# IMAGE_VERSION) is written after dracut by 21-image-identity.sh, PRETTY_NAME by 07-branding.sh. This slot only logs the base image,
# so the build log says what this build started from.

echo "::group:: ===$(basename "$0")==="

set -xeuo pipefail

echo "== base image os-release"
cat /usr/lib/os-release

echo "::endgroup::"
