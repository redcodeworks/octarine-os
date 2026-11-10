# vim: set ft=make :

# Deliberately empty. It replaces the base image's 15-luks.just (setup-luks-tpm-unlock and remove-luks-tpm-unlock: root
# device only, enroll and remove as separate commands) so those two names are gone; `ujust luks-tpm-unlock` in
# 60-custom.just is the one recipe for both. The same file name makes build.sh's copy of system_files overwrite the base file.
