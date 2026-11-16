#!/usr/bin/env bash
# Behavior of the hardware-targeting fix: proton.sh sets the AMD-only variable only with an AMD GPU (sysfs is redirected with OCTARINE_SYSFS_DRM).
# Drop-in and build.sh text is not asserted. Needs: bash. Run: tests/hardware-targeting.sh
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
sf="$here/system_files"
root=$(mktemp -d)
trap 'rm -rf -- "$root"' EXIT
pass=0
failn=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { failn=$((failn + 1)); echo "FAIL $1"; }
check() { local d=$1; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }

card() { mkdir -p "$root/$1/$2/device"; echo "$3" >"$root/$1/$2/device/vendor"; }
card amd card0 0x1002
card nv card0 0x10de
card both card0 0x8086
card both card1 0x1002
card intel card0 0x8086
mkdir -p "$root/none"
fsr() { env -u PROTON_FSR4_UPGRADE -u PROTON_ENABLE_WAYLAND OCTARINE_SYSFS_DRM="$root/$1" bash -c ". '$sf/etc/profile.d/proton.sh'; echo \"fsr=\${PROTON_FSR4_UPGRADE:-unset} wl=\${PROTON_ENABLE_WAYLAND:-unset} leak=\${_octarine_vendor:-}\${_octarine_id:-}\""; }
check "AMD GPU: FSR4 upgrade is set" bash -c "[ \"\$($(declare -f fsr); root='$root' sf='$sf'; fsr amd)\" = 'fsr=1 wl=1 leak=' ]"
check "Intel iGPU plus AMD dGPU (card1): FSR4 upgrade is set" bash -c "$(declare -f fsr); root='$root' sf='$sf'; fsr both | grep -q 'fsr=1'"
check "NVIDIA GPU: FSR4 upgrade stays unset, Wayland stays on" bash -c "$(declare -f fsr); root='$root' sf='$sf'; [ \"\$(fsr nv)\" = 'fsr=unset wl=1 leak=' ]"
check "Intel only: FSR4 upgrade unset" bash -c "$(declare -f fsr); root='$root' sf='$sf'; fsr intel | grep -q 'fsr=unset'"
check "no GPU nodes at all: no error, FSR4 unset" bash -c "$(declare -f fsr); root='$root' sf='$sf'; [ \"\$(fsr none 2>&1)\" = 'fsr=unset wl=1 leak=' ]"

d="$sf/usr/lib/systemd/system"

echo
echo "passed: $pass, failed: $failn"
[ "$failn" = 0 ]
