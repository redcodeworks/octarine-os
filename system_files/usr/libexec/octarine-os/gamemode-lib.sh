# shellcheck shell=bash
# Shared code of the GameMode hooks gamemode-start and gamemode-end. Sourced, never run. The hooks run as the logged-in user, so this
# is the ONLY place that reads the user's file ~/.config/octarine-os/scheduler.conf; the root units never read it.
#
# The per-user choice is GAMEMODE_SCHED=skip|none|<instance>, parsed (never sourced) from that file; absent means skip. An
# instance name must equal a registry entry (/usr/share/octarine-os/schedulers.d). Switching uses `systemctl start|stop
# scx@<instance>.service`, which the polkit rule 50-octarine-scx.rules allows for the active wheel user without a prompt.
#
# Paths can be moved with OCTARINE_* variables for the tests.

SCX_REGISTRY=${OCTARINE_SCX_REGISTRY:-/usr/share/octarine-os/schedulers.d}
SCX_SYSFS=${OCTARINE_SCX_SYSFS:-/sys/kernel/sched_ext}
USER_CONF=${OCTARINE_SCX_USER_CONF:-${XDG_CONFIG_HOME:-${HOME:-/nonexistent}/.config}/octarine-os/scheduler.conf}
RUN_DIR=${OCTARINE_SCX_RUN_DIR:-${XDG_RUNTIME_DIR:-/tmp}/octarine-scx}
SYSTEMCTL_TIMEOUT=${OCTARINE_SCX_SYSTEMCTL_TIMEOUT:-9}
ACTIVE_WAIT=${OCTARINE_SCX_ACTIVE_WAIT:-6}

log() { logger -t octarine-scx -- "$*" 2> /dev/null || true; echo "octarine-scx: $*" >&2; }

notify_failure() {
    log "$*"
    if command -v notify-send > /dev/null 2>&1; then
        notify-send -a "octarineOS" "Scheduler switch failed" "$*" 2> /dev/null || true
    fi
}

# registered <name>: exact match against the registry file names
registered() {
    local want=${1-} f
    [[ "${want}" =~ ^[a-z0-9][a-z0-9_]*$ ]] || return 1
    for f in "${SCX_REGISTRY}"/*.conf; do
        [[ -f "${f}" ]] || continue
        [[ "${f##*/}" == "${want}.conf" ]] && return 0
    done
    return 1
}

instances() {
    local f
    for f in "${SCX_REGISTRY}"/*.conf; do
        [[ -f "${f}" ]] || continue
        f=${f##*/}
        printf '%s\n' "${f%.conf}"
    done
}

# chosen: the validated GAMEMODE_SCHED value (skip when absent or invalid)
chosen() {
    local v=""
    if [[ -r "${USER_CONF}" ]]; then
        v=$(awk -F= '$1 == "GAMEMODE_SCHED" { v = $2 } END { print v }' "${USER_CONF}" | tr -d '[:space:]"'"'")
    fi
    case "${v}" in
        "" | skip) echo skip ;;
        none) echo none ;;
        *)
            if registered "${v}"; then echo "${v}"; else log "ignoring GAMEMODE_SCHED='${v}' (not a registered scheduler)"; echo skip; fi
            ;;
    esac
}

# active_instance: the loaded scheduler's instance name, empty for the kernel default
active_instance() {
    local ops
    ops=$(cat "${SCX_SYSFS}/root/ops" 2> /dev/null) || return 0
    if registered "${ops}"; then echo "${ops}"; fi
}

# boot_instance: the instance `systemctl is-enabled` reports enabled, empty for none
boot_instance() {
    local i
    while IFS= read -r i; do
        if [[ "$(systemctl is-enabled "scx@${i}.service" 2> /dev/null)" == enabled ]]; then
            echo "${i}"
            return 0
        fi
    done < <(instances)
}

sctl() { timeout "${SYSTEMCTL_TIMEOUT}" systemctl "$@"; }

# wait_active <instance>: true when it is the loaded scheduler within ACTIVE_WAIT seconds
wait_active() {
    local want=$1 t=0
    while ((t < ACTIVE_WAIT * 5)); do
        [[ "$(active_instance)" == "${want}" ]] && return 0
        sleep 0.2
        t=$((t + 1))
    done
    return 1
}

marker() { echo "${RUN_DIR}/switched"; }

# restore_boot: bring back the boot choice (the enabled instance, or the kernel default when none is enabled)
restore_boot() {
    local boot cur
    boot=$(boot_instance)
    cur=$(active_instance)
    if [[ -n "${boot}" ]]; then
        if [[ "${cur}" == "${boot}" ]]; then
            log "boot scheduler ${boot} is already active"
        elif sctl start "scx@${boot}.service" && wait_active "${boot}"; then
            log "restored boot scheduler ${boot}"
        else
            notify_failure "could not restore the boot scheduler ${boot}; the kernel default or the current one stays (ujust scheduler --status)"
        fi
    elif [[ -n "${cur}" ]]; then
        if sctl stop "scx@${cur}.service"; then log "stopped ${cur}: back to the kernel default scheduler"; else notify_failure "could not stop scx@${cur}.service"; fi
    fi
}

scheduler_start() {
    local choice cur boot
    choice=$(chosen)
    [[ "${choice}" != skip ]] || return 0
    mkdir -p "${RUN_DIR}" 2> /dev/null
    cur=$(active_instance)
    boot=$(boot_instance)
    if [[ "${choice}" == none ]]; then
        if [[ -z "${cur}" ]]; then log "no scheduler is active: nothing to stop"; return 0; fi
        if sctl stop "scx@${cur}.service"; then echo none > "$(marker)"; log "stopped ${cur} for the game: kernel default scheduler"; else notify_failure "could not stop scx@${cur}.service"; fi
        return 0
    fi
    if [[ "${cur}" == "${choice}" ]]; then
        # already the game choice: if it is not also the boot choice, a crashed session may have left it; take the restore duty over
        if [[ "${boot}" != "${choice}" ]]; then echo "${choice}" > "$(marker)"; fi
        log "${choice} is already active: nothing to switch"
        return 0
    fi
    # GameMode calls start only for the FIRST game, so a scheduler left over from a crashed session (gamemoded died, end never ran)
    # is repaired here: when a scheduler is running that is neither the boot choice nor the requested one, go back to the boot choice first
    if [[ -n "${cur}" && "${cur}" != "${boot}" ]]; then
        log "stale scheduler ${cur} is running (boot choice: ${boot:-none}); restoring the boot choice before switching"
        restore_boot
    fi
    if sctl start "scx@${choice}.service" && wait_active "${choice}"; then
        echo "${choice}" > "$(marker)"
        log "switched to ${choice} for the game (boot choice: ${boot:-none})"
    else
        notify_failure "scheduler ${choice} did not start; restoring the boot choice"
        restore_boot
    fi
}

scheduler_end() {
    if [[ ! -f "$(marker)" ]]; then log "nothing to restore"; return 0; fi
    restore_boot
    rm -f "$(marker)"
}

# with_lock <function>: several games overlap; serialize the switch (GameMode itself counts games, start for the first one and end
# after the last one)
with_lock() {
    mkdir -p "${RUN_DIR}" 2> /dev/null
    if command -v flock > /dev/null 2>&1; then
        (
            flock -w 10 9 || { log "could not take the lock; skipping"; exit 0; }
            "$1"
        ) 9> "${RUN_DIR}/lock"
    else
        "$1"
    fi
}
