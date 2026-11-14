#!/usr/bin/env bash
# Tests system_files/usr/share/octarine-os/lib/kargs.sh (pending kernel-argument changes) with stub rpm-ostree and a fake /proc/cmdline. Needs: bash, jq, diff.
# The facts it encodes: `rpm-ostree kargs --append-if-missing=ARG` makes a PENDING deployment; a later image update (which stages from the BOOTED
# deployment) replaces it and drops ARG. Run: tests/kargs.sh
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
lib="$here/system_files/usr/share/octarine-os/lib/kargs.sh"
root=$(mktemp -d)
trap 'rm -rf -- "$root"' EXIT
pass=0; failn=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { failn=$((failn + 1)); echo "FAIL $1"; }
check() { local d=$1; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
mkdir -p "$root/bin"
for c in bash env cat grep sed tr sort diff jq; do p=$(command -v "$c") && ln -sf "$p" "$root/bin/$c"; done
cat >"$root/bin/rpm-ostree" <<'F'
#!/usr/bin/env bash
case "$1" in
    kargs) echo "${FAKE_NEXT-quiet}" ;;
    status) case "${FAKE_JSON:-pending}" in
        pending) echo '{"deployments":[{"booted":false},{"booted":true}]}' ;;
        booted) echo '{"deployments":[{"booted":true},{"booted":false}]}' ;;
        nofield) echo '{"deployments":[{"id":"x"}]}' ;;
        broken) echo 'not json' ;;
        esac ;;
esac
F
chmod +x "$root/bin/rpm-ostree"
echo "BOOT_IMAGE=(hd0,gpt2)/ostree/x/vmlinuz-1 root=UUID=1 rw quiet ostree=/ostree/boot.1/x/0 iommu=pt" >"$root/cmdline"
run() { PATH="$root/bin" OCTARINE_CMDLINE="$root/cmdline" bash -c ". '$lib'; $1" 2>&1; }
runrc() { PATH="$root/bin" OCTARINE_CMDLINE="$root/cmdline" bash -c ". '$lib'; $1" >"$root/out" 2>&1; rc=$?; }

FAKE_NEXT="root=UUID=1 rw quiet iommu=pt ostree=/ostree/boot.0/x/0 amdgpu.ppfeaturemask=0xfff7ffff" FAKE_JSON=pending runrc kargs_pending_change
check "pending deployment with an extra argument: the change is reported as +arg, ostree= and BOOT_IMAGE= are ignored" bash -c "[ $rc = 0 ] && [ \"\$(cat '$root/out')\" = '+amdgpu.ppfeaturemask=0xfff7ffff' ]"
FAKE_NEXT="root=UUID=1 rw quiet" FAKE_JSON=pending runrc kargs_pending_change
check "pending deployment that REMOVES an argument: reported as -arg" bash -c "[ $rc = 0 ] && grep -qx -- '-iommu=pt' '$root/out'"
FAKE_NEXT="root=UUID=1 rw quiet iommu=pt" FAKE_JSON=pending runrc kargs_pending_change
check "pending deployment (a staged image) with the same arguments: nothing to report (rc 1)" test "$rc" = 1
FAKE_NEXT="root=UUID=1 rw quiet iommu=pt amdgpu.ppfeaturemask=0x1" FAKE_JSON=booted runrc kargs_pending_change
check "the newest deployment is the booted one (nothing pending): rc 1 even if the lines differ (a hand edit in the GRUB menu is not a pending change)" test "$rc" = 1
FAKE_NEXT="root=UUID=1 rw quiet iommu=pt amdgpu.ppfeaturemask=0x1" FAKE_JSON=nofield runrc kargs_pending_change
check "the JSON has no booted field: the comparison alone decides (difference found)" bash -c "[ $rc = 0 ] && grep -qx -- '+amdgpu.ppfeaturemask=0x1' '$root/out'"
FAKE_NEXT="root=UUID=1 rw quiet iommu=pt amdgpu.ppfeaturemask=0x1" FAKE_JSON=broken runrc kargs_pending_change
check "the JSON is not readable: the comparison alone decides" test "$rc" = 0
FAKE_NEXT="" FAKE_JSON=pending runrc kargs_pending_change
check "rpm-ostree kargs prints nothing: no report, no crash" test "$rc" = 1
rm -f "$root/cmdline"; FAKE_NEXT="quiet" FAKE_JSON=pending runrc kargs_pending_change
check "no readable command line: no report" test "$rc" = 1
echo "root=UUID=1 rw quiet iommu=pt" >"$root/cmdline"

FAKE_NEXT="quiet iommu=pt amdgpu.ppfeaturemask=0xfff7ffff" runrc "kargs_pending_arg 'amdgpu.ppfeaturemask='"
check "kargs_pending_arg KEY=: in the next boot, not in the running ones: pending" test "$rc" = 0
FAKE_NEXT="quiet iommu=pt" runrc "kargs_pending_arg 'amdgpu.ppfeaturemask='"
check "kargs_pending_arg KEY=: in neither: not pending" test "$rc" = 1
echo "quiet amdgpu.ppfeaturemask=0x1" >"$root/cmdline"
FAKE_NEXT="quiet amdgpu.ppfeaturemask=0x1" runrc "kargs_pending_arg 'amdgpu.ppfeaturemask='"
check "kargs_pending_arg KEY=: already booted: not pending" test "$rc" = 1
echo "root=UUID=1 rw quiet" >"$root/cmdline"
FAKE_NEXT="quiet iommu=pt" runrc "kargs_pending_arg iommu=pt"
check "kargs_pending_arg WORD: pending when only the next boot has it" test "$rc" = 0
echo "quiet iommu=pt" >"$root/cmdline"
FAKE_NEXT="quiet iommu=pt" runrc "kargs_pending_arg iommu=pt"
check "kargs_pending_arg WORD: booted already: not pending" test "$rc" = 1

runrc "kargs_notice iommu=pt intel_iommu=on"
check "the notice says to reboot before the next image update, names the update paths, why, and the exact check on /proc/cmdline for each argument" bash -c "grep -q 'Reboot before the next image update (bootc upgrade, ujust update, switch-image, automatic update staging)' '$root/out' && grep -q 'replaces this pending change and drops the argument' '$root/out' && grep -qF 'grep -qw -- iommu=pt /proc/cmdline && grep -qw -- intel_iommu=on /proc/cmdline' '$root/out'"

# the confirmation helper
echo "root=UUID=1 rw quiet" >"$root/cmdline"
export FAKE_NEXT="root=UUID=1 rw quiet iommu=pt" FAKE_JSON=pending
runrc "kargs_confirm_update yes 'the image update'"
check "confirm yes: a WARNING with the change, goes on (rc 0), says --yes" bash -c "[ $rc = 0 ] && grep -q 'WARNING' '$root/out' && grep -q '+iommu=pt' '$root/out' && grep -q -- '--yes: going on anyway' '$root/out'"
runrc "kargs_confirm_update no 'the image update'"
check "confirm no (plan only): the WARNING, rc 0" bash -c "[ $rc = 0 ] && grep -q 'WARNING' '$root/out'"
runrc "kargs_confirm_update ask 'the image update'"
check "confirm ask without a menu: the WARNING and a refusal (default no, never silently on), rc 1" bash -c "[ $rc = 1 ] && grep -q 'WARNING' '$root/out'"
runrc "menu_confirm() { echo \"asked: \$1 default \$2\" >&2; return 0; }; kargs_confirm_update ask 'the image update'"
check "confirm ask, answered yes: asks with default n, rc 0" bash -c "[ $rc = 0 ] && grep -q 'default n' '$root/out'"
runrc "menu_confirm() { return 1; }; kargs_confirm_update ask 'the image update'"
check "confirm ask, answered no: rc 1" test "$rc" = 1
FAKE_NEXT="root=UUID=1 rw quiet" runrc "kargs_confirm_update ask 'the image update'"
check "nothing pending: no output at all, rc 0" bash -c "[ $rc = 0 ] && [ ! -s '$root/out' ]"
echo; echo "passed: $pass, failed: $failn"
[ "$failn" = 0 ]
