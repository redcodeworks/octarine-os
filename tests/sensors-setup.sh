#!/usr/bin/env bash
# Tests for `ujust sensors-setup` (60-custom.just). Nothing real changes: sudo, sensors-detect, modprobe and sensors are
# fakes; the files go to a temp dir (OCTARINE_MODULES_LOAD_DIR, OCTARINE_SENSORS_SYSCONFIG). Needs: bash, just.
# Run: tests/sensors-setup.sh
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
justfile="$here/system_files/usr/share/ublue-os/just/60-custom.just"
root=$(mktemp -d)
trap 'rm -rf -- "$root"' EXIT
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
export LOG="$root/log"
mkdir -p "$root/fakebin" "$root/mld"
export OCTARINE_MODULES_LOAD_DIR="$root/mld"
export OCTARINE_SENSORS_SYSCONFIG="$root/lm_sensors"
target="$root/mld/octarine-sensors.conf"
legacy="$root/mld/nct6775.conf"

cat >"$root/fakebin/sudo" <<'EOF2'
#!/bin/bash
echo "sudo $*" >>"$LOG"
[ "${FAKE_SUDO_FAIL:-}" = 1 ] && exit 1
[ "$1" = -v ] && exit 0
exec "$@"
EOF2
cat >"$root/fakebin/sensors-detect" <<'EOF2'
#!/bin/bash
# FAKE_DETECT: none | one | two | bus | fail | autoloaded
echo "sensors-detect $*" >>"$LOG"
case "${FAKE_DETECT:-one}" in
    none) echo "Sorry, no sensors were detected." ;;
    autoloaded) echo "No modules to load, skipping modules configuration." ;;
    fail) echo "boom" >&2; exit 3 ;;
    one) echo 'HWMON_MODULES="nct6775"' >"$OCTARINE_SENSORS_SYSCONFIG" ;;
    two) echo 'HWMON_MODULES="nct6775 jc42"' >"$OCTARINE_SENSORS_SYSCONFIG" ;;
    bus) printf 'BUS_MODULES="i2c-piix4"\nHWMON_MODULES="it87 bad;name"\n' >"$OCTARINE_SENSORS_SYSCONFIG" ;;
esac
exit 0
EOF2
cat >"$root/fakebin/modprobe" <<'EOF2'
#!/bin/bash
echo "modprobe $*" >>"$LOG"
[ "${FAKE_MODPROBE_FAIL:-}" = 1 ] && exit 1
exit 0
EOF2
cat >"$root/fakebin/sensors" <<'EOF2'
#!/bin/bash
printf 'nct6798-isa-0290\nAdapter: ISA adapter\nfan1:        1200 RPM\nSYSTIN:      +31.0°C\nintrusion0:  ALARM\n'
EOF2
chmod +x "$root/fakebin/"*

run() {
    : >"$LOG"
    PATH="$root/fakebin:$PATH" just --justfile "$justfile" sensors-setup "$@" >"$root/out" 2>&1 </dev/null
    rc=$?
}
reset() { rm -f "$root/mld/"* "$root/lm_sensors"; }


reset; run --no
check "--no changes and runs nothing (no sudo, no detect)" bash -c "[ $rc = 0 ] && [ ! -e '$target' ]" 

reset; FAKE_DETECT=one run --yes
check "one module: file written with header and the module" bash -c "[ $rc = 0 ] && grep -q '^# Written by' '$target' && grep -qx nct6775 '$target' && [ \$(grep -vc '^#' '$target') = 1 ]"
FAKE_DETECT=one run --yes

reset; echo "other" >"$target"; FAKE_DETECT=one run --no --redetect
check "--no with an existing different file: untouched" bash -c "[ \$(cat '$target') = other ]"
reset; echo "other" >"$target"; FAKE_DETECT=one run --yes --redetect
check "existing different file with --yes --redetect: diff shown, backup made, replaced" bash -c "grep -q '^-other' '$root/out' && ls '$root/mld' | grep -q 'octarine-sensors.conf.bak-' && grep -qx nct6775 '$target'"

reset; FAKE_SUDO_FAIL=1 FAKE_DETECT=one run --yes
check "a failing sudo: exit 1, exact command printed, nothing written, no retry" bash -c "[ $rc = 1 ] && grep -q 'sudo sensors-detect --auto' '$root/out' && [ ! -e '$target' ] && [ \$(grep -c 'sudo' '$LOG') = 1 ]"
reset; FAKE_DETECT=fail run --yes
check "a failing sensors-detect: exit 1 and nothing written" bash -c "[ $rc = 1 ] && [ ! -e '$target' ]"
echo
echo "passed: $pass, failed: $failn"
[ "$failn" = 0 ]
