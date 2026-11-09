#!/usr/bin/env bash
# Tests for `ujust user-setup` (system_files/usr/share/ublue-os/just/60-custom.just).
# flatpak, sudo, id, getent and usermod are fakes on PATH; nothing real is changed. Needs: bash, just.
# Run: tests/user-setup.sh
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
justfile="$here/../system_files/usr/share/ublue-os/just/60-custom.just"
root=$(mktemp -d)
trap 'rm -rf -- "$root"' EXIT
pass=0
failn=0
bin="$root/bin"
mkdir -p "$bin"
export LOG="$root/log" INSTALLED="$root/installed" OVR="$root/ovr" GROUPS_OF="$root/groups" FAILAPP="$root/failapp"
export HOME="$root/home"
mkdir -p "$HOME"

cat >"$bin/flatpak" <<'F'
#!/usr/bin/env bash
echo "flatpak $*" >>"$LOG"
case "$1" in
    info) grep -qx -- "$2" "$INSTALLED" ;;
    override)
        if [ "$2 $3" = "--user --show" ]; then
            app=$4
            [ -f "$OVR.$app" ] && cat "$OVR.$app"
            exit 0
        fi
        app=${!#}
        if [ -f "$FAILAPP" ] && grep -qx -- "$app" "$FAILAPP"; then exit 1; fi
        for a in "${@:3:$#-3}"; do
            case "$a" in
                --device=*) echo "devices=${a#--device=};" >>"$OVR.$app" ;;
                --socket=*) echo "sockets=${a#--socket=};" >>"$OVR.$app" ;;
                --nofilesystem=*) echo "filesystems=!${a#--nofilesystem=};" >>"$OVR.$app" ;;
                --filesystem=*) echo "filesystems=${a#--filesystem=};" >>"$OVR.$app" ;;
            esac
        done
        ;;
esac
F
cat >"$bin/sudo" <<'F'
#!/usr/bin/env bash
echo "sudo $*" >>"$LOG"
[ "$1" = sh ] && exit 0
exec "$@"
F
cat >"$bin/usermod" <<'F'
#!/usr/bin/env bash
echo "usermod $*" >>"$LOG"
echo "$2" >>"$GROUPS_OF"
F
cat >"$bin/getent" <<'F'
#!/usr/bin/env bash
case "$2" in gamemode | input | libvirt) echo "$2:x:1:" ;; *) exit 2 ;; esac
F
cat >"$bin/id" <<'F'
#!/usr/bin/env bash
case "$1" in
    -un) echo tester ;;
    -nG) echo "tester wheel $(cat "$GROUPS_OF" 2>/dev/null | tr '\n' ' ')" ;;
    *) [ "$1" = tester ] ;;
esac
F
chmod +x "$bin"/*

reset() { rm -f "$LOG" "$GROUPS_OF" "$FAILAPP" "$OVR".*; : >"$LOG"; : >"$INSTALLED"; }
run() { # stdin text, args...
    local input=$1
    shift
    printf '%b' "$input" | PATH="$bin:$PATH" just --justfile "$justfile" --working-directory "$root" user-setup "$@" >"$root/out" 2>&1
    rc=$?
}
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { failn=$((failn + 1)); echo "FAIL $1"; sed 's/^/     /' "$root/out"; }
check() { local d=$1; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
has() { grep -qF -- "$1" "$root/out"; }
logged() { grep -qF -- "$1" "$LOG"; }
notlogged() { ! grep -qF -- "$1" "$LOG"; }
all_apps='com.valvesoftware.Steam\ncom.usebottles.bottles\nnet.lutris.Lutris\ncom.visualstudio.code\nio.podman_desktop.PodmanDesktop\ncom.google.Chrome\nit.mijorus.gearlever'

# 1. nothing installed, --yes: groups applied, all Flatpak steps skipped
reset
run '' --yes
check "nothing installed: exit 0" test "$rc" = 0
check "nothing installed: groups added" logged "usermod -aG libvirt tester"
check "nothing installed: no override" notlogged "flatpak override"
check "nothing installed: steps skipped" has "skipped (not installed)"

# 2. everything installed, --yes: defaults (steam devices and games path skipped)
reset
printf '%b\n' "$all_apps" >"$INSTALLED"
run '' --yes
check "yes: exit 0" test "$rc" = 0
check "yes: vscode" logged "--socket=wayland --filesystem=xdg-run/podman com.visualstudio.code"
check "yes: podman desktop" logged "--nofilesystem=/run/docker.sock io.podman_desktop.PodmanDesktop"
check "yes: chrome" logged "com.google.Chrome"
check "yes: gearlever" logged "--filesystem=~/Applications it.mijorus.gearlever"
check "yes: steam devices not applied" notlogged "--device=usb"
check "yes: games path skipped" has "skipped (needs a path)"
check "yes: undo printed" has "flatpak override --user --nosocket=wayland"

# 3. idempotent second run
: >"$LOG"
run '' --yes
check "second run: exit 0" test "$rc" = 0
check "second run: no override" notlogged "flatpak override --user --socket"
check "second run: no override (fs)" notlogged "flatpak override --user --nofilesystem"
check "second run: no usermod" notlogged "usermod"
check "second run: already done" has "already done"

# 4. --no changes nothing
reset
printf '%b\n' "$all_apps" >"$INSTALLED"
run '' --no
check "no: exit 0" test "$rc" = 0
check "no: nothing changed" notlogged "usermod"
check "no: no override" notlogged "flatpak override --user --socket"
check "no: plan printed" has "planned (would ask)"

# 5. a failing step does not stop the rest, exit status non-zero
reset
printf '%b\n' "$all_apps" >"$INSTALLED"
echo com.visualstudio.code >"$FAILAPP"
run '' --yes
check "failure: exit non-zero" test "$rc" != 0
check "failure: reported" has "FAILED"
check "failure: later step still ran" logged "it.mijorus.gearlever"

# 6. interactive: Enter takes defaults, steam devices yes, games path given
reset
printf '%b\n' "$all_apps" >"$INSTALLED"
run '\n'"$root"'/games\ny\n\n\n\n\n'
check "interactive: exit 0" test "$rc" = 0
check "interactive: steam devices yes" logged "--device=usb"
check "interactive: games path applied" logged "--filesystem=$root/games net.lutris.Lutris"
reset
printf '%b\n' "$all_apps" >"$INSTALLED"
run '\n\n\n\n\n\n\n'
check "interactive: steam devices default no" notlogged "--device=usb"

# 7. unknown flag is an error, unsafe games path refused
reset
run '' --bogus
check "unknown flag: error" test "$rc" = 2
reset
printf '%b\n' "$all_apps" >"$INSTALLED"
run '\n/\n\n\n\n\n\n\n'
check "games path: / refused" has "Refusing to expose"

echo "passed: $pass, failed: $failn"
[ "$failn" = 0 ]
