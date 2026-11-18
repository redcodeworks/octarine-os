#!/usr/bin/bash
# Our own step (Bluefin has no file for it): the local SELinux policy module, after every package step.

echo "::group:: ===$(basename "$0")==="

set -eoux pipefail

# The local SELinux module (system_files/usr/share/octarine-os/selinux/octarine-local.cil: three narrow rules, the reasons and the upstream references are
# in the file). It goes in AFTER every package step: the rules name types of pcp and tuned, so the install fails when those packages (or a renamed type)
# are not there, and that failure is meant to fail the build (set -e, no `|| true`). semodule writes the module into the policy store, /etc/selinux/targeted/active
# (priority 400), which the image carries as /usr/etc.
semodule -i /usr/share/octarine-os/selinux/octarine-local.cil
modules=$(semodule -l)
grep -qx 'octarine-local' <<< "${modules}" || { echo "ERROR: semodule -i succeeded but octarine-local is not listed"; exit 1; }

echo "::endgroup::"
