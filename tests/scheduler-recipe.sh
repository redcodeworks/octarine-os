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
    is-active) i=${2#scx@}; i=${i%.service}; [ "$(sed 's/_1\.1\.4_x86_64_unknown_linux_gnu$//' "$SCHEDULER_SYSFS/root/ops" 2>/dev/null)" = "$i" ] && { echo active; exit 0; }; echo inactive; exit 3 ;;
    start) [ "${FAKE_SYSTEMCTL_FAIL:-}" = 1 ] && exit 1
        i=${2#scx@}; i=${i%.service}; mkdir -p "$SCHEDULER_SYSFS/root"; echo enabled >"$SCHEDULER_SYSFS/state"; echo "${i}_1.1.4_x86_64_unknown_linux_gnu" >"$SCHEDULER_SYSFS/root/ops"; exit 0 ;;
    stop) [ "${FAKE_SYSTEMCTL_FAIL:-}" = 1 ] && exit 1
        i=${2#scx@}; i=${i%.service}; [ "$(sed 's/_1\.1\.4_x86_64_unknown_linux_gnu$//' "$SCHEDULER_SYSFS/root/ops" 2>/dev/null)" = "$i" ] && { rm -f "$SCHEDULER_SYSFS/root/ops"; echo disabled >"$SCHEDULER_SYSFS/state"; }; exit 0 ;;
esac
exit 0
F
cat >"$bin/sudo" <<'F'
#!/usr/bin/env bash
echo "sudo $*" >>"$LOG"
[ "$1" = -v ] && exit "${FAKE_SUDO_V_FAIL:-0}"
[ "${FAKE_SUDO_FAIL:-}" = 1 ] && exit 1
sysfs=$SCHEDULER_SYSFS
setops() { mkdir -p "$sysfs/root"; echo enabled >"$sysfs/state"; echo "${1}_1.1.4_x86_64_unknown_linux_gnu" >"$sysfs/root/ops"; }
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
        disable) grep -vx "$inst" "$ENABLED_FILE" >"$ENABLED_FILE.t"; mv "$ENABLED_FILE.t" "$ENABLED_FILE"; case " $* " in *" --now "*) [ "$(sed 's/_1\.1\.4_x86_64_unknown_linux_gnu$//' "$sysfs/root/ops" 2>/dev/null)" = "$inst" ] && { rm -f "$sysfs/root/ops"; echo disabled >"$sysfs/state"; } ;; esac ;;
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

reset; FAKE_UID=0 run '' --boot rusty
check "root is refused (exit 1), nothing run" bash -c "[ $rc = 1 ] && grep -q 'not as root' '$root/out' && ! grep -q sudo '$LOG'"

# ---- --boot
reset; run '' --boot rusty
check "--boot NAME: enable --now through sudo, exactly one sudo command, the unit named, undo line printed" bash -c "[ $rc = 0 ] && [ \$(grep -c '^sudo systemctl' '$LOG') = 1 ] && grep -qx 'sudo systemctl enable --now scx@rusty.service' '$LOG' && grep -q 'ujust scheduler --boot none' '$root/out' && grep -q 'uses sudo' '$root/out'"
reset; FAKE_SUDO_FAIL=1 run '' --boot rusty
check "--boot, sudo fails: FAILED, exit 1, the exact command printed, never retried" bash -c "[ $rc = 1 ] && grep -q 'FAILED' '$root/out' && grep -q 'Failed: sudo systemctl enable --now scx@rusty.service' '$root/out' && [ \$(grep -c '^sudo systemctl' '$LOG') = 1 ]"
seed_running() { mkdir -p "$root/sys/root"; echo enabled >"$root/sys/state"; echo "${1}_1.1.4_x86_64_unknown_linux_gnu" >"$root/sys/root/ops"; echo "$1" >"$ENABLED_FILE"; }
reset; seed_running rusty; mkdir -p "$root/state/scx-disabled"; echo 6.99.0-test >"$root/state/scx-disabled/rusty"; rm -f "$root/sys/root/ops"; echo disabled >"$root/sys/state"
run '' --boot rusty
check "--boot NAME enabled with the crash-loop marker of this kernel: NOT applied, FAILED, the reason names the marker and the kernel, the marker is NOT removed silently, exit 1" bash -c "[ $rc = 1 ] && grep -q 'FAILED' '$root/out' && ! grep -q 'applied' '$root/out' && grep -q 'disabled for this kernel (6.99.0-test)' '$root/out' && [ -f '$root/state/scx-disabled/rusty' ] && ! grep -q 'sudo rm' '$LOG' && grep -q 'sudo rm -- $root/state/scx-disabled/rusty' '$root/out'"
export OCTARINE_MENU_FORCE_TTY=1; GUM_CONFIRM_RC=1 run '' --boot rusty
check "marker: asked, declined (default no): nothing removed, still FAILED" bash -c "[ $rc = 1 ] && grep -q '^gum confirm' '$LOG' && [ -f '$root/state/scx-disabled/rusty' ] && ! grep -q 'sudo rm' '$LOG'"
GUM_CONFIRM_RC=0 run '' --boot rusty
check "marker: asked and accepted: sudo rm of exactly that marker, then start; applied only because it runs" bash -c "[ $rc = 0 ] && grep -qx 'sudo rm -- $root/state/scx-disabled/rusty' '$LOG' && [ ! -e '$root/state/scx-disabled/rusty' ] && grep -qx 'sudo systemctl start scx@rusty.service' '$LOG' && grep -q 'applied' '$root/out'"
unset OCTARINE_MENU_FORCE_TTY
reset; seed_running rusty; mkdir -p "$root/state/scx-disabled"; echo 6.99.0-test >"$root/state/scx-disabled/rusty"; rm -f "$root/sys/root/ops"
run '' --boot rusty --yes
check "marker with --yes: never removed without the question" bash -c "[ $rc = 1 ] && [ -f '$root/state/scx-disabled/rusty' ] && ! grep -q 'sudo rm' '$LOG' && ! grep -q '^gum confirm' '$LOG'"
reset; run '' --boot rusty --no
check "--no: the plan only, nothing run or written" bash -c "[ $rc = 0 ] && grep -q 'plan only' '$root/out' && ! grep -q sudo '$LOG'"
reset; run '' --yes
check "--yes alone changes nothing" bash -c "[ $rc = 0 ] && ! grep -q sudo '$LOG' && [ ! -e '$conf' ]"
setops() { mkdir -p "$root/sys/root"; echo enabled >"$root/sys/state"; echo "${1}_1.1.4_x86_64_unknown_linux_gnu" >"$root/sys/root/ops"; }
reset; setops lavd; echo rusty >"$ENABLED_FILE"; FAKE_SYSTEMCTL_FAIL=1 FAKE_SUDO_FAIL=1 run '' --restore
check "restore, sudo fails too: FAILED with the exact command, exit 1, never retried" bash -c "[ $rc = 1 ] && grep -q 'Failed: sudo systemctl start scx@rusty.service' '$root/out' && [ \$(grep -c '^sudo systemctl' '$LOG') = 1 ] && ! grep -q 'sudo systemctl stop' '$LOG'"
reset; FAKE_UID=0 run '' --restore
check "restore refuses root" test "$rc" = 1
first_item=$(grep '^ugum arg: ' "$LOG" | sed -n 2p | sed 's/^ugum arg: //')
GUM_CONFIRM_RC=1 PATH="$bin:$sysbin" "$REAL_JUST" --justfile "$justfile" --working-directory "$root" scheduler </dev/null >"$root/out" 2>&1
echo
echo "passed: $pass, failed: $failn"
[ "$failn" = 0 ]
