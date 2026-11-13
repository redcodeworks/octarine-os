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

reset; run --help
check "--help explains persistence, the lax option and the opt-in" bash -c "[ $rc = 0 ] && grep -q 'survives image updates' '$root/out' && grep -q 'acpi_enforce_resources=lax' '$root/out' && grep -q -- '--no' '$root/out'"
run --bogus
check "an unknown argument is rejected (exit 1)" bash -c "[ $rc = 1 ]"

reset; run --no
check "--no changes and runs nothing (no sudo, no detect)" bash -c "[ $rc = 0 ] && [ ! -e '$target' ]" 
check "--no logs nothing" bash -c "[ ! -s '$LOG' ]"
check "--no prints the plan" has "Plan:"

reset; run
check "without a terminal and without --yes: left as it is, nothing run" bash -c "[ $rc = 0 ] && [ ! -s '$LOG' ] && [ ! -e '$target' ]"

reset; FAKE_DETECT=none run --yes
check "no chip detected: exit 0, clear message, nothing written" bash -c "[ $rc = 0 ] && [ ! -e '$target' ]"
check "no chip: the message says nothing needs a driver" has "No sensor chip needs a driver"
check "no chip: nothing is loaded" notlogged modprobe
reset; FAKE_DETECT=autoloaded run --yes
check "only autoloaded chips: exit 0 and nothing written" bash -c "[ $rc = 0 ] && [ ! -e '$target' ]"

reset; FAKE_DETECT=one run --yes
check "one module: file written with header and the module" bash -c "[ $rc = 0 ] && grep -q '^# Written by' '$target' && grep -qx nct6775 '$target' && [ \$(grep -vc '^#' '$target') = 1 ]"
check "detect runs once with --auto under sudo" bash -c "[ \$(grep -c 'sudo sensors-detect --auto' '$LOG') = 1 ]"
check "the module is loaded now" logged "modprobe nct6775"
check "fan and temperature lines are shown" bash -c "grep -q 'fan1' '$root/out' && grep -q 'SYSTIN' '$root/out' && ! grep -q intrusion '$root/out'"
check "the final message says to not re-run after an update" has "no need to re-run after an update"
check "the final message names acpi_enforce_resources=lax as not set" has "acpi_enforce_resources=lax"
check "the undo is printed" has "Undo: sudo rm $target"

FAKE_DETECT=one run --yes
check "second run with the same content: already done, no backup" bash -c "[ $rc = 0 ] && grep -q 'Already done' '$root/out' && ! ls '$root/mld' | grep -q bak"

reset; FAKE_DETECT=two run --yes
check "two modules: both on their own lines" bash -c "grep -qx nct6775 '$target' && grep -qx jc42 '$target'"
check "two modules: both loaded" bash -c "grep -q 'modprobe nct6775' '$LOG' && grep -q 'modprobe jc42' '$LOG'"

reset; FAKE_DETECT=bus run --yes
check "bus modules come first and an odd module name is ignored" bash -c "[ \$(grep -v '^#' '$target' | head -n1) = i2c-piix4 ] && ! grep -q 'bad' '$target' && grep -q 'odd module name' '$root/out'"

reset; echo "other" >"$target"; FAKE_DETECT=one run --no
check "--no with an existing different file: untouched" bash -c "[ \$(cat '$target') = other ]"
reset; echo "other" >"$target"; FAKE_DETECT=one run --yes
check "existing different file with --yes: diff shown, backup made, replaced" bash -c "grep -q '^-other' '$root/out' && ls '$root/mld' | grep -q 'octarine-sensors.conf.bak-' && grep -qx nct6775 '$target'"
reset; echo "other" >"$target"; FAKE_DETECT=one OCTARINE_MENU_FORCE_TTY=1 run --yes
check "the backup keeps the old content" bash -c "grep -qx other '$root'/mld/octarine-sensors.conf.bak-*"

reset; echo "nct6775" >"$legacy"; FAKE_DETECT=one run --yes
check "legacy nct6775.conf: mentioned and moved to a backup with --yes" bash -c "grep -q 'older hand-made' '$root/out' && [ ! -e '$legacy' ] && ls '$root/mld' | grep -q 'nct6775.conf.bak-'"
check "legacy: the generated file is still written" bash -c "grep -qx nct6775 '$target'"

reset; FAKE_SUDO_FAIL=1 FAKE_DETECT=one run --yes
check "a failing sudo: exit 1, exact command printed, nothing written, no retry" bash -c "[ $rc = 1 ] && grep -q 'sudo sensors-detect --auto' '$root/out' && [ ! -e '$target' ] && [ \$(grep -c 'sudo' '$LOG') = 1 ]"
reset; FAKE_DETECT=fail run --yes
check "a failing sensors-detect: exit 1 and nothing written" bash -c "[ $rc = 1 ] && [ ! -e '$target' ]"
reset; FAKE_MODPROBE_FAIL=1 FAKE_DETECT=one run --yes
check "a failing modprobe: file stays, exit 1, command printed" bash -c "[ $rc = 1 ] && [ -e '$target' ] && grep -q 'sudo modprobe nct6775' '$root/out'"

# a PATH without sensors-detect: only the tools the recipe needs are linked in
mkdir -p "$root/minbin"
for t in bash env just sed grep mktemp date cmp diff cat head tail rm cp mv tee ls; do ln -sf "$(command -v $t)" "$root/minbin/$t"; done
cp "$root/fakebin/sudo" "$root/minbin/sudo"
reset; : >"$LOG"; PATH="$root/minbin" just --justfile "$justfile" sensors-setup --yes >"$root/out" 2>&1 </dev/null; rc=$?
check "sensors-detect missing: exit 1 with a hint" bash -c "[ $rc = 1 ] && grep -q 'lm_sensors' '$root/out'"

echo
echo "passed: $pass, failed: $failn"
[ "$failn" = 0 ]
