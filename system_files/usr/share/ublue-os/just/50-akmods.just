# vim: set ft=make :

# Deliberately empty. It replaces the base image's 50-akmods.just, which held only configure-broadcom-wl (and an alias,
# broadcom-wl): the image ships no Broadcom `wl` kernel module, so the recipe could only write modprobe files for a module
# that does not exist. The same file name makes build.sh's copy of system_files overwrite the base file.
