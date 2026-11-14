#!/usr/bin/env bash
# Tests for `ujust luks-tpm-unlock` (60-custom.just) and the recipes the image hides from `ujust --list` (30-distrobox.just,
# 50-akmods.just). 15-luks.just is empty on purpose (the base's two LUKS recipes are gone).
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
: >"$root/tpmrm0"
export OCTARINE_TPM_DEVICE="$root/tpmrm0"

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
# cryptsetup luksDump DEV: a LUKS2 header. FAKE_TPM lists devices with a TPM2 token (keyslot 1); FAKE_TPM_ONLY lists devices whose ONLY keyslot is
# the TPM2 one (no passphrase, no recovery key); FAKE_LUKS1 lists devices with an old LUKS1 header
case " ${FAKE_LUKS1:-} " in *" $2 "*) printf 'LUKS header information for %s\nKey Slot 0: ENABLED\n' "$2"; exit 0 ;; esac
tpm=no; case " ${FAKE_TPM:-} ${FAKE_TPM_ONLY:-} " in *" $2 "*) tpm=yes ;; esac
only=no; case " ${FAKE_TPM_ONLY:-} " in *" $2 "*) only=yes ;; esac
echo "Keyslots:"
[ "$only" = yes ] || printf '  0: luks2\n\tKey:        512 bits\n'
[ "$tpm" = yes ] && printf '  1: luks2\n\tKey:        512 bits\n'
echo "Tokens:"
[ "$tpm" = yes ] && printf '  0: systemd-tpm2\n\ttpm2-pcrs:  7\n\tKeyslot:    1\n'
echo "Digests:"
printf '  0: pbkdf2\n\tKeyslot:    0\n'
EOF2
cat >"$root/fakebin/systemd-cryptenroll" <<'EOF2'
#!/bin/bash
echo "cryptenroll $*" >>"$LOG"
[ "${FAKE_ENROLL_FAIL:-}" = 1 ] && [[ "$*" == *--tpm2-device* ]] && exit 1
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

OCTARINE_TPM_DEVICE="$root/none" run enroll /dev/nvme1n1 --yes
check "no TPM device: clear message, exit 0, no sudo and no enrollment" bash -c "[ $rc = 0 ] && grep -q 'no TPM 2.0 device' '$root/out' && [ ! -s '$LOG' ]"
OCTARINE_TPM_DEVICE="$root/none" run
check "no TPM device with no arguments: the same message, exit 0" bash -c "[ $rc = 0 ] && grep -q 'no TPM 2.0 device' '$root/out'"
OCTARINE_TPM_DEVICE="$root/none" run --help
check "no TPM device: --help still works" bash -c "[ $rc = 0 ] && grep -q 'PCR 7+14' '$root/out'"
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
check "enroll uses PCR 7+14 by default" logged "cryptenroll --tpm2-device=auto --tpm2-pcrs=7+14 --wipe-slot=tpm2 /dev/nvme1n1"
run enroll /dev/nvme1n1 --pcrs=7 --yes
check "--pcrs=7 binds to Secure Boot only" bash -c "grep -q 'pcrs=7 --wipe-slot=tpm2 /dev/nvme1n1' '$LOG' && ! grep -q 'pcrs=7+14' '$LOG'"
check "the PCR 7 note does not mention MOK keys" hasnt "MOK"
run enroll /dev/nvme1n1 --yes
check "the default note mentions the MOK keys" has "MOK keys"
check "a first enrollment runs the same call (wipe-slot=tpm2 has nothing to wipe): the end state does not depend on a probe" logged "wipe-slot=tpm2"
check "...and never any other wipe" notlogged "wipe-slot=all"
check "enrolling the data volume gives no initramfs tip" hasnt "initramfs"
run enroll "$data_uuid" --pin --yes
check "a UUID selects the device; --pin passes through" logged "cryptenroll --tpm2-device=auto --tpm2-pcrs=7+14 --wipe-slot=tpm2 --tpm2-with-pin=yes /dev/nvme1n1"
FAKE_TPM="/dev/nvme1n1" run enroll /dev/nvme1n1 --yes
check "re-enrolling is one call: enroll the new TPM2 key and wipe the old slot (the tool wipes only after the enrollment succeeded)" bash -c "[ \$(grep -c '^cryptenroll' '$LOG') = 1 ] && grep -q 'cryptenroll --tpm2-device=auto --tpm2-pcrs=7+14 --wipe-slot=tpm2 /dev/nvme1n1' '$LOG'"
FAKE_TPM="/dev/nvme1n1" FAKE_ENROLL_FAIL=1 run enroll /dev/nvme1n1 --yes
check "a failed re-enrollment never runs a separate wipe" bash -c "[ $rc = 1 ] && [ \$(grep -c '^cryptenroll' '$LOG') = 1 ] && ! grep -q 'cryptenroll --wipe-slot=tpm2 ' '$LOG'"
run enroll /dev/nvme0n1p3 /dev/nvme1n1 --yes
check "two devices are enrolled in one go" bash -c "grep -q 'pcrs=7+14 --wipe-slot=tpm2 /dev/nvme0n1p3' '$LOG' && grep -q 'pcrs=7+14 --wipe-slot=tpm2 /dev/nvme1n1' '$LOG'"
check "enrolling the root volume prints the initramfs tip and the reboot hint" bash -c "grep -q 'tpm2-tss' '$root/out' && grep -q 'Reboot' '$root/out'"
check "the passphrases are never touched" hasnt "luksKillSlot"

# ---- the same end state on every run, and never a volume without another unlock method
FAKE_TPM_ONLY="/dev/nvme1n1" run enroll /dev/nvme1n1 --yes
check "a volume whose only keyslot is the TPM2 one: REFUSED before anything runs, with the recovery-key command, exit 1" bash -c "[ $rc = 1 ] && grep -q 'REFUSED /dev/nvme1n1' '$root/out' && grep -q 'systemd-cryptenroll /dev/nvme1n1 --recovery-key --unlock-tpm2-device=auto' '$root/out' && ! grep -q '^cryptenroll' '$LOG'"
FAKE_TPM_ONLY="/dev/nvme1n1" run remove /dev/nvme1n1 --yes
check "remove is refused for such a volume too (it would leave it with no way to unlock)" bash -c "[ $rc = 1 ] && grep -q REFUSED '$root/out' && ! grep -q '^cryptenroll' '$LOG'"
FAKE_TPM_ONLY="/dev/nvme1n1" run enroll /dev/nvme0n1p3 /dev/nvme1n1 --yes
check "one refused volume does not stop the others (exit 1, the other is enrolled)" bash -c "[ $rc = 1 ] && grep -q 'wipe-slot=tpm2 /dev/nvme0n1p3' '$LOG' && ! grep -q '^cryptenroll.*nvme1n1' '$LOG'"
FAKE_LUKS1="/dev/nvme1n1" run enroll /dev/nvme1n1 --yes
check "a header that is not LUKS2 cannot be checked: refused, says so" bash -c "[ $rc = 1 ] && grep -q 'could not confirm another unlock method' '$root/out' && ! grep -q '^cryptenroll' '$LOG'"
check "no run ever wipes every slot, a keyslot or a passphrase" bash -c "! grep -qE 'wipe-slot=(all|password|[0-9])|luksKillSlot|luksRemoveKey' '$LOG'"
FAKE_TPM="/dev/nvme0n1p3 /dev/nvme1n1" run enroll --yes
check "--yes without devices: only volumes without a TPM2 key are touched (here none: nothing runs, exit 0)" bash -c "[ $rc = 0 ] && ! grep -q '^cryptenroll' '$LOG' && grep -q 'Nothing selected' '$root/out'"
FAKE_TPM="/dev/nvme0n1p3" run enroll --yes
check "--yes without devices: the volume without a TPM2 key is enrolled, the enrolled one is left alone" bash -c "[ $rc = 0 ] && grep -q 'wipe-slot=tpm2 /dev/nvme1n1' '$LOG' && ! grep -q '^cryptenroll.*nvme0n1p3' '$LOG'"
FAKE_TPM="/dev/nvme0n1p3 /dev/nvme1n1" run enroll --force --yes
check "--force re-enrolls every volume, including the ones that already have a key (one call each, wipe-slot=tpm2)" bash -c "[ $rc = 0 ] && [ \$(grep -c '^cryptenroll' '$LOG') = 2 ] && grep -q 'wipe-slot=tpm2 /dev/nvme0n1p3' '$LOG' && grep -q 'wipe-slot=tpm2 /dev/nvme1n1' '$LOG'"
FAKE_TPM="/dev/nvme1n1" run enroll /dev/nvme1n1 --yes
check "naming an enrolled volume re-enrolls it (the explicit request wins over the probe)" bash -c "[ $rc = 0 ] && grep -q 'wipe-slot=tpm2 /dev/nvme1n1' '$LOG'"
FAKE_TPM="/dev/nvme1n1" run --help
check "--help states the rule: always the same call, probe only sets the default, refusal without another unlock method, no wipe of other slots" bash -c "grep -q 'ALWAYS runs one systemd-cryptenroll call' '$root/out' && grep -q 'REFUSES' '$root/out' && grep -q -- '--force' '$root/out' && grep -q 'no --wipe-slot=all' '$root/out'"

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

# ---- the base image's two LUKS recipe names are gone (15-luks.just is empty); the assembled check is tests/just-recipes.sh
check "15-luks.just defines no alias or recipe" bash -c "! grep -qE '^(alias |[a-z@\\[])' '$justdir/15-luks.just'"

# ---- Esc leaves everything as it is: exit 0 and no cryptenroll. A fake ugum/gum that returns nothing is Esc; a terminal is faked.
cat >"$root/fakebin/ugum" <<'EOF2'
#!/bin/bash
exit 130
EOF2
cat >"$root/fakebin/gum" <<'EOF2'
#!/bin/bash
exit 130
EOF2
chmod +x "$root/fakebin/ugum" "$root/fakebin/gum"
escrun() {
    : >"$LOG"
    PATH="$root/fakebin:$PATH" OCTARINE_MENU_FORCE_TTY=1 OCTARINE_MENU_LIB="$here/system_files/usr/share/octarine-os/lib/menu.sh" OCTARINE_LUKS_CMDLINE="$root/cmdline" OCTARINE_LUKS_CPUINFO="$root/cpu-intel" \
        just --justfile "$justfile" luks-tpm-unlock "$@" >"$root/out" 2>&1 </dev/null
    rc=$?
}
escrun
check "Esc at the action menu exits 0 and changes nothing" bash -c "[ $rc = 0 ] && grep -q 'nothing changed' '$root/out' && ! grep -q cryptenroll '$LOG'"
escrun enroll
check "Esc (nothing ticked) at the device checklist exits 0 and changes nothing" bash -c "[ $rc = 0 ] && grep -q 'Nothing selected' '$root/out' && ! grep -q cryptenroll '$LOG'"
escrun remove
check "Esc at the remove checklist exits 0 and changes nothing" bash -c "[ $rc = 0 ] && ! grep -q cryptenroll '$LOG'"

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
check "broadcom-wl is not listed" hasnt "broadcom-wl"
check "install-resolve and distrobox-assemble stay listed (Resolve is wanted)" bash -c "grep -q install-resolve '$root/out' && grep -q distrobox-assemble '$root/out'"
just --justfile "$root/Hide" --show setup-distrobox-app >"$root/out" 2>&1; rc=$?
check "setup-distrobox-app is still defined, as the private override" bash -c "[ $rc = 0 ] && grep -q 'private' '$root/out' && ! grep -q BASE-APP '$root/out'"
just --justfile "$root/Hide" --show configure-broadcom-wl >"$root/out" 2>&1; rc=$?
check "configure-broadcom-wl is gone (the file is comment-only)" bash -c "[ $rc != 0 ]"
just --justfile "$root/Hide" --show broadcom-wl >"$root/out" 2>&1; rc=$?
check "the broadcom-wl alias is gone" bash -c "[ $rc != 0 ]"
check "the 50-akmods replacement defines nothing (comments only)" bash -c "! grep -qvE '^(#|\$)' '$justdir/50-akmods.just'"

echo
echo "$pass passed, $failn failed"
[ "$failn" = 0 ]
