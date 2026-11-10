# vim: set ft=make :

# Wraps the base image's 30-distrobox.just (kept by build.sh as 30-distrobox-base.just): everything comes from the base
# file except setup-distrobox-app, which is hidden from `ujust --list` (private) but still works: its only entry is an
# NVIDIA PyTorch container that needs an NVIDIA GPU.
import "30-distrobox-base.just"

[private]
setup-distrobox-app CONTAINER="prompt":
    #!/usr/bin/bash
    source /usr/lib/ujust/ujust.sh
    AssembleList "/etc/distrobox/apps.ini" create {{ CONTAINER }}
