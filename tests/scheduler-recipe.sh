#!/usr/bin/env bash
# Tests for `ujust scheduler` (system_files/usr/share/ublue-os/just/60-custom.just): the flags, the two-step menu with every
# description, idempotence, the sudo steps, the GameMode file, --status and --list. systemctl, sudo, id, ugum and gum are fakes on a
# restricted PATH; the registry, sysfs, state dir and user file are temp dirs (SCHEDULER_* variables). Nothing real changes.
# Needs: bash, just. Run: tests/scheduler-recipe.sh
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
justfile="$here/system_files/usr/share/ublue-os/just/60-custom.just"
root=$(mktemp -d)
trap 'rm -rf -- "${root:?}"' EXIT
pass=0
failn=0
rc=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { failn=$((failn + 1)); echo "FAIL $1"; sed 's/^/     /' "$root/out" 2>/dev/null; echo "     rc=$rc"; }
check() { local d=$1; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
has() { grep -qF -- "$1" "$root/out"; }
hasnt() { ! grep -qF -- "$1" "$root/out"; }
logged() { grep -qF -- "$1" "$root/log" 2>/dev/null; }
notlogged() { ! grep -qF -- "$1" "$root/log" 2>/dev/null; }
bin="$root/bin"
sysbin="$root/sysbin"
mkdir -p "$bin" "$sysbin"
REAL_JUST=$(command -v just)
for c in bash sh env cat grep awk sed cut tr date head sort dirname basename wc chmod printf mkdir mktemp mv rm ls touch tee readlink timeout; do
    p=$(command -v "$c") && ln -sf "$p" "$sysbin/$c"
done
export LOG="$root/log" HOME="$root/home" UGUMQ="$root/ugumq" GUMQ="$root/gumq" OCTARINE_MENU_LIB="$here/system_files/usr/share/octarine-os/lib/menu.sh"
export SCHEDULER_REGISTRY="$root/reg" SCHEDULER_SYSFS="$root/sys" SCHEDULER_STATE_DIR="$root/state" SCHEDULER_USER_CONF="$root/home/.config/octarine-os/scheduler.conf"
export ENABLED_FILE="$root/enabled" SCHEDULER_WAIT=0 SCHEDULER_BTF="$root/btf-vmlinux" SCHEDULER_KERNEL=6.99.0-test
: >"$root/btf-vmlinux"
unset XDG_CONFIG_HOME
mkdir -p "$HOME" "$root/reg" "$root/sys" "$root/state"
long="Earliest-deadline-first scheduler focused on fairness among tasks and performance predictability in every workload you run"
for n in rusty lavd flash; do
    d="Test scheduler $n"
    [ "$n" = flash ] && d="$long"
    printf '# test\nNAME=scx_%s\nINSTANCE=%s\nBINARY=/usr/bin/scx_%s\nDESCRIPTION=%s\nMIN_KERNEL=\nFLAGS=\n' "$n" "$n" "$n" "$d" >"$root/reg/$n.conf"
done

cat >"$bin/systemctl" <<'F'
#!/usr/bin/env bash
echo "systemctl $*" >>"$LOG"
case "$1" in
    is-enabled) grep -qx "${2#scx@}" <(sed 's/$/.service/' "$ENABLED_FILE") && { echo enabled; exit 0; }; echo disabled; exit 1 ;;
    is-active) i=${2#scx@}; i=${i%.service}; [ "$(cat "$SCHEDULER_SYSFS/root/ops" 2>/dev/null)" = "$i" ] && { echo active; exit 0; }; echo inactive; exit 3 ;;
    start) [ "${FAKE_SYSTEMCTL_FAIL:-}" = 1 ] && exit 1
        i=${2#scx@}; i=${i%.service}; mkdir -p "$SCHEDULER_SYSFS/root"; echo enabled >"$SCHEDULER_SYSFS/state"; echo "$i" >"$SCHEDULER_SYSFS/root/ops"; exit 0 ;;
    stop) [ "${FAKE_SYSTEMCTL_FAIL:-}" = 1 ] && exit 1
        i=${2#scx@}; i=${i%.service}; [ "$(cat "$SCHEDULER_SYSFS/root/ops" 2>/dev/null)" = "$i" ] && { rm -f "$SCHEDULER_SYSFS/root/ops"; echo disabled >"$SCHEDULER_SYSFS/state"; }; exit 0 ;;
esac
exit 0
F
cat >"$bin/sudo" <<'F'
#!/usr/bin/env bash
echo "sudo $*" >>"$LOG"
[ "$1" = -v ] && exit "${FAKE_SUDO_V_FAIL:-0}"
[ "${FAKE_SUDO_FAIL:-}" = 1 ] && exit 1
sysfs=$SCHEDULER_SYSFS
setops() { mkdir -p "$sysfs/root"; echo enabled >"$sysfs/state"; echo "$1" >"$sysfs/root/ops"; }
startit() { # a start of INST: Conflicts= stops the running one first; a failing start leaves nothing running
    rm -f "$sysfs/root/ops"; echo disabled >"$sysfs/state"
    case " ${FAKE_START_FAIL:-} " in *" $1 "*) return 1 ;; esac
    [ -e "$SCHEDULER_BTF" ] || return 0
    [ -f "$SCHEDULER_STATE_DIR/scx-disabled/$1" ] && return 0
    setops "$1"
}
if [ "$1" = rm ]; then shift; [ "$1" = -- ] && shift; rm -f -- "$1"; exit 0; fi
if [ "$1" = systemctl ]; then
    verb=$2
    unit=${@: -1}
    inst=${unit#scx@}; inst=${inst%.service}
    case "$verb" in
        enable) grep -qx "$inst" "$ENABLED_FILE" || echo "$inst" >>"$ENABLED_FILE"; case " $* " in *" --now "*) startit "$inst" || { [ "${FAKE_START_RC:-0}" = 1 ] && exit 1; } ;; esac ;;
        disable) grep -vx "$inst" "$ENABLED_FILE" >"$ENABLED_FILE.t"; mv "$ENABLED_FILE.t" "$ENABLED_FILE"; case " $* " in *" --now "*) [ "$(cat "$sysfs/root/ops" 2>/dev/null)" = "$inst" ] && { rm -f "$sysfs/root/ops"; echo disabled >"$sysfs/state"; } ;; esac ;;
        start) startit "$inst" ;;
    esac
fi
exit 0
F
cat >"$bin/journalctl" <<'F'
#!/usr/bin/env bash
echo "journalctl $*" >>"$LOG"
echo "scx_fake: could not load the BPF program"
F
cat >"$bin/id" <<'F'
#!/usr/bin/env bash
[ "$1" = -u ] && { echo "${FAKE_UID:-1000}"; exit 0; }
exit 0
F
cat >"$bin/uname" <<'F'
#!/usr/bin/env bash
echo 6.99.0-test
F
cat >"$bin/ugum" <<'F'
#!/usr/bin/env bash
echo "ugum $*" >>"$LOG"
printf 'ugum arg: %s\n' "$@" >>"$LOG"
n=$(( $(cat "$UGUMQ.n" 2>/dev/null || echo 0) + 1 )); echo "$n" >"$UGUMQ.n"
[ -f "$UGUMQ.$n" ] && cat "$UGUMQ.$n"
exit 0
F
cat >"$bin/gum" <<'F'
#!/usr/bin/env bash
echo "gum $*" >>"$LOG"
case "$1" in confirm) exit "${GUM_CONFIRM_RC:-0}" ;; style) echo "${@: -1}" ;; esac
exit 0
F
chmod +x "$bin"/*

reset() {
    rm -f "${root:?}"/ugumq.* "${root:?}"/gumq.*; unset OCTARINE_MENU_FORCE_TTY GUM_CONFIRM_RC FAKE_SUDO_FAIL FAKE_UID FAKE_SYSTEMCTL_FAIL FAKE_GAMEMODED FAKE_SUDO_V_FAIL FAKE_START_FAIL FAKE_START_RC; : >"$root/btf-vmlinux"
    rm -rf "${HOME:?}/.config"
    rm -rf "${root:?}/state"; mkdir -p "$root/state"
    rm -rf "${root:?}/sys"; mkdir -p "$root/sys"
    : >"$LOG"; : >"$ENABLED_FILE"
}
ugumq() { printf '%b' "$2" >"$root/ugumq.$1"; }
run() { # stdin text, args...
    local input=$1
    shift
    printf '%b' "$input" | PATH="$bin:$sysbin" "$REAL_JUST" --justfile "$justfile" --working-directory "$root" scheduler "$@" >"$root/out" 2>&1
    rc=$?
}
conf="$SCHEDULER_USER_CONF"

# ---- shape
reset; run '' --help
check "help: usage text, exit 0, names every flag" bash -c "[ $rc = 0 ] && grep -q -- '--boot' '$root/out' && grep -q -- '--gamemode' '$root/out' && grep -q -- '--status' '$root/out' && grep -q -- '--list' '$root/out' && grep -q -- '--yes' '$root/out' && grep -q -- '--no' '$root/out'"
check "recipe: group Setup, a single comment line, placed above the toolbox recipe" bash -c "awk '/^# Choose a sched_ext CPU scheduler/{c=NR} /^\\[group\\(.Setup.\\)\\]/ && c && NR==c+1 {g=1} /^scheduler \\*args:/{s=NR} /^toolbox \\*args:/{t=NR} END{exit !(g && s && t && s<t)}' '$justfile' && [ \$(grep -n '^# Choose a sched_ext CPU scheduler' '$justfile' | head -1 | cut -d: -f2 | wc -c) -lt 90 ]"
check "recipe: no sudo outside the one boot step, none after the toolbox recipe from this change" bash -c "! sed -n '/^toolbox \\*args:/,\$p' '$justfile' | grep -q 'scx@'"
reset; run '' --bogus
check "unknown option: exit 2 with usage" test "$rc" = 2
reset; run '' --boot nosuch
check "unknown scheduler name for --boot: exit 2, lists the known ones, nothing run" bash -c "[ $rc = 2 ] && grep -q 'Known: none flash lavd rusty' '$root/out' && ! grep -q sudo '$LOG'"
reset; run '' --gamemode ../x
check "unknown name for --gamemode: exit 2, nothing written" bash -c "[ $rc = 2 ] && [ ! -e '$conf' ]"
reset; FAKE_UID=0 run '' --boot rusty
check "root is refused (exit 1), nothing run" bash -c "[ $rc = 1 ] && grep -q 'not as root' '$root/out' && ! grep -q sudo '$LOG'"
reset; rm -rf "${root:?}/sys"; run '' --boot rusty
check "no /sys/kernel/sched_ext: not applicable, exit 0, nothing run" bash -c "[ $rc = 0 ] && grep -q 'Not applicable' '$root/out' && ! grep -q sudo '$LOG'"
mkdir -p "$root/sys"

# ---- --list
reset; run '' --list
check "--list: every registry entry with its FULL description, none and skip explained" bash -c "[ $rc = 0 ] && grep -q 'rusty' '$root/out' && grep -q 'Test scheduler lavd' '$root/out' && grep -qF '$long' '$root/out' && grep -q 'none ' '$root/out' && grep -q 'skip ' '$root/out' && grep -q 'EEVDF' '$root/out'"

# ---- --status
reset; echo enabled >"$root/sys/state"; mkdir -p "$root/sys/root"; echo lavd >"$root/sys/root/ops"; echo rusty >"$ENABLED_FILE"
mkdir -p "$(dirname "$conf")"; echo 'GAMEMODE_SCHED=flash' >"$conf"
mkdir -p "$root/state/scx-disabled"; echo 6.99.0-test >"$root/state/scx-disabled/rusty"
run '' --status
check "--status: sched_ext state, the active scheduler, the boot unit, the GameMode choice and the disabled-for-this-kernel marker" bash -c "[ $rc = 0 ] && grep -q 'sched_ext state:   enabled' '$root/out' && grep -q 'active scheduler:  lavd' '$root/out' && grep -q 'boot choice:       rusty' '$root/out' && grep -q 'GameMode choice:   flash' '$root/out' && grep -q 'rusty (disabled for this kernel 6.99.0-test' '$root/out'"
reset; echo disabled >"$root/sys/state"; run '' --status
check "--status with nothing set: kernel default, boot none, GameMode skip, no markers" bash -c "grep -q 'none (the kernel' '$root/out' && grep -q 'boot choice:       none' '$root/out' && grep -q 'GameMode choice:   skip' '$root/out' && grep -q 'disabled markers: *none' '$root/out'"

# ---- --boot
reset; run '' --boot rusty
check "--boot NAME: enable --now through sudo, exactly one sudo command, the unit named, undo line printed" bash -c "[ $rc = 0 ] && [ \$(grep -c '^sudo systemctl' '$LOG') = 1 ] && grep -qx 'sudo systemctl enable --now scx@rusty.service' '$LOG' && grep -q 'ujust scheduler --boot none' '$root/out' && grep -q 'uses sudo' '$root/out'"
run '' --boot rusty
check "--boot NAME again: already done, no sudo" bash -c "[ $rc = 0 ] && grep -q 'already done' '$root/out' && [ \$(grep -c '^sudo systemctl' '$LOG') = 1 ]"
: >"$LOG"; run '' --boot lavd
check "--boot other: the enabled one is disabled first (with --now), then the new one enabled" bash -c "[ $rc = 0 ] && grep -qx 'sudo systemctl disable --now scx@rusty.service' '$LOG' && grep -qx 'sudo systemctl enable --now scx@lavd.service' '$LOG' && [ \"\$(cat '$ENABLED_FILE')\" = lavd ] && grep -q 'ujust scheduler --boot rusty' '$root/out'"
: >"$LOG"; run '' --boot none
check "--boot none: disable --now of the enabled one only, nothing enabled" bash -c "[ $rc = 0 ] && grep -qx 'sudo systemctl disable --now scx@lavd.service' '$LOG' && ! grep -q 'enable --now' '$LOG' && [ ! -s '$ENABLED_FILE' ]"
: >"$LOG"; run '' --boot none
check "--boot none again: already done, no sudo" bash -c "grep -q 'already done' '$root/out' && ! grep -q sudo '$LOG'"
reset; FAKE_SUDO_FAIL=1 run '' --boot rusty
check "--boot, sudo fails: FAILED, exit 1, the exact command printed, never retried" bash -c "[ $rc = 1 ] && grep -q 'FAILED' '$root/out' && grep -q 'Failed: sudo systemctl enable --now scx@rusty.service' '$root/out' && [ \$(grep -c '^sudo systemctl' '$LOG') = 1 ]"
# ---- --boot: "applied" means the scheduler really runs (A3)
seed_running() { mkdir -p "$root/sys/root"; echo enabled >"$root/sys/state"; echo "$1" >"$root/sys/root/ops"; echo "$1" >"$ENABLED_FILE"; }
reset; run '' --boot rusty
check "--boot NAME: sudo -v primes sudo once before the first systemctl, then enable, and 'applied' only after it runs" bash -c "[ $rc = 0 ] && [ \$(grep -c '^sudo -v' '$LOG') = 1 ] && [ \$(grep -n '^sudo -v' '$LOG' | cut -d: -f1) -lt \$(grep -n '^sudo systemctl enable' '$LOG' | cut -d: -f1) ] && grep -q 'applied' '$root/out' && grep -q 'not guaranteed' '$root/out'"
seed_running rusty; : >"$LOG"; run '' --boot lavd
check "--boot other: the new instance is enabled and started first, the old one disabled only after (log order)" bash -c "[ $rc = 0 ] && [ \$(grep -n 'enable --now scx@lavd' '$LOG' | cut -d: -f1) -lt \$(grep -n 'disable --now scx@rusty' '$LOG' | cut -d: -f1) ] && [ \"\$(cat '$ENABLED_FILE')\" = lavd ] && [ \"\$(cat '$root/sys/root/ops')\" = lavd ]"
seed_running rusty; : >"$LOG"; rm -f "$root/sys/root/ops"
run '' --boot rusty
check "--boot NAME when it is enabled but NOT running: not 'already set', it is started and verified" bash -c "[ $rc = 0 ] && grep -qx 'sudo systemctl enable --now scx@rusty.service' '$LOG' && grep -q 'enabled but not running' '$root/out' && grep -q applied '$root/out' && ! grep -q 'Already set' '$root/out'"
reset; seed_running rusty; mkdir -p "$root/state/scx-disabled"; echo 6.99.0-test >"$root/state/scx-disabled/rusty"; rm -f "$root/sys/root/ops"; echo disabled >"$root/sys/state"
run '' --boot rusty
check "--boot NAME enabled with the crash-loop marker of this kernel: NOT applied, FAILED, the reason names the marker and the kernel, the marker is NOT removed silently, exit 1" bash -c "[ $rc = 1 ] && grep -q 'FAILED' '$root/out' && ! grep -q 'applied' '$root/out' && grep -q 'disabled for this kernel (6.99.0-test)' '$root/out' && [ -f '$root/state/scx-disabled/rusty' ] && ! grep -q 'sudo rm' '$LOG' && grep -q 'sudo rm -- $root/state/scx-disabled/rusty' '$root/out'"
check "that failure leaves the enable state as it was (it was enabled before: not disabled)" bash -c "grep -qx rusty '$ENABLED_FILE' && ! grep -q 'disable --now scx@rusty' '$LOG'"
export OCTARINE_MENU_FORCE_TTY=1; GUM_CONFIRM_RC=1 run '' --boot rusty
check "marker: asked, declined (default no): nothing removed, still FAILED" bash -c "[ $rc = 1 ] && grep -q '^gum confirm' '$LOG' && [ -f '$root/state/scx-disabled/rusty' ] && ! grep -q 'sudo rm' '$LOG'"
GUM_CONFIRM_RC=0 run '' --boot rusty
check "marker: asked and accepted: sudo rm of exactly that marker, then start; applied only because it runs" bash -c "[ $rc = 0 ] && grep -qx 'sudo rm -- $root/state/scx-disabled/rusty' '$LOG' && [ ! -e '$root/state/scx-disabled/rusty' ] && grep -qx 'sudo systemctl start scx@rusty.service' '$LOG' && grep -q 'applied' '$root/out'"
unset OCTARINE_MENU_FORCE_TTY
reset; seed_running rusty; mkdir -p "$root/state/scx-disabled"; echo 6.99.0-test >"$root/state/scx-disabled/rusty"; rm -f "$root/sys/root/ops"
run '' --boot rusty --yes
check "marker with --yes: never removed without the question" bash -c "[ $rc = 1 ] && [ -f '$root/state/scx-disabled/rusty' ] && ! grep -q 'sudo rm' '$LOG' && ! grep -q '^gum confirm' '$LOG'"
reset; rm -f "$root/btf-vmlinux"; run '' --boot rusty
check "no BTF: the scheduler does not run: FAILED with the BTF reason, the new instance is disabled again, exit 1" bash -c "[ $rc = 1 ] && grep -q 'FAILED' '$root/out' && ! grep -q 'applied' '$root/out' && grep -q 'no BTF' '$root/out' && [ ! -s '$ENABLED_FILE' ] && grep -qx 'sudo systemctl disable --now scx@rusty.service' '$LOG'"
: >"$root/btf-vmlinux"
reset; seed_running rusty; : >"$LOG"; FAKE_START_FAIL=lavd run '' --boot lavd
check "start failure with another scheduler running: FAILED, the OLD instance is kept (still enabled, started again), the new one is not kept, journal lines shown" bash -c "[ $rc = 1 ] && grep -q 'FAILED' '$root/out' && ! grep -q 'applied' '$root/out' && [ \"\$(cat '$ENABLED_FILE')\" = rusty ] && [ \"\$(cat '$root/sys/root/ops')\" = rusty ] && ! grep -q 'disable --now scx@rusty' '$LOG' && grep -qx 'sudo systemctl start scx@rusty.service' '$LOG' && grep -q 'could not load the BPF program' '$root/out' && grep -q 'Restored the previous scheduler: rusty' '$root/out'"
reset; seed_running rusty; : >"$LOG"; FAKE_START_FAIL=lavd FAKE_START_RC=1 run '' --boot lavd
check "start failure that makes systemctl itself fail: same, the old instance is back and no disable of it ran" bash -c "[ $rc = 1 ] && [ \"\$(cat '$ENABLED_FILE')\" = rusty ] && [ \"\$(cat '$root/sys/root/ops')\" = rusty ] && ! grep -q 'disable --now scx@rusty' '$LOG' && grep -q 'FAILED' '$root/out'"
reset; FAKE_SUDO_V_FAIL=1 run '' --boot rusty
check "sudo -v refused: FAILED, no systemctl command ran, exit 1" bash -c "[ $rc = 1 ] && grep -q FAILED '$root/out' && ! grep -q '^sudo systemctl' '$LOG'"
reset; seed_running rusty; : >"$LOG"; run '' --boot rusty
check "--boot NAME enabled AND running: already set, no sudo at all" bash -c "[ $rc = 0 ] && grep -q 'Already set' '$root/out' && ! grep -q '^sudo' '$LOG'"
reset; run '' --boot rusty --no
check "--no: the plan only, nothing run or written" bash -c "[ $rc = 0 ] && grep -q 'plan only' '$root/out' && ! grep -q sudo '$LOG'"
reset; PATH_NO_SUDO=1 run '' --boot=lavd
check "--boot=NAME form works" logged "sudo systemctl enable --now scx@lavd.service"

# ---- --gamemode
reset; run '' --gamemode lavd
check "--gamemode NAME: writes GAMEMODE_SCHED=lavd to the user file, no sudo, an undo line" bash -c "[ $rc = 0 ] && grep -qx 'GAMEMODE_SCHED=lavd' '$conf' && ! grep -q sudo '$LOG' && grep -q 'ujust scheduler --gamemode skip' '$root/out'"
run '' --gamemode lavd
check "--gamemode again: already done, the file unchanged" bash -c "grep -q 'already done' '$root/out' && [ \$(grep -c '^GAMEMODE_SCHED=' '$conf') = 1 ]"
printf 'OTHER=keep\n' >>"$conf"; run '' --gamemode none
check "--gamemode none: the key is replaced (one line), other lines of the file are kept" bash -c "[ \$(grep -c '^GAMEMODE_SCHED=' '$conf') = 1 ] && grep -qx 'GAMEMODE_SCHED=none' '$conf' && grep -qx 'OTHER=keep' '$conf'"
run '' --gamemode skip
check "--gamemode skip is accepted" bash -c "grep -qx 'GAMEMODE_SCHED=skip' '$conf'"
reset; run '' --boot rusty --gamemode flash
check "both flags in one run: the boot step and the GameMode file" bash -c "[ $rc = 0 ] && grep -qx 'sudo systemctl enable --now scx@rusty.service' '$LOG' && grep -qx 'GAMEMODE_SCHED=flash' '$conf'"
reset; run '' --yes
check "--yes alone changes nothing" bash -c "[ $rc = 0 ] && ! grep -q sudo '$LOG' && [ ! -e '$conf' ]"
reset; run ''
check "no flags and no terminal: nothing changes, exit 0, the usage and the names shown, no menu" bash -c "[ $rc = 0 ] && grep -q 'Nothing to change\\|No terminal menu' '$root/out' && ! grep -q 'ugum' '$LOG' && ! grep -q sudo '$LOG'"

# ---- --restore: back to the boot choice after a crashed GameMode session
setops() { mkdir -p "$root/sys/root"; echo enabled >"$root/sys/state"; echo "$1" >"$root/sys/root/ops"; }
cat >"$bin/gamemoded" <<'F'
#!/usr/bin/env bash
case "${FAKE_GAMEMODED:-inactive}" in
    active) echo "gamemode is active" ;;
    silent) ;;
    *) echo "gamemode is inactive" ;;
esac
F
chmod +x "$bin/gamemoded"
reset; setops lavd; : >"$ENABLED_FILE"; run '' --restore
check "restore, stale game scheduler and no boot instance: stops it (no sudo needed), back to the kernel default" bash -c "[ $rc = 0 ] && grep -qx 'systemctl stop scx@lavd.service' '$LOG' && ! grep -q '^sudo' '$LOG' && [ ! -e '$root/sys/root/ops' ] && grep -q 'kernel default' '$root/out'"
reset; setops lavd; echo rusty >"$ENABLED_FILE"; run '' --restore
check "restore, stale game scheduler and a boot instance enabled: starts the boot instance (which replaces the other)" bash -c "[ $rc = 0 ] && grep -qx 'systemctl start scx@rusty.service' '$LOG' && [ \"\$(cat '$root/sys/root/ops')\" = rusty ] && ! grep -q '^sudo' '$LOG'"
reset; setops rusty; echo rusty >"$ENABLED_FILE"; run '' --restore
check "restore, already consistent (boot instance running): nothing to do, nothing run" bash -c "[ $rc = 0 ] && grep -q 'Already consistent' '$root/out' && ! grep -qE 'systemctl (start|stop)' '$LOG'"
reset; : >"$ENABLED_FILE"; echo disabled >"$root/sys/state"; run '' --restore
check "restore, nothing enabled and nothing running: already consistent" bash -c "[ $rc = 0 ] && grep -q 'Already consistent' '$root/out' && ! grep -qE 'systemctl (start|stop)' '$LOG'"
reset; setops lavd; echo rusty >"$ENABLED_FILE"; run '' --restore --no
check "restore --no: prints the plan and changes nothing" bash -c "[ $rc = 0 ] && grep -q 'Plan only' '$root/out' && grep -q 'systemctl start scx@rusty.service' '$root/out' && ! grep -qE '^systemctl (start|stop)' '$LOG' && [ \"\$(cat '$root/sys/root/ops')\" = lavd ]"
reset; setops lavd; echo rusty >"$ENABLED_FILE"; FAKE_SYSTEMCTL_FAIL=1 run '' --restore
check "restore, the unprivileged call is refused: the same command runs once through sudo and the sudo is logged" bash -c "grep -qx 'sudo systemctl start scx@rusty.service' '$LOG' && [ \$(grep -cx 'sudo systemctl start scx@rusty.service' '$LOG') = 1 ]"
reset; setops lavd; echo rusty >"$ENABLED_FILE"; FAKE_SYSTEMCTL_FAIL=1 FAKE_SUDO_FAIL=1 run '' --restore
check "restore, sudo fails too: FAILED with the exact command, exit 1, never retried" bash -c "[ $rc = 1 ] && grep -q 'Failed: sudo systemctl start scx@rusty.service' '$root/out' && [ \$(grep -c '^sudo systemctl' '$LOG') = 1 ] && ! grep -q 'sudo systemctl stop' '$LOG'"
reset; FAKE_UID=0 run '' --restore
check "restore refuses root" test "$rc" = 1
reset; setops lavd; echo rusty >"$ENABLED_FILE"; run '' --status
check "status: the running scheduler differs from the boot choice and gamemoded -s says inactive: the hint names ujust scheduler --restore" bash -c "grep -q 'a game-time scheduler is active but no GameMode session is registered: run ujust scheduler --restore' '$root/out'"
reset; setops lavd; echo rusty >"$ENABLED_FILE"; FAKE_GAMEMODED=active run '' --status
check "status: with an active GameMode session no restore hint is given" bash -c "grep -q 'GameMode reports an active session' '$root/out' && ! grep -q 'run ujust scheduler --restore' '$root/out'"
reset; setops lavd; echo rusty >"$ENABLED_FILE"; FAKE_GAMEMODED=silent run '' --status
check "status: gamemoded -s that answers nothing: the hint is skipped and says why" bash -c "grep -q 'did not answer' '$root/out'"
reset; setops lavd; echo rusty >"$ENABLED_FILE"; mv "$bin/gamemoded" "$root/gamemoded.off"; run '' --status; mv "$root/gamemoded.off" "$bin/gamemoded"
check "status: without gamemoded the hint says the GameMode state is unknown" bash -c "grep -q 'GameMode state unknown' '$root/out'"
reset; setops rusty; echo rusty >"$ENABLED_FILE"; run '' --status
check "status: running equals the boot choice: no note" bash -c "! grep -q 'differs from the boot choice' '$root/out'"

# ---- the menus (a terminal is faked)
export OCTARINE_MENU_FORCE_TTY=1
reset; export OCTARINE_MENU_FORCE_TTY=1
ugumq 1 'rusty: Test scheduler rusty\n'; ugumq 2 'Skip - do not switch when a game starts\n'
printf 'y\n' | PATH="$bin:$sysbin" "$REAL_JUST" --justfile "$justfile" --working-directory "$root" scheduler >"$root/out" 2>&1; rc=$?
check "menu: step 1 offers None plus every registry entry, each with its description; step 2 offers Skip, None and every entry" bash -c "grep -q '^ugum choose' '$LOG' && grep -q 'None - the kernel' '$LOG' && grep -q 'rusty: Test scheduler rusty' '$LOG' && grep -q 'lavd: Test scheduler lavd' '$LOG' && grep -q 'flash: ' '$LOG' && grep -q 'Skip - do not switch' '$LOG' && grep -q 'None - the kernel.s default scheduler (EEVDF) during games' '$LOG'"
check "menu: the pick is applied after the confirmation (sudo enable for the boot choice; skip is stored)" bash -c "[ $rc = 0 ] && grep -qx 'sudo systemctl enable --now scx@rusty.service' '$LOG' && grep -qx 'GAMEMODE_SCHED=skip' '$conf'"
check "menu: every item is one readable line (at most 76 characters) and the long description is shortened with an ellipsis" python3 -I - "$LOG" <<'PY'
import sys
items = [l[len("ugum arg: "):].rstrip("\n") for l in open(sys.argv[1]) if l.startswith("ugum arg: ") and l != "ugum arg: choose\n"]
assert items, "no menu items logged"
assert all(len(i) <= 76 for i in items), [i for i in items if len(i) > 76]
flash = [i for i in items if i.startswith("flash: ")]
assert flash and all(i.endswith("\u2026") for i in flash), flash
short = [i for i in items if i.startswith("lavd: ")]
assert short and not short[0].endswith("\u2026"), short
PY
check "menu: --list still has the full text of the shortened entry" bash -c "PATH='$bin:$sysbin' '$REAL_JUST' --justfile '$justfile' --working-directory '$root' scheduler --list | grep -qF '$long'"
reset; export OCTARINE_MENU_FORCE_TTY=1
echo lavd >"$ENABLED_FILE"; ugumq 1 'lavd: Test scheduler lavd\n'; mkdir -p "$root/sys/root"; echo enabled >"$root/sys/state"; echo lavd >"$root/sys/root/ops"
printf '\n' | PATH="$bin:$sysbin" "$REAL_JUST" --justfile "$justfile" --working-directory "$root" scheduler >"$root/out" 2>&1; rc=$?
check "menu: Esc or an empty answer on both steps: nothing changed, exit 0" bash -c "[ $rc = 0 ] && ! grep -q '^sudo' '$LOG'"
reset; export OCTARINE_MENU_FORCE_TTY=1
echo lavd >"$ENABLED_FILE"
printf 'n\n' | PATH="$bin:$sysbin" "$REAL_JUST" --justfile "$justfile" --working-directory "$root" scheduler >"$root/out" 2>&1
first_item=$(grep '^ugum arg: ' "$LOG" | sed -n 2p | sed 's/^ugum arg: //')
check "menu: the current boot choice (lavd) is the first entry, which ugum preselects" test "$first_item" = "lavd: Test scheduler lavd"
reset; export OCTARINE_MENU_FORCE_TTY=1
ugumq 1 'rusty: Test scheduler rusty\n'; ugumq 2 'None - the kernel'"'"'s default scheduler (EEVDF) during games\n'
GUM_CONFIRM_RC=1 PATH="$bin:$sysbin" "$REAL_JUST" --justfile "$justfile" --working-directory "$root" scheduler </dev/null >"$root/out" 2>&1
check "menu: declining the confirmation changes nothing" bash -c "! grep -q '^sudo' '$LOG' && [ ! -e '$conf' ]"
reset
run '' --boot rusty
check "flags: a named choice opens no menu even on a terminal" notlogged "ugum choose"
unset OCTARINE_MENU_FORCE_TTY

check "the recipe is not part of hardware-setup and never calls it" bash -c "! sed -n '/^scheduler \\*args:/,/^# Create and manage toolboxes/p' '$justfile' | grep -q 'hardware-setup'"

echo
echo "passed: $pass, failed: $failn"
[ "$failn" = 0 ]
