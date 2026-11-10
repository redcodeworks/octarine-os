# vim: set ft=make :

# Deliberately empty. It replaces the base image's 40-nvidia.just, whose only recipe is toggle-nvk: it derives image names
# by string substitution (octarine-os-dx-nvidia-open does not exist) and rebases without enforcing the signature policy.
# The same file name makes build.sh's copy of system_files overwrite the base file, so toggle-nvk is gone from the image;
# `ujust switch-image` (60-custom.just) replaces it.
