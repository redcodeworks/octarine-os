# shellcheck shell=bash
# Pending kernel-argument changes of an ostree system, shared by `ujust hardware-setup`, `ujust virthost-setup`, `ujust update` and
# `ujust switch-image`. Source this file; it is never run on its own:
#
#   kargs_lib="${OCTARINE_KARGS_LIB:-/usr/share/octarine-os/lib/kargs.sh}"
#   . "$kargs_lib"
#
# THE PITFALL (seen on nox, 2026-11-14): `sudo rpm-ostree kargs --append-if-missing=ARG` does not change the running system. It creates a
# PENDING deployment of the booted image that carries the argument. A later `bootc upgrade` stages the new image from the BOOTED
# deployment (without the argument) and REPLACES the pending one, so after the next reboot the argument is gone. The recipes did the
# right thing; the update erased the result. Rule: reboot between applying a kernel argument and the next image update.
#
# What is read (no sudo, nothing is written):
#   booted    $OCTARINE_CMDLINE (default /proc/cmdline)
#   next boot `rpm-ostree kargs`, the arguments of the deployment that boots next (the pending one when there is one)
#   pending   `rpm-ostree status --json`: .deployments[0].booted == false means a pending (staged) deployment exists. The JSON exposes no
#             per-deployment kernel arguments, so the arguments are compared as above. When the field is missing or the JSON is not
#             readable the gate is skipped and the comparison alone decides.
# Limits: an argument that the bootloader adds for one boot or a hand edit in the GRUB menu only counts while a pending deployment
# exists (when the JSON is readable); BOOT_IMAGE=, initrd= and ostree= are never compared.
#
#   kargs_pending_change   prints "+arg" / "-arg" lines and returns 0 when a pending deployment has different arguments than the booted one
#   kargs_pending_arg ARG  returns 0 when ARG (a word, or KEY= for any value) is in the next boot's arguments but not in the booted ones
#   kargs_notice ARG...    the text a recipe prints after it applied arguments

kargs_words() { tr -s ' \t\n' '\n' | grep -vE '^(BOOT_IMAGE|initrd|ostree)=|^$' | sort -u; }
kargs_booted() { kargs_words < "${OCTARINE_CMDLINE:-/proc/cmdline}" 2> /dev/null; }
kargs_next() { rpm-ostree kargs 2> /dev/null | kargs_words; }

# 0 pending deployment exists, 1 none (the booted one is the newest), 2 unknown
kargs_has_pending() {
    local b
    b=$(rpm-ostree status --json 2> /dev/null | jq -r '.deployments[0].booted | if . == null then "unknown" else tostring end' 2> /dev/null) || b=unknown
    case "${b}" in false) return 0 ;; true) return 1 ;; *) return 2 ;; esac
}

kargs_pending_change() {
    local booted next gate diff
    kargs_has_pending
    gate=$?
    [[ "${gate}" != 1 ]] || return 1
    booted=$(kargs_booted) || return 1
    next=$(kargs_next)
    [[ -n "${booted}" && -n "${next}" ]] || return 1
    diff=$(diff <(printf '%s\n' "${booted}") <(printf '%s\n' "${next}") | sed -n 's/^< /-/p; s/^> /+/p')
    [[ -n "${diff}" ]] || return 1
    printf '%s\n' "${diff}"
}

kargs_pending_arg() {
    local want=$1 w
    case "${want}" in
        *=) while IFS= read -r w; do [[ "${w}" == "${want}"* ]] && return 1; done < <(kargs_booted)
            kargs_next | grep -q -- "^${want}" ;;
        *) kargs_booted | grep -qxF -- "${want}" && return 1; kargs_next | grep -qxF -- "${want}" ;;
    esac
}

kargs_notice() {
    local a grepline=""
    for a in "$@"; do grepline="${grepline:+${grepline} && }grep -qw -- ${a} /proc/cmdline"; done
    echo "Reboot before the next image update (bootc upgrade, ujust update, switch-image, automatic update staging): a newer staged image replaces this pending change and drops the argument. Check after the reboot: ${grepline}"
}

# kargs_confirm_update <mode> <what>: before an image update or switch. mode: yes (warn, go on), no (plan only: warn, return 0) or ask
# (warn, ask with default no). Returns 0 to go on, 1 when the user declined. Prints nothing when no kernel-argument change is pending.
kargs_confirm_update() {
    local mode=$1 what=$2 d
    d=$(kargs_pending_change) || return 0
    echo "WARNING: a pending kernel-argument change would be lost by ${what}:"
    printf '%s\n' "${d}" | sed 's/^/  /'
    echo "  A newer staged image replaces the pending deployment that carries it (the arguments are taken from the booted deployment). Reboot first, then update."
    case "${mode}" in
        yes) echo "  --yes: going on anyway."; return 0 ;;
        no) return 0 ;;
    esac
    if declare -F menu_confirm > /dev/null; then menu_confirm "Go on anyway and lose the pending kernel arguments?" n; else return 1; fi
}
