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
[ -n "${FAKE_SLOW:-}" ] && sleep 0.3   # keep writing after the TPM2 token line: a `| grep -q` would have closed the pipe by now
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

run enroll /dev/nvme1n1 --yes
check "enroll uses PCR 7+14 by default" logged "cryptenroll --tpm2-device=auto --tpm2-pcrs=7+14 --wipe-slot=tpm2 /dev/nvme1n1"
FAKE_TPM="/dev/nvme1n1" run enroll /dev/nvme1n1 --yes
check "re-enrolling is one call: enroll the new TPM2 key and wipe the old slot (the tool wipes only after the enrollment succeeded)" bash -c "[ \$(grep -c '^cryptenroll' '$LOG') = 1 ] && grep -q 'cryptenroll --tpm2-device=auto --tpm2-pcrs=7+14 --wipe-slot=tpm2 /dev/nvme1n1' '$LOG'"
FAKE_TPM="/dev/nvme1n1" FAKE_ENROLL_FAIL=1 run enroll /dev/nvme1n1 --yes
check "a failed re-enrollment never runs a separate wipe" bash -c "[ $rc = 1 ] && [ \$(grep -c '^cryptenroll' '$LOG') = 1 ] && ! grep -q 'cryptenroll --wipe-slot=tpm2 ' '$LOG'"

FAKE_TPM_ONLY="/dev/nvme1n1" run enroll /dev/nvme1n1 --yes
check "a volume whose only keyslot is the TPM2 one: REFUSED before anything runs, with the recovery-key command, exit 1" bash -c "[ $rc = 1 ] && grep -q 'REFUSED /dev/nvme1n1' '$root/out' && grep -q 'systemd-cryptenroll /dev/nvme1n1 --recovery-key --unlock-tpm2-device=auto' '$root/out' && ! grep -q '^cryptenroll' '$LOG'"
FAKE_TPM_ONLY="/dev/nvme1n1" run remove /dev/nvme1n1 --yes
check "remove is refused for such a volume too (it would leave it with no way to unlock)" bash -c "[ $rc = 1 ] && grep -q REFUSED '$root/out' && ! grep -q '^cryptenroll' '$LOG'"
FAKE_LUKS1="/dev/nvme1n1" run enroll /dev/nvme1n1 --yes
check "a header that is not LUKS2 cannot be checked: refused, says so" bash -c "[ $rc = 1 ] && grep -q 'could not confirm another unlock method' '$root/out' && ! grep -q '^cryptenroll' '$LOG'"
check "no run ever wipes every slot, a keyslot or a passphrase" bash -c "! grep -qE 'wipe-slot=(all|password|[0-9])|luksKillSlot|luksRemoveKey' '$LOG'"
FAKE_SLOW=1 FAKE_TPM="/dev/nvme0n1p3" run enroll --yes
check "a luksDump that keeps writing after the TPM2 token line (SIGPIPE under pipefail) still counts as enrolled" bash -c "[ $rc = 0 ] && grep -q 'wipe-slot=tpm2 /dev/nvme1n1' '$LOG' && ! grep -q '^cryptenroll.*nvme0n1p3' '$LOG'"

FAKE_TPM="/dev/nvme0n1p3 /dev/nvme1n1" run remove /dev/nvme1n1 --yes
check "remove deletes only the TPM2 key" bash -c "grep -q 'cryptenroll --wipe-slot=tpm2 /dev/nvme1n1' '$LOG' && ! grep -q 'tpm2-device' '$LOG'"
FAKE_ENROLL_FAIL=1 run enroll /dev/nvme1n1 --yes
check "a failed enrollment exits 1 and says the passphrase still works" bash -c "[ $rc = 1 ] && grep -q 'passphrase still works' '$root/out'"

echo
echo "$pass passed, $failn failed"
[ "$failn" = 0 ]
