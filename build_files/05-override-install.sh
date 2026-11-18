#!/usr/bin/bash
# Derived from ublue-os/bluefin@a1f90cb7a79c1158263ae8082571d3d2f1a6b35a build_files/base/05-override-install.sh (Apache-2.0, https://github.com/ublue-os/bluefin); modified for octarine-os.
# Deviations: only the kernel-devel and /usr/src removal is taken. Bluefin's offline PDF, Starship download, wallpapers, faces and desktop-entry
# edits are Bluefin's own, and /usr/share/doc is left alone (not decided). Bluefin's erase is unconditional because its kernel-devel always
# comes from its akmods step; ours is not installed at this point (the base has none and the lists do not name it), so the erase is guarded.

echo "::group:: ===$(basename "$0")==="

set -eoux pipefail

# We do not need anything here at all
rm -rf /usr/src
# Remove kernel-devel from rpmdb because all package files are removed from /usr/src
if rpm -q kernel-devel &>/dev/null; then
    rpm --erase --nodeps kernel-devel
fi

echo "::endgroup::"
