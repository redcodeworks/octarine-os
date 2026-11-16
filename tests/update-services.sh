#!/usr/bin/env bash
# Tests for `ujust toggle-updates` and `ujust update` (system_files/usr/share/ublue-os/just/10-update.just), the shared
# source table (system_files/usr/share/octarine-os/lib/update-services.sh) and the distrobox timer units.
# Nothing real changes: systemctl, sudo, bootc, rpm-ostree, flatpak, distrobox and brew are fakes. The enabled units come
# from FAKE_ENABLED (space separated, "user:" prefix for user units). Needs: bash, just, jq. Run: tests/update-services.sh
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
justfile="$here/system_files/usr/share/ublue-os/just/10-update.just"
lib="$here/system_files/usr/share/octarine-os/lib/update-services.sh"
root=$(mktemp -d)
trap 'rm -rf -- "$root"' EXIT
pass=0
failn=0
rc=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { failn=$((failn + 1)); echo "FAIL $1"; sed 's/^/     /' "$root/out" 2>/dev/null; echo "     rc=$rc"; }
check() { local d=$1; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
has() { grep -qF -- "$1" "$root/out"; }
logged() { grep -qF -- "$1" "$root/log" 2>/dev/null; }
notlogged() { ! grep -qF -- "$1" "$root/log" 2>/dev/null; }
export LOG="$root/log"
mkdir -p "$root/fakebin" "$root/just"
# the image layout: our 10-update.just next to the base file that build.sh renames to 10-update-base.just (a stub here)
cp -- "$justfile" "$root/just/10-update.just"
# the own recipes live in octarine-os/just/update.just, which the wrapper imports first (absolute path rewritten to the temp tree)
mkdir -p "$root/own"; cp -- "$here/system_files/usr/share/octarine-os/just/update.just" "$root/own/"
sed -i "s|/usr/share/octarine-os/just|$root/own|" "$root/just/10-update.just"
cat >"$root/just/10-update-base.just" <<'EOF2'
alias upgrade := update
alias changelog := changelogs
alias auto-update := toggle-updates
update VERB_LEVEL="full":
    @echo BASE-UPDATE
toggle-updates ACTION="prompt":
    @echo BASE-TOGGLE
changelogs:
    @echo BASE-CHANGELOGS
EOF2
printf 'set allow-duplicate-recipes := true\nimport "%s/just/10-update.just"\n' "$root" >"$root/Justfile"

cat >"$root/fakebin/systemctl" <<'EOF2'
#!/bin/bash
scope=system
[ "$1" = --user ] && { scope=user; shift; }
verb=$1
shift
case "$verb" in
    is-enabled)
        u=$1
        key=$u; [ "$scope" = user ] && key="user:$u"
        case " ${FAKE_MISSING:-} " in *" $key "*) echo "Failed to get unit file state for $u: No such file or directory"; exit 1 ;; esac
        case " ${FAKE_ENABLED:-} " in *" $key "*) echo enabled; exit 0 ;; esac
        echo disabled; exit 1 ;;
    enable | disable)
        echo "systemctl[$scope] $verb $*" >>"$LOG" ;;
esac
EOF2
cat >"$root/fakebin/sudo" <<'EOF2'
#!/bin/bash
echo "sudo $*" >>"$LOG"
[ "${FAKE_SUDO_FAIL:-}" = 1 ] && exit 1
exec "$@"
EOF2
for c in bootc flatpak distrobox brew; do
    cat >"$root/fakebin/$c" <<EOF2
#!/bin/bash
echo "$c \$*" >>"\$LOG"
[ "\${FAKE_FAIL:-}" = "$c" ] && exit 1
exit 0
EOF2
done
cat >"$root/fakebin/rpm-ostree" <<'EOF2'
#!/bin/bash
case "$1" in
    status) echo "{\"deployments\":[{\"requested-packages\":${FAKE_LAYERED:-[]}}]}" ;;
    *) echo "rpm-ostree $*" >>"$LOG" ;;
esac
EOF2
chmod +x "$root/fakebin/"*

run() { # recipe, args...
    local recipe=$1
    shift
    : >"$LOG"
    PATH="$root/fakebin:$PATH" OCTARINE_UPDATE_LIB="$lib" just --justfile "$root/Justfile" "$recipe" "$@" >"$root/out" 2>&1 </dev/null
    rc=$?
}

all_on="rpm-ostreed-automatic.timer flatpak-system-update.timer user:flatpak-user-update.timer user:octarine-distrobox-upgrade.timer brew-update.timer brew-upgrade.timer"

FAKE_ENABLED="flatpak-system-update.timer" check "flatpak counts as on when only the system timer is on" bash -c "PATH='$root/fakebin:\$PATH' FAKE_ENABLED=flatpak-system-update.timer; export FAKE_ENABLED; source '$lib'; us_on flatpak && ! us_on image"
FAKE_ENABLED="rpm-ostreed-automatic.timer flatpak-system-update.timer user:flatpak-user-update.timer brew-update.timer" run toggle-updates status
FAKE_ENABLED="" run toggle-updates
FAKE_ENABLED="" run toggle-updates enable flatpak --yes
FAKE_ENABLED="" run toggle-updates enable distrobox --yes
FAKE_ENABLED="$all_on" run toggle-updates disable brew-upgrade brew-update --yes
FAKE_ENABLED="$all_on" run toggle-updates disable --yes
FAKE_ENABLED="$all_on" run toggle-updates enable --yes
FAKE_ENABLED="" run toggle-updates enable all --no
check "--no prints the plan only" bash -c "grep -q 'turn on   image' '$root/out' && ! grep -q systemctl '$LOG'"
FAKE_ENABLED="" run toggle-updates enable image
check "without --yes and no terminal the question is declined" bash -c "grep -q 'Left as it is' '$root/out' && ! grep -q systemctl '$LOG'"
FAKE_ENABLED="" FAKE_MISSING="user:octarine-distrobox-upgrade.timer" run toggle-updates enable all --yes
FAKE_ENABLED="" run toggle-updates bogus
FAKE_ENABLED="" run toggle-updates flatpak
FAKE_ENABLED="" run toggle-updates --help

# ---- update
FAKE_ENABLED="rpm-ostreed-automatic.timer flatpak-system-update.timer" run update
check "update runs only what is switched on: image" logged "sudo bootc upgrade"
check "update tells the user to reboot after staging an image" has "needs a reboot"
FAKE_ENABLED="" run update
FAKE_ENABLED="flatpak-system-update.timer" run update
FAKE_ENABLED="rpm-ostreed-automatic.timer" run update
FAKE_ENABLED="" run update image --no
FAKE_ENABLED="" run update --all
FAKE_ENABLED="$all_on" run update distrobox
FAKE_ENABLED="$all_on" run update --no
FAKE_ENABLED="rpm-ostreed-automatic.timer" FAKE_LAYERED='["htop"]' run update
FAKE_ENABLED="$all_on" FAKE_FAIL=flatpak run update
check "a failing source does not stop the others, and is reported (exit 1)" bash -c "[ $rc = 1 ] && grep -q 'Failed sources: flatpak' '$root/out' && grep -q 'brew upgrade' '$LOG'"
FAKE_ENABLED="$all_on" run update bogus
FAKE_ENABLED="flatpak-system-update.timer" run toggle-updates enable flatpak --yes
FAKE_ENABLED="flatpak-system-update.timer user:flatpak-user-update.timer" run toggle-updates enable flatpak --yes
FAKE_ENABLED="flatpak-system-update.timer" run toggle-updates disable flatpak --yes
# ---- a pending kernel-argument change would be replaced by the staged image: warn, ask (default no), --yes goes on, --no is the plan
mkdir -p "$root/kbin"
cat >"$root/kbin/rpm-ostree" <<'EOF2'
#!/bin/bash
case "$1" in
    kargs) echo "root=UUID=1 rw quiet ${FAKE_NEXT_EXTRA-}" ;;
    status) echo '{"deployments":[{"booted":false,"requested-packages":[]},{"booted":true}]}' ;;
esac
EOF2
chmod +x "$root/kbin/rpm-ostree"
echo "root=UUID=1 rw quiet" >"$root/cmdline"
krun() { # args...
    : >"$LOG"
    PATH="$root/kbin:$root/fakebin:$PATH" OCTARINE_UPDATE_LIB="$lib" OCTARINE_KARGS_LIB="$here/system_files/usr/share/octarine-os/lib/kargs.sh" OCTARINE_CMDLINE="$root/cmdline" \
        just --justfile "$root/Justfile" update "$@" >"$root/out" 2>&1 </dev/null
    rc=$?
}
FAKE_NEXT_EXTRA="amdgpu.ppfeaturemask=0xffffffff" FAKE_ENABLED="$all_on" krun
check "pending kernel argument, image source on, asked (default no): WARNING with the change, the image is NOT updated, the other sources still are, exit 0" bash -c "[ $rc = 0 ] && grep -q 'WARNING: a pending kernel-argument change would be lost by the image update' '$root/out' && grep -q '+amdgpu.ppfeaturemask=0xffffffff' '$root/out' && grep -q 'Image update skipped' '$root/out' && ! grep -q 'bootc upgrade' '$LOG' && grep -q 'flatpak update' '$LOG'"
FAKE_NEXT_EXTRA="amdgpu.ppfeaturemask=0xffffffff" FAKE_ENABLED="$all_on" krun --yes
check "pending kernel argument with --yes: the WARNING is printed and bootc upgrade runs" bash -c "[ $rc = 0 ] && grep -q 'WARNING' '$root/out' && grep -q -- '--yes: going on anyway' '$root/out' && grep -q 'bootc upgrade' '$LOG'"
FAKE_NEXT_EXTRA="amdgpu.ppfeaturemask=0xffffffff" FAKE_ENABLED="$all_on" krun --no
check "pending kernel argument with --no: the WARNING and the plan, nothing runs" bash -c "[ $rc = 0 ] && grep -q 'WARNING' '$root/out' && grep -q 'Would run: sudo bootc upgrade' '$root/out' && ! grep -q '^bootc' '$LOG'"
FAKE_NEXT_EXTRA="" FAKE_ENABLED="$all_on" krun
check "nothing pending: no warning, the image update runs without a question" bash -c "[ $rc = 0 ] && ! grep -q 'WARNING' '$root/out' && grep -q 'bootc upgrade' '$LOG'"
FAKE_NEXT_EXTRA="iommu=pt" FAKE_ENABLED="$all_on" krun flatpak
check "pending kernel argument but the image source is not part of the run: no warning" bash -c "[ $rc = 0 ] && ! grep -q 'WARNING' '$root/out'"
FAKE_NEXT_EXTRA="iommu=pt" FAKE_ENABLED="rpm-ostreed-automatic.timer" krun
check "pending kernel argument and image is the only source: skipped, exit 0, says reboot first" bash -c "[ $rc = 0 ] && grep -q 'Image update skipped' '$root/out' && ! grep -q 'bootc' '$LOG'"
u="$here/system_files/usr/lib/systemd/user"
PATH="$root/fakebin:$PATH" OCTARINE_UPDATE_LIB="$lib" FAKE_ENABLED="" just --justfile "$root/Justfile" update --no >"$root/out" 2>&1 </dev/null; rc=$?
PATH="$root/fakebin:$PATH" OCTARINE_UPDATE_LIB="$lib" FAKE_ENABLED="" just --justfile "$root/Justfile" upgrade --all --no >"$root/out" 2>&1 </dev/null; rc=$?
PATH="$root/fakebin:$PATH" OCTARINE_UPDATE_LIB="$lib" FAKE_ENABLED="" just --justfile "$root/Justfile" auto-update status >"$root/out" 2>&1 </dev/null; rc=$?
PATH="$root/fakebin:$PATH" just --justfile "$root/Justfile" changelogs >"$root/out" 2>&1 </dev/null; rc=$?
echo
echo "$pass passed, $failn failed"
[ "$failn" = 0 ]
