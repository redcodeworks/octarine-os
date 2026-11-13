#!/usr/bin/env bash
# Tests for the hardware-targeting fixes: proton.sh sets the AMD-only variable only with an AMD GPU, the mcelog and
# automatic-update drop-ins, the broadcom removal. Nothing real changes; sysfs is redirected with OCTARINE_SYSFS_DRM.
# Needs: bash. Run: tests/hardware-targeting.sh
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
check "proton.sh starts no subprocess (no command substitution, grep, awk or sed in code lines)" bash -c "! grep -v '^ *#' '$sf/etc/profile.d/proton.sh' | grep -qE '[$][(]|\`|grep|awk|sed'"
check "no fish equivalent of proton.sh exists to keep in step" bash -c "! grep -rqs 'PROTON_FSR4' '$sf/usr/share/fish'"

d="$sf/usr/lib/systemd/system"
check "mcelog: Intel-only drop-in (ExecCondition on GenuineIntel)" grep -qx 'ExecCondition=/usr/bin/grep -q -m1 GenuineIntel /proc/cpuinfo' "$d/mcelog.service.d/50-octarine-intel-only.conf"
check "mcelog: build.sh no longer masks it" bash -c "! grep -qE '^systemctl mask mcelog' '$here/build_files/build.sh'"
check "automatic updates: bounded retry drop-in" bash -c "grep -qx Restart=on-failure '$d/rpm-ostreed-automatic.service.d/50-octarine-retry.conf' && grep -qx RestartSec=60 '$d/rpm-ostreed-automatic.service.d/50-octarine-retry.conf' && grep -qx StartLimitBurst=5 '$d/rpm-ostreed-automatic.service.d/50-octarine-retry.conf'"
check "automatic updates: the base override.conf is not shadowed by a file of ours" test ! -e "$d/rpm-ostreed-automatic.service.d/override.conf"
check "automatic updates: the policy is not set by us (stays stage from the base)" bash -c "! grep -rqs AutomaticUpdatePolicy '$d/rpm-ostreed-automatic.service.d'"
check "smoke test (build.yml) asserts the drop-ins" bash -c "grep -q 'Restart=on-failure' '$here/.github/workflows/build.yml' && grep -q 'mcelog is not masked' '$here/.github/workflows/build.yml'"
check "50-akmods.just is comment-only" bash -c "! grep -qvE '^(#|\$)' '$sf/usr/share/ublue-os/just/50-akmods.just'"

echo
echo "passed: $pass, failed: $failn"
[ "$failn" = 0 ]
