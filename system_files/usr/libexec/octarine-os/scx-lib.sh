# shellcheck shell=bash
# Shared helpers of the sched_ext scheduler units and the GameMode hooks. Sourced, never run. Root units use it, so it only ever
# reads root-owned files: the registry (/usr/share/octarine-os/schedulers.d/<instance>.conf, generated at image build from
# schedulers.tsv), the kernel's sysfs and /var/lib/octarine-os. No user-writable file and no user environment is read here.
#
# Instance names are attacker-chosen (systemd passes whatever follows `scx@`): scx_find_instance matches the name EXACTLY against
# the registry files it finds (it never builds a path from the name) and only then returns the registry file.
#
# The paths can be moved with OCTARINE_SCX_* variables for the tests; systemd units run with a clean environment, so nothing
# of the kind is set in production.

SCX_REGISTRY=${OCTARINE_SCX_REGISTRY:-/usr/share/octarine-os/schedulers.d}
SCX_SYSFS=${OCTARINE_SCX_SYSFS:-/sys/kernel/sched_ext}
SCX_BTF=${OCTARINE_SCX_BTF:-/sys/kernel/btf/vmlinux}
SCX_STATE=${OCTARINE_SCX_STATE:-/var/lib/octarine-os}
SCX_MAX_FAILURES=${OCTARINE_SCX_MAX_FAILURES:-3}
SCX_VERIFY_SECONDS=${OCTARINE_SCX_VERIFY_SECONDS:-5}

scx_log() { logger -t octarine-scx -- "$*" 2>/dev/null || true; echo "octarine-scx: $*" >&2; }

scx_kernel() { echo "${OCTARINE_SCX_KERNEL:-$(uname -r)}"; }

# scx_reg_get <registry file> <KEY>: the value of KEY=value (first match), parsed, never sourced
scx_reg_get() {
    awk -v k="$2" 'index($0, k "=") == 1 { print substr($0, length(k) + 2); exit }' "$1"
}

# scx_find_instance <name>: prints the registry file of the exact instance name and returns 0; returns 1 otherwise.
# The name must look like an instance (lower case letters, digits, underscore) AND equal the name of a registry file.
scx_find_instance() {
    local want=${1-} f base
    [[ "${want}" =~ ^[a-z0-9][a-z0-9_]*$ ]] || return 1
    for f in "${SCX_REGISTRY}"/*.conf; do
        [[ -f "${f}" ]] || continue
        base=${f##*/}
        if [[ "${base%.conf}" == "${want}" ]]; then
            printf '%s\n' "${f}"
            return 0
        fi
    done
    return 1
}

# scx_instances: the instance names of the registry, one per line
scx_instances() {
    local f base
    for f in "${SCX_REGISTRY}"/*.conf; do
        [[ -f "${f}" ]] || continue
        base=${f##*/}
        printf '%s\n' "${base%.conf}"
    done
}

scx_marker_dir() { echo "${SCX_STATE}/scx-disabled"; }
scx_failure_dir() { echo "${SCX_STATE}/scx-failures"; }
