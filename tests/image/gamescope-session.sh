#!/usr/bin/env bash
# Tests for the Steam Big Picture gamescope session of the gx layer: the REAL wrapper (variants/gx/system_files/usr/libexec/octarine-os/gamescope-session)
# runs against a fake `gamescope` that prints its argv, with environment.d fixtures: variables set -> flags present, unset -> omitted, later files
# override earlier ones (defaults, then system, then user), bad values are left out. Also checks the session file and the shipped defaults file.
# Run: tests/image/gamescope-session.sh. Needs: bash, python3.
set -uo pipefail
here=$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)
gx="$here/variants/gx/system_files"
wrapper="$gx/usr/libexec/octarine-os/gamescope-session"
root=$(mktemp -d); trap 'rm -rf -- "$root"' EXIT
pass=0; failn=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { failn=$((failn + 1)); echo "FAIL $1"; sed 's/^/     /' "$root/out" 2>/dev/null; }
bin="$root/bin"; mkdir -p "$bin" "$root/sys" "$root/user"
# fake gamescope: prints one line, the argv, and the value of PROTON_ENABLE_WAYLAND
cat >"$bin/gamescope" <<'F'
#!/usr/bin/env bash
echo "ARGV $*"
echo "PROTON_ENABLE_WAYLAND=${PROTON_ENABLE_WAYLAND-unset}"
F
chmod +x "$bin/gamescope"
printf '#!/bin/sh\nexit 0\n' >"$bin/logger"; chmod +x "$bin/logger"
# the scheduler side: a fake systemctl that logs and loads or unloads a fake scheduler (the ops file of a fake sched_ext sysfs), a registry with lavd and rusty, and
# a sysfs that does not exist for every run that is not about the scheduler (so no run here can touch the real systemctl)
cat >"$bin/systemctl" <<'F'
#!/usr/bin/env bash
echo "systemctl $*" >>"$SCXLOG"
case "$1" in
    is-enabled) echo disabled; exit 1 ;;
    start) mkdir -p "$OCTARINE_SCX_SYSFS/root"; n=${2#scx@}; echo "${n%.service}_1.1.4_x86_64" >"$OCTARINE_SCX_SYSFS/root/ops" ;;
    stop) rm -f "$OCTARINE_SCX_SYSFS/root/ops" ;;
esac
exit 0
F
chmod +x "$bin/systemctl"
mkdir -p "$root/registry"; : >"$root/registry/lavd.conf"; : >"$root/registry/rusty.conf"
export SCXLOG="$root/scxlog"
empty="$root/empty.conf"; : >"$empty"

# run_wrapper DEFAULTS_FILE: runs the wrapper with the fixture dirs; output in $root/out, the argv line in $argv
run_wrapper() {
    : >"$SCXLOG"
    env -i PATH="$bin:/usr/bin:/bin" HOME="$root/home" OCTARINE_GAMESCOPE_DEFAULTS="$1" OCTARINE_GAMESCOPE_SYSTEM_DIR="$root/sys" OCTARINE_GAMESCOPE_USER_DIR="$root/user" \
        OCTARINE_GAMESCOPE_LIBEXEC="$here/system_files/usr/libexec/octarine-os" OCTARINE_SCX_REGISTRY="$root/registry" OCTARINE_SCX_SYSFS="${SYSFS:-$root/nosys}" OCTARINE_SCX_RUN_DIR="$root/run" \
        OCTARINE_SCX_ACTIVE_WAIT=2 SCXLOG="$SCXLOG" "${@:2}" bash "$wrapper" >"$root/out" 2>&1 </dev/null
    wrc=$?
    argv=$(sed -n 's/^ARGV //p' "$root/out")
}
clean() { rm -f "$root"/sys/* "$root"/user/*; }
has() { [[ " $argv " == *" $1 "* ]]; }
check() { local d=$1; shift; if "$@"; then ok "$d"; else bad "$d (argv: ${argv:-none})"; fi; }

clean; run_wrapper "$empty"
check "nothing set: only the fixed flags (--backend drm, -e), no size, rate, output or upscaler baked in" test "$argv" = "--backend drm -e -- /usr/bin/steam -steamos3 -gamepadui"
check "PROTON_ENABLE_WAYLAND is 0 for the game" grep -qx 'PROTON_ENABLE_WAYLAND=0' "$root/out"

clean
cat >"$root/user/10-gamescope-session.conf" <<'F'
# comment
OUTPUT_CONNECTOR=DP-1
SCREEN_WIDTH=5120
SCREEN_HEIGHT=2160
REFRESH_RATE=120
INTERNAL_WIDTH=2560
INTERNAL_HEIGHT=1080
UPSCALER=nis
ADAPTIVE_SYNC=1
MOUSE_SENSITIVITY=2
CUSTOM_REFRESH_RATES=60,120
DRM_MODE=cvt
ORIENTATION=left
GAMESCOPE_EXTRA_ARGS="--mangoapp --fsr-sharpness 5"
F
run_wrapper "$empty"
for f in "--prefer-output DP-1" "-W 5120" "-H 2160" "-r 120" "-w 2560" "-h 1080" "-F nis" "--adaptive-sync" "--mouse-sensitivity 2" "--custom-refresh-rates 60,120" "--generate-drm-mode cvt" "--force-orientation left" "--mangoapp --fsr-sharpness 5"; do
    check "variable set -> flag present: $f" bash -c '[[ " $1 " == *" $2 "* ]]' _ "$argv" "$f"
done
check "extra args come before the Steam command" bash -c '[[ "$1" == *"--fsr-sharpness 5 -e -- /usr/bin/steam"* ]]' _ "$argv"

clean
printf 'SCREEN_WIDTH=1920\nREFRESH_RATE=60\nUPSCALER=fsr\nGAMESCOPE_SCHED_UNUSED=x\n' >"$root/def.conf"
printf 'SCREEN_WIDTH=2560\nREFRESH_RATE=75\n' >"$root/sys/20-b.conf"
printf 'SCREEN_WIDTH=3840\nexport UPSCALER="nis"\n' >"$root/sys/10-a.conf"
printf 'REFRESH_RATE=144\n' >"$root/user/10-gamescope-session.conf"
run_wrapper "$root/def.conf"
check "override order: defaults, then /etc/environment.d (sorted by name), then the user's file" bash -c '[[ " $1 " == *" -W 2560 "* && " $1 " == *" -r 144 "* && " $1 " == *" -F nis "* ]]' _ "$argv"
check "a name the wrapper does not know is ignored" bash -c '[[ "$1" != *UNUSED* ]]' _ "$argv"

clean; printf 'SCREEN_WIDTH=1920\n' >"$root/def.conf"; printf 'SCREEN_WIDTH=\n' >"$root/user/10-gamescope-session.conf"
run_wrapper "$root/def.conf"
check "an empty value in a later file unsets the setting: the flag is omitted" bash -c '[[ " $1 " != *" -W "* ]]' _ "$argv"

clean; printf 'SCREEN_WIDTH=7\n' >"$root/user/10-gamescope-session.conf"
run_wrapper "$empty" SCREEN_WIDTH=9999 REFRESH_RATE=240
check "the process environment is not read for these names" bash -c '[[ " $1 " == *" -W 7 "* && " $1 " != *" -r "* ]]' _ "$argv"

clean; printf 'SCREEN_WIDTH=wide\nREFRESH_RATE=120; touch %s/pwned\nMOUSE_SENSITIVITY=fast\nOUTPUT_CONNECTOR=DP 1\nADAPTIVE_SYNC=off\n' "$root" >"$root/user/10-gamescope-session.conf"
run_wrapper "$empty"
check "bad values are left out, files are parsed not sourced (nothing executed), ADAPTIVE_SYNC=off is off" bash -c '[[ "$1" == "--backend drm -e -- /usr/bin/steam -steamos3 -gamepadui" && ! -e "$2/pwned" ]]' _ "$argv" "$root"

clean; printf 'ENABLE_GAMESCOPE_HDR=1\nGAMESCOPE_HDR_NITS=600\n' >"$root/user/10-gamescope-session.conf"
run_wrapper "$empty"
check "HDR variables map to the HDR flags" bash -c '[[ " $1 " == *" --hdr-enabled --hdr-itm-enable "* && " $1 " == *" --hdr-itm-target-nits 600 "* ]]' _ "$argv"

# the session scheduler (GAMESCOPE_SESSION_SCHED): lavd while gamescope runs, restored when it ends
sysfs="$root/sysfs"; mkdir -p "$sysfs"
steps_of() { sed -n 's/^systemctl //p' "$SCXLOG" | tr '\n' '|'; }
clean; printf 'GAMESCOPE_SESSION_SCHED=lavd\n' >"$root/user/10-gamescope-session.conf"
SYSFS="$sysfs" run_wrapper "$empty"
check "lavd: started for the session, then stopped when gamescope ends (boot choice none: kernel default)" bash -c '[[ "$1" == *"start scx@lavd.service|"*"stop scx@lavd.service|" ]]' _ "$(steps_of)"
check "...the start comes before the stop and gamescope still got its flags" bash -c '[[ "$1" == "--backend drm -e -- /usr/bin/steam -steamos3 -gamepadui" ]]' _ "$argv"
check "...nothing is left loaded" test ! -e "$sysfs/root/ops"

clean; printf 'GAMESCOPE_SESSION_SCHED=skip\n' >"$root/user/10-gamescope-session.conf"
SYSFS="$sysfs" run_wrapper "$empty"
check "skip: systemctl is never called" test -z "$(steps_of)"
clean; printf 'GAMESCOPE_SESSION_SCHED=evil\n' >"$root/user/10-gamescope-session.conf"
SYSFS="$sysfs" run_wrapper "$empty"
check "an unregistered name is ignored (nothing started) and logged" bash -c '[[ -z "$1" ]]' _ "$(steps_of)" && grep -q "not a registered scheduler" "$root/out"
clean; printf 'GAMESCOPE_SESSION_SCHED=lavd\n' >"$root/user/10-gamescope-session.conf"
run_wrapper "$empty"
check "a kernel without sched_ext: no systemctl call, the session still starts" bash -c '[[ -z "$1" && -n "$2" ]]' _ "$(steps_of)" "$argv"
clean; printf 'GAMESCOPE_SESSION_SCHED=rusty\n' >"$root/user/10-gamescope-session.conf"
SYSFS="$sysfs" run_wrapper "$empty"
check "another registered scheduler can be chosen (rusty)" bash -c '[[ "$1" == *"start scx@rusty.service|"*"stop scx@rusty.service|" ]]' _ "$(steps_of)"

# gamescope that fails: its exit status is the session's, the scheduler is still restored
cat >"$root/failing" <<'F'
#!/usr/bin/env bash
echo "ARGV $*"; exit 7
F
mkdir -p "$root/bin2"; cp "$bin"/* "$root/bin2/"; cp "$root/failing" "$root/bin2/gamescope"; chmod +x "$root/bin2/gamescope"
clean; printf 'GAMESCOPE_SESSION_SCHED=lavd\n' >"$root/user/10-gamescope-session.conf"
bin_save=$bin; bin="$root/bin2"; SYSFS="$sysfs" run_wrapper "$empty"; bin=$bin_save
check "gamescope exiting 7: the wrapper exits 7 and the scheduler is stopped" bash -c '[[ "$1" == 7 && "$2" == *"stop scx@lavd.service|" ]]' _ "$wrc" "$(steps_of)"

# a signal to the wrapper ends gamescope and still restores the scheduler
cat >"$root/bin2/gamescope" <<'F'
#!/usr/bin/env bash
touch "$STARTED"; exec sleep 30
F
chmod +x "$root/bin2/gamescope"
clean; printf 'GAMESCOPE_SESSION_SCHED=lavd\n' >"$root/user/10-gamescope-session.conf"; : >"$SCXLOG"
rm -f "$root/started" "$root/run/switched"
env -i PATH="$root/bin2:/usr/bin:/bin" HOME="$root/home" OCTARINE_GAMESCOPE_DEFAULTS="$empty" OCTARINE_GAMESCOPE_SYSTEM_DIR="$root/sys" OCTARINE_GAMESCOPE_USER_DIR="$root/user" \
    OCTARINE_GAMESCOPE_LIBEXEC="$here/system_files/usr/libexec/octarine-os" OCTARINE_SCX_REGISTRY="$root/registry" OCTARINE_SCX_SYSFS="$sysfs" OCTARINE_SCX_RUN_DIR="$root/run" \
    OCTARINE_SCX_ACTIVE_WAIT=2 SCXLOG="$SCXLOG" STARTED="$root/started" timeout 20 bash "$wrapper" >"$root/out" 2>&1 </dev/null &
wp=$!
for _ in $(seq 100); do [[ -e "$root/started" && -e "$root/run/switched" ]] && break; sleep 0.1; done
pkill -TERM -P "$wp" -x bash 2>/dev/null; kill -TERM "$(pgrep -P "$wp" -x bash | head -1)" 2>/dev/null
wait "$wp" 2>/dev/null
check "SIGTERM to the wrapper: gamescope is ended, the scheduler is started and then stopped" bash -c '[[ "$1" == *"start scx@lavd.service|"*"stop scx@lavd.service|" ]]' _ "$(steps_of)"

# the shipped files
d="$gx/usr/share/octarine-os/gamescope-session.conf"
clean; run_wrapper "$d"
check "the shipped defaults file sets only the upscaler (fsr)" test "$argv" = "--backend drm -F fsr -e -- /usr/bin/steam -steamos3 -gamepadui"
check "the shipped defaults file documents every variable the wrapper knows" bash -c 'for k in $(sed -n "s/^known=\" \(.*\) \"\$/\1/p" "$1"); do grep -q "^# $k " "$2" || { echo "missing $k"; exit 1; }; done' _ "$wrapper" "$d"
check "the session file parses and Exec points at the wrapper under /usr/libexec" python3 -I - "$gx/usr/share/wayland-sessions/steam-gamescope.desktop" <<'PY'
import configparser, sys
c = configparser.RawConfigParser(strict=True, interpolation=None)
c.optionxform = str
c.read(sys.argv[1], encoding="utf-8")
e = c["Desktop Entry"]
assert e["Type"] == "Application" and e["Name"] == "Steam Big Picture (gamescope)" and e["DesktopNames"] == "gamescope"
assert e["Exec"] == "/usr/libexec/octarine-os/gamescope-session"
PY
check "the wrapper is executable" test -x "$wrapper"
echo; echo "$pass passed, $failn failed"; [ "$failn" = 0 ]
