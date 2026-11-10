# vim: set ft=make :

# Replaces the base image's two recipes (root device only, enroll and remove as separate commands) with aliases of the
# single menu-driven recipe in 60-custom.just. The old names keep working.
alias setup-luks-tpm-unlock := luks-tpm-unlock
alias remove-luks-tpm-unlock := luks-tpm-unlock
