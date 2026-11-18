#!/bin/bash
# The orchestrator of the image build, in the shape of Bluefin's build_files/shared/build.sh (one script per concern, numbered, each with its
# own log group, called in order).
# Derived from ublue-os/bluefin@64de5bcd0c67dc807686991c98110d708f245a60 build_files/shared/build.sh (Apache-2.0, https://github.com/ublue-os/bluefin); modified for octarine-os.
#
# Deviations from Bluefin, in short:
#   - the scripts sit directly in build_files/ (the Containerfile mounts it at /ctx), not in base/ and shared/
#   - 03-install-kernel-akmods.sh is not used: we keep the base image's kernel, there are no akmods in this image
#   - 05-override-install.sh keeps only the kernel-devel and /usr/src removal; 20-tests.sh (post-build assertions) runs last, as in Bluefin; Bluefin's shared/validate-repos.sh and clean-stage.sh are
#     replaced by our validate-repos.sh (an allow-list, shared with the variant builds) and final-cleanup.sh (bootc lint)
#   - our own steps in the gaps of the numbering: 01 signature policy, 06 SELinux module, 07 branding, 10 binaries, 21 image identity
#   - the identity (21) is written AFTER dracut (19) because dracut copies os-release into the initramfs; packages (04) come before the
#     SELinux module (06), which names pcp and tuned types
#   - the error trap below is ours: it closes an open ::group:: and prints an ::error:: line
set -ouex pipefail

# Log sections: every script prints its own "::group::" ... "::endgroup::" pair, which GitHub Actions folds in the build log (anywhere
# else it is just a line of text). Groups are never nested (Actions does not nest them), so the helper scripts print their own
# and are called between two of ours. When the build fails inside a group, this trap closes it and prints an "::error::" line outside
# it, so the failure is not folded away (the exit status is unchanged).
trap 'rc=$?; if (( rc != 0 )); then echo "::endgroup::"; echo "::error::build.sh failed (exit ${rc})"; fi' EXIT

echo "::group:: Copy Files"
# --- Guard: refuse to build if secrets or personal key material ended up in system_files ---
# A security key registration (pam_u2f's u2f_keys) or a private key copied here would be baked into a
# public image. Check names first, then content (this also catches a renamed copy).
forbidden=$(find /ctx/system_files \( -name 'u2f_keys' -o -name 'u2f_mappings' -o -name 'Yubico' \
    -o -name '*.key' -o -name '*.p12' -o -name '*.pfx' -o -name 'id_rsa*' -o -name 'id_ed25519*' \
    -o -name 'id_ecdsa*' -o -name 'authorized_keys' -o -name '.env' \) -print)
forbidden+=$'\n'$(grep -rIlE -e '-----BEGIN [A-Z ]*PRIVATE KEY-----' \
    -e ',(es256|eddsa|rs256),\+?(presence|verification|pin)?' /ctx/system_files || true)
forbidden=$(echo "$forbidden" | sed '/^$/d')
if [[ -n "$forbidden" ]]; then
    echo "Refusing to build: sensitive files found in system_files:" >&2
    echo "$forbidden" >&2
    exit 1
fi

# Base recipe files that our own file of the same name wraps: keep the base copy as <name>-base.just. Our file imports it and
# overrides single recipes (between two imported files the FIRST import wins, so a later file could not override them).
# A missing base file fails the build, which is the signal that the base changed its layout.
for f in 00-default 10-update 30-distrobox; do
    mv "/usr/share/ublue-os/just/${f}.just" "/usr/share/ublue-os/just/${f}-base.just"
done

# Copy the contents of system_files/ of the git repo to /
cp -avf "/ctx/system_files"/. /

# Our 15-luks.just, 40-nvidia.just and 50-akmods.just overwrite the base files of the same name (only 00-default, 10-update and
# 30-distrobox are renamed and imported). The base's toggle-nvk (builds image names that do not exist, rebases without the
# signature policy) lived in 40-nvidia.just: it must be gone.
if grep -rqE '^toggle-nvk' /usr/share/ublue-os/just/; then echo "ERROR: the base toggle-nvk recipe is still installed"; exit 1; fi

# sudo ignores sudoers.d files that are not mode 0440; git does not track modes
chmod 0440 /etc/sudoers.d/10-timestamp-timeout
visudo -c

# System-wide GNOME defaults: compile the keyfiles in /etc/dconf/db/*.d (ours is distro.d/90-octarine-os) into the binary
# databases dconf reads. /etc/dconf/profile/user already lists system-db:distro after the user database, so a user's
# own setting always wins. A bad keyfile makes dconf exit non-zero and fails the build (set -e).
dconf update
test /etc/dconf/db/distro -nt /etc/dconf/db/distro.d/90-octarine-os
echo "::endgroup::"

# Log the base image
/ctx/00-image-info.sh

# Container signature policy
/ctx/01-signature-policy.sh

# Install Additional Packages
/ctx/04-packages.sh

# Remove kernel-devel and /usr/src
/ctx/05-override-install.sh

# The local SELinux module (after every package step)
/ctx/06-selinux.sh

# Branding: PRETTY_NAME, GDM logo, Plymouth theme (before the initramfs)
/ctx/07-branding.sh

# Prebuilt binaries and the scheduler registry
/ctx/10-binaries.sh

## late stage changes
# Systemd
/ctx/17-cleanup.sh

# Run workarounds
/ctx/18-workarounds.sh

# Regenerate initramfs
/ctx/19-initramfs.sh

# Image identity (after the initramfs)
/ctx/21-image-identity.sh

# --- Every repository that is enabled must be one the base enables (see validate-repos.sh; prints its own log group) ---
/ctx/validate-repos.sh

# --- Last step: nothing in /boot, /run, /tmp or /var that `bootc container lint --fatal-warnings` objects to (see final-cleanup.sh; prints its own log group) ---
/ctx/final-cleanup.sh

# Simple Tests
/ctx/20-tests.sh
