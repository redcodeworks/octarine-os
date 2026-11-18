#!/usr/bin/bash
# Our own step (Bluefin has no file for it): prebuilt binaries (sched_ext schedulers, extest, Ghostty), the scheduler registry and the
# checks of its files. The two helper scripts print their own log groups, so only the checks sit in a group of this script.

set -eoux pipefail

# The signed files-only octarine-bins image (built by the octarine-bins repository), pinned by digest in the Containerfile and bind-mounted
# at /binaries; install-binaries.sh installs them (checks, layout and licenses are described there). Installed only:
# no unit, no preset, nothing is started.
/ctx/install-binaries.sh

# The sched_ext scheduler registry and unit drop-ins, generated from the manifest that install-binaries.sh just installed
# (scx@.service, its helpers and the polkit rule come from system_files). Nothing is enabled: the preset says disable.
/ctx/gen-schedulers.sh
echo "::group:: ===$(basename "$0")=== checks of the scheduler files"
for f in scx-preflight scx-wait-idle scx-run scx-verify gamemode-start gamemode-end; do test -x "/usr/libexec/octarine-os/${f}"; done
test -f /usr/lib/systemd/system/scx@.service
test -f /usr/share/polkit-1/rules.d/50-octarine-scx.rules
! grep -q "@INSTANCES@" /usr/share/polkit-1/rules.d/50-octarine-scx.rules

echo "::endgroup::"
