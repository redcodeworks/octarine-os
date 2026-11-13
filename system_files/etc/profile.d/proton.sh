#!/bin/bash

# FSR4 upgrade is an AMD feature: set it only when a GPU with the AMD vendor id (0x1002) is present. A bash glob and
# `read` only, no subprocess, because this runs at every login shell.
for _octarine_vendor in "${OCTARINE_SYSFS_DRM:-/sys/class/drm}"/card*/device/vendor; do
    [ -r "$_octarine_vendor" ] || continue
    read -r _octarine_id <"$_octarine_vendor" 2>/dev/null
    if [ "$_octarine_id" = 0x1002 ]; then
        export PROTON_FSR4_UPGRADE=1
        break
    fi
done
unset _octarine_vendor _octarine_id

export PROTON_ENABLE_WAYLAND=1
