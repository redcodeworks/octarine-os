#!/usr/bin/bash
# Derived from ublue-os/bluefin@c020f2101db64e0fa8638edab315f4da4c5e847a build_files/base/18-workarounds.sh (Apache-2.0, https://github.com/ublue-os/bluefin); modified for octarine-os.
# Deviation: Bluefin's bling.sh copy is left out (we have no bling files). The orphan-directory loop sits inside the group.

echo "::group:: ===$(basename "$0")==="

set -eoux pipefail

# Try removing just docs (is it actually promblematic?)
rm -rf /usr/share/doc/just/README.*.md

# Remove orphan /usr/lib/modules/ directories left by kernel-tools version bumps
# that don't bring the matching kernel-core. akmods-ostree-post iterates all
# /usr/lib/modules/ entries and fails on those with no matching kernel headers.
# (Bluefin PR #4677; here dracut would otherwise find two kernel directories.)
for kver_dir in /usr/lib/modules/*/; do
    kver=$(basename "${kver_dir}")
    if ! rpm -q "kernel-core-${kver}" &>/dev/null; then
        echo "Removing orphan /usr/lib/modules/${kver} (no matching kernel-core RPM)"
        rm -rf "${kver_dir}"
    fi
done

echo "::endgroup::"
