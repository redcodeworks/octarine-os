# vim: set ft=make :

# Replaces the base image's toggle-nvk, which derives image names by string substitution (octarine-os-dx-nvidia-open does
# not exist) and rebases without enforcing the signature policy. `ujust switch-image` (60-custom.just) replaces it.
# Switch between Nvidia image and NVK (use switch-image)
toggle-nvk:
    #!/usr/bin/bash
    echo "toggle-nvk is gone: use 'ujust switch-image' (images default, dx, nvidia, nvidia-dx; channels latest, beta, testing)."
