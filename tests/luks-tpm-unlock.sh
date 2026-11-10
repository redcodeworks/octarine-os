#!/usr/bin/env bash
# Tests for `ujust luks-tpm-unlock` (60-custom.just), the aliases that keep the base image's two LUKS recipe names working
# (15-luks.just) and the recipes the image hides from `ujust --list` (30-distrobox.just, 50-akmods.just).
# Nothing real changes: sudo, lsblk, cryptsetup and systemd-cryptenroll are fakes; the LUKS state comes from FAKE_TPM
# (devices that already have a TPM2 key). Needs: bash, just. Run: tests/luks-tpm-unlock.sh
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
justdir="$here/system_files/usr/share/ublue-os/just"
justfile="$justdir/60-custom.just"
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
mkdir -p "$root/fakebin"

root_uuid=53df742f-65ee-4ba5-8adf-8d51565386bf
data_uuid=9be2eb1e-ec1e-4e97-933e-64f9341bf5f6
cat >"$root/fakebin/lsblk" <<EOF2
#!/bin/bash
[ "\${FAKE_NO_LUKS:-}" = 1 ] && exit 0
echo "/dev/nvme0n1p3 crypto_LUKS $root_uuid 1.8T"
echo "/dev/mapper/luks-$root_uuid btrfs 38ff5d6f-f9ce-4c65-ac54-9c451df9e944 1.8T"
echo "/dev/nvme1n1 crypto_LUKS $data_uuid 1.8T"
echo "/dev/nvme2n1 LVM2_member abcd 1T"
EOF2
cat >"$root/fakebin/sudo" <<'EOF2'
#!/bin/bash
echo "sudo $*" >>"$LOG"
[ "${FAKE_SUDO_FAIL:-}" = 1 ] && exit 1
[ "$1" = -v ] && exit 0
exec "$@"
EOF2
cat >"$root/fakebin/cryptsetup" <<'EOF2'
#!/bin/bash
# cryptsetup luksDump DEV
case " ${FAKE_TPM:-} " in
    *" $2 "*) printf 'Tokens:\n  0: systemd-tpm2\n' ;;
    *) printf 'Tokens:\n' ;;
esac
EOF2
cat >"$root/fakebin/systemd-cryptenroll" <<'EOF2'
#!/bin/bash
echo "cryptenroll $*" >>"$LOG"
[ "${FAKE_ENROLL_FAIL:-}" = 1 ] && [[ "$*" != *--wipe-slot* ]] && exit 1
exit 0
EOF2
chmod +x "$root/fakebin/"*
echo "BOOT_IMAGE=/boot rd.luks.uuid=luks-$root_uuid rhgb quiet" >"$root/cmdline"
echo "vendor_id : GenuineIntel" >"$root/cpu-intel"
echo "vendor_id : AuthenticAMD" >"$root/cpu-amd"

run() { # args...
    : >"$LOG"
    PATH="$root/fakebin:$PATH" OCTARINE_LUKS_CMDLINE="$root/cmdline" OCTARINE_LUKS_CPUINFO="${CPU:-$root/cpu-intel}" \
        just --justfile "$justfile" luks-tpm-unlock "$@" >"$root/out" 2>&1 </dev/null
    rc=$?
}

run --help
check "--help explains enroll, remove, PCRs and the PIN" bash -c "grep -q 'remove' '$root/out' && grep -q 'PCR 7+14' '$root/out' && grep -q -- '--pin' '$root/out'"
run
check "no action without a terminal: exit 2" bash -c "[ $rc = 2 ]"
run enroll
check "no devices named without a terminal: exit 2" bash -c "[ $rc = 2 ]"
check "it lists the LUKS devices, not the other block devices" bash -c "grep -q '/dev/nvme0n1p3' '$root/out' && grep -q '/dev/nvme1n1' '$root/out' && ! grep -q 'LVM2\\|nvme2n1' '$root/out'"
check "it marks the root device from the kernel command line" bash -c "grep '/dev/nvme0n1p3' '$root/out' | grep -q root && grep '/dev/nvme1n1' '$root/out' | grep -q data"
FAKE_TPM="/dev/nvme1n1" run enroll
check "it shows which devices already have a TPM2 key" bash -c "grep '/dev/nvme1n1' '$root/out' | grep -q 'enrolled' && grep '/dev/nvme0n1p3' '$root/out' | grep -q 'none'"
run bogus
check "a stray word is treated as a device and rejected (exit 2)" bash -c "[ $rc = 2 ]"
run enroll /dev/sdz --yes
check "an unknown device is rejected (exit 2)" bash -c "[ $rc = 2 ] && grep -q 'No LUKS device matches' '$root/out'"
check "an unknown device enrolls nothing" notlogged cryptenroll
run enroll --bogus
check "an unknown option is rejected (exit 2)" bash -c "[ $rc = 2 ]"
run enroll /dev/nvme1n1 --pcrs=9 --yes
check "an unsupported PCR set is rejected (exit 2)" bash -c "[ $rc = 2 ]"

run enroll /dev/nvme1n1 --yes
check "enroll uses PCR 7+14 by default" logged "cryptenroll --tpm2-device=auto --tpm2-pcrs=7+14 /dev/nvme1n1"
run enroll /dev/nvme1n1 --pcrs=7 --yes
check "--pcrs=7 binds to Secure Boot only" bash -c "grep -q 'pcrs=7 /dev/nvme1n1' '$LOG' && ! grep -q 'pcrs=7+14' '$LOG'"
check "the PCR 7 note does not mention MOK keys" hasnt "MOK"
run enroll /dev/nvme1n1 --yes
check "the default note mentions the MOK keys" has "MOK keys"
check "a first enrollment does not wipe anything" notlogged "wipe-slot"
check "enrolling the data volume gives no initramfs tip" hasnt "initramfs"
run enroll "$data_uuid" --pin --yes
check "a UUID selects the device; --pin passes through" logged "cryptenroll --tpm2-device=auto --tpm2-pcrs=7+14 --tpm2-with-pin=yes /dev/nvme1n1"
FAKE_TPM="/dev/nvme1n1" run enroll /dev/nvme1n1 --yes
check "re-enrolling wipes the old TPM2 key first" bash -c "grep -n 'cryptenroll' '$LOG' | head -2 | grep -q 'wipe-slot=tpm2 /dev/nvme1n1'"
check "re-enrolling then enrolls again" logged "cryptenroll --tpm2-device=auto --tpm2-pcrs=7+14 /dev/nvme1n1"
run enroll /dev/nvme0n1p3 /dev/nvme1n1 --yes
check "two devices are enrolled in one go" bash -c "grep -q 'pcrs=7+14 /dev/nvme0n1p3' '$LOG' && grep -q 'pcrs=7+14 /dev/nvme1n1' '$LOG'"
check "enrolling the root volume prints the initramfs tip and the reboot hint" bash -c "grep -q 'tpm2-tss' '$root/out' && grep -q 'Reboot' '$root/out'"
check "the passphrases are never touched" hasnt "luksKillSlot"

FAKE_TPM="/dev/nvme0n1p3 /dev/nvme1n1" run remove /dev/nvme1n1 --yes
check "remove deletes only the TPM2 key" bash -c "grep -q 'cryptenroll --wipe-slot=tpm2 /dev/nvme1n1' '$LOG' && ! grep -q 'tpm2-device' '$LOG'"
run --no remove /dev/nvme1n1
check "--no prints the plan and changes nothing" bash -c "grep -q 'remove' '$root/out' && ! grep -q cryptenroll '$LOG'"
run enroll /dev/nvme1n1
check "without --yes and no terminal the question is declined" bash -c "grep -q 'Left as it is' '$root/out' && ! grep -q cryptenroll '$LOG'"

CPU="$root/cpu-amd" run enroll /dev/nvme1n1 --yes
check "an AMD CPU gets the faulTPM warning" has "faulTPM"
CPU="$root/cpu-amd" run enroll /dev/nvme1n1
check "the AMD warning needs a yes (declined without a terminal)" bash -c "grep -q 'Left as it is' '$root/out' && ! grep -q cryptenroll '$LOG'"
CPU="$root/cpu-amd" run remove /dev/nvme1n1 --yes
check "removing needs no warning" hasnt "faulTPM"
run enroll /dev/nvme1n1 --yes
check "an Intel CPU gets no warning" hasnt "faulTPM"

FAKE_SUDO_FAIL=1 run enroll /dev/nvme1n1 --yes
check "without sudo it stops before reading anything (exit 1)" bash -c "[ $rc = 1 ] && ! grep -q cryptenroll '$LOG'"
FAKE_ENROLL_FAIL=1 run enroll /dev/nvme1n1 --yes
check "a failed enrollment exits 1 and says the passphrase still works" bash -c "[ $rc = 1 ] && grep -q 'passphrase still works' '$root/out'"
FAKE_NO_LUKS=1 run enroll
check "no LUKS devices: say so and exit 0" bash -c "[ $rc = 0 ] && grep -q 'No LUKS devices found' '$root/out'"

# ---- the base image's recipe names keep working through aliases
cat >"$root/Justfile" <<EOF2
set allow-duplicate-recipes := true
import "$justdir/15-luks.just"
import "$justfile"
EOF2
PATH="$root/fakebin:$PATH" just --justfile "$root/Justfile" setup-luks-tpm-unlock --help >"$root/out" 2>&1 </dev/null; rc=$?
check "setup-luks-tpm-unlock is an alias of luks-tpm-unlock" bash -c "[ $rc = 0 ] && grep -q 'TPM unlock\\|unlock LUKS' '$root/out'"
PATH="$root/fakebin:$PATH" just --justfile "$root/Justfile" remove-luks-tpm-unlock --help >"$root/out" 2>&1 </dev/null; rc=$?
check "remove-luks-tpm-unlock is an alias of luks-tpm-unlock" bash -c "[ $rc = 0 ] && grep -q 'remove' '$root/out'"

# ---- hidden recipes: private, so not listed, but still defined; the rest of the base file comes through
mkdir -p "$root/hide"
cp -- "$justdir/30-distrobox.just" "$justdir/50-akmods.just" "$root/hide/"
cat >"$root/hide/30-distrobox-base.just" <<'EOF2'
setup-distrobox-app CONTAINER="prompt":
    @echo BASE-APP
install-resolve ACTION="":
    @echo BASE-RESOLVE
distrobox-assemble:
    @echo BASE-ASSEMBLE
EOF2
printf 'set allow-duplicate-recipes := true\nimport "%s/hide/30-distrobox.just"\nimport "%s/hide/50-akmods.just"\n' "$root" "$root" >"$root/Hide"
just --justfile "$root/Hide" --list >"$root/out" 2>&1; rc=$?
check "setup-distrobox-app is not listed" hasnt "setup-distrobox-app"
check "configure-broadcom-wl is not listed" hasnt "configure-broadcom-wl"
check "install-resolve and distrobox-assemble stay listed (Resolve is wanted)" bash -c "grep -q install-resolve '$root/out' && grep -q distrobox-assemble '$root/out'"
just --justfile "$root/Hide" --show setup-distrobox-app >"$root/out" 2>&1; rc=$?
check "setup-distrobox-app is still defined, as the private override" bash -c "[ $rc = 0 ] && grep -q 'private' '$root/out' && ! grep -q BASE-APP '$root/out'"
just --justfile "$root/Hide" --show configure-broadcom-wl >"$root/out" 2>&1; rc=$?
check "configure-broadcom-wl is still defined" bash -c "[ $rc = 0 ] && grep -q 'private' '$root/out'"
just --justfile "$root/Hide" --show broadcom-wl >"$root/out" 2>&1; rc=$?
check "the broadcom-wl alias still resolves" bash -c "[ $rc = 0 ]"
check "the 50-akmods replacement has no other public recipe" bash -c "! grep -E '^[a-z][a-z0-9-]* .*:\$' '$justdir/50-akmods.just' | grep -qv '^configure-broadcom-wl'"

echo
echo "$pass passed, $failn failed"
[ "$failn" = 0 ]
