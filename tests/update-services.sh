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

# ---- the source table
check "the library has the five sources in run order" bash -c "source '$lib'; [ \"\${US_IDS[*]}\" = 'image flatpak distrobox brew-update brew-upgrade' ]"
FAKE_ENABLED="flatpak-system-update.timer" check "flatpak counts as on when only the system timer is on" bash -c "PATH='$root/fakebin:\$PATH' FAKE_ENABLED=flatpak-system-update.timer; export FAKE_ENABLED; source '$lib'; us_on flatpak && ! us_on image"
check "a missing timer makes a source unavailable" bash -c "PATH='$root/fakebin:\$PATH' FAKE_MISSING=user:octarine-distrobox-upgrade.timer; export FAKE_MISSING; source '$lib'; [ \"\$(us_state distrobox)\" = unavailable ]"

# ---- toggle-updates
FAKE_ENABLED="rpm-ostreed-automatic.timer flatpak-system-update.timer user:flatpak-user-update.timer brew-update.timer" run toggle-updates status
check "status lists every source with its state" bash -c "[ $rc = 0 ] && grep -qE '^image +enabled' '$root/out' && grep -qE '^distrobox +disabled' '$root/out' && grep -qE '^brew-upgrade +disabled' '$root/out'"
FAKE_ENABLED="" run toggle-updates
check "without a terminal it shows the status and a hint" bash -c "[ $rc = 0 ] && grep -q 'checklist' '$root/out'"
check "that changes nothing" notlogged systemctl
FAKE_ENABLED="" run toggle-updates enable flatpak --yes
check "enable flatpak turns on the system timer with sudo" logged "sudo systemctl enable --now flatpak-system-update.timer"
check "enable flatpak turns on the user timer without sudo" logged "systemctl[user] enable --now flatpak-user-update.timer"
FAKE_ENABLED="" run toggle-updates enable distrobox --yes
check "distrobox is a user timer: no sudo" bash -c "grep -q 'systemctl\\[user\\] enable --now octarine-distrobox-upgrade.timer' '$LOG' && ! grep -q '^sudo' '$LOG'"
FAKE_ENABLED="$all_on" run toggle-updates disable brew-upgrade brew-update --yes
check "disable several sources in one sudo call" logged "sudo systemctl disable --now brew-update.timer brew-upgrade.timer"
FAKE_ENABLED="$all_on" run toggle-updates disable --yes
check "disable with no source turns everything off" bash -c "grep -q 'disable --now rpm-ostreed-automatic.timer' '$LOG' && grep -q 'systemctl\\[user\\] disable --now' '$LOG'"
FAKE_ENABLED="$all_on" run toggle-updates enable --yes
check "enable when all is on changes nothing" bash -c "grep -q 'Nothing to change' '$root/out'"
check "nothing is run when nothing changes" notlogged systemctl
FAKE_ENABLED="" run toggle-updates enable all --no
check "--no prints the plan only" bash -c "grep -q 'turn on   image' '$root/out' && ! grep -q systemctl '$LOG'"
FAKE_ENABLED="" run toggle-updates enable image
check "without --yes and no terminal the question is declined" bash -c "grep -q 'Left as it is' '$root/out' && ! grep -q systemctl '$LOG'"
FAKE_ENABLED="" FAKE_MISSING="user:octarine-distrobox-upgrade.timer" run toggle-updates enable all --yes
check "an unavailable source is skipped" bash -c "! grep -q octarine-distrobox '$LOG' && grep -q 'enable --now rpm-ostreed-automatic.timer' '$LOG'"
FAKE_ENABLED="" run toggle-updates bogus
check "an unknown source is rejected (exit 2)" bash -c "[ $rc = 2 ]"
FAKE_ENABLED="" run toggle-updates flatpak
check "sources without an action are rejected (exit 2)" bash -c "[ $rc = 2 ]"
FAKE_ENABLED="" run toggle-updates --help
check "--help names the sources" bash -c "grep -q 'brew-upgrade' '$root/out' && grep -q 'ujust update' '$root/out'"

# ---- update
FAKE_ENABLED="rpm-ostreed-automatic.timer flatpak-system-update.timer" run update
check "update runs only what is switched on: image" logged "sudo bootc upgrade"
check "update runs only what is switched on: flatpak" logged "flatpak update -y --noninteractive"
check "update skips distrobox when it is off" notlogged "distrobox upgrade"
check "update skips brew when it is off" notlogged "brew "
check "update tells the user to reboot after staging an image" has "needs a reboot"
FAKE_ENABLED="" run update
check "with nothing switched on it says so and runs nothing" bash -c "[ $rc = 0 ] && grep -q 'No update source is switched on' '$root/out' && [ ! -s '$LOG' ]"
check "with image updates off it prints one clear line about it" bash -c "[ \$(grep -c 'Image updates are switched off' '$root/out') = 1 ]"
FAKE_ENABLED="flatpak-system-update.timer" run update
check "image off while other sources run: the same single line, flatpak still runs" bash -c "[ \$(grep -c 'Image updates are switched off' '$root/out') = 1 ] && grep -q 'flatpak update' '$LOG'"
FAKE_ENABLED="rpm-ostreed-automatic.timer" run update
check "image on: no such line" bash -c "! grep -q 'Image updates are switched off' '$root/out'"
FAKE_ENABLED="" run update image --no
check "naming image while it is off: no such line" bash -c "! grep -q 'Image updates are switched off' '$root/out'"
FAKE_ENABLED="" run update --all
check "--all runs every source" bash -c "grep -q 'bootc upgrade' '$LOG' && grep -q 'flatpak update' '$LOG' && grep -q 'distrobox upgrade --all' '$LOG' && grep -q 'brew update' '$LOG' && grep -q 'brew upgrade' '$LOG'"
FAKE_ENABLED="$all_on" run update distrobox
check "naming a source runs just that one" bash -c "grep -q 'distrobox upgrade --all' '$LOG' && ! grep -q 'bootc' '$LOG' && ! grep -q flatpak '$LOG'"
FAKE_ENABLED="$all_on" run update --no
check "--no prints the plan and runs nothing" bash -c "grep -q 'Would run: sudo bootc upgrade' '$root/out' && [ ! -s '$LOG' ]"
FAKE_ENABLED="rpm-ostreed-automatic.timer" FAKE_LAYERED='["htop"]' run update
check "with layered packages the image step is rpm-ostree upgrade" logged "sudo rpm-ostree upgrade"
check "with layered packages bootc upgrade is not used" notlogged "bootc upgrade"
FAKE_ENABLED="$all_on" FAKE_FAIL=flatpak run update
check "a failing source does not stop the others, and is reported (exit 1)" bash -c "[ $rc = 1 ] && grep -q 'Failed sources: flatpak' '$root/out' && grep -q 'brew upgrade' '$LOG'"
FAKE_ENABLED="$all_on" run update bogus
check "an unknown source is rejected (exit 2)" bash -c "[ $rc = 2 ]"

# ---- a half-enabled source (flatpak: the system timer on, the user timer off) is completed by enable, not skipped
FAKE_ENABLED="flatpak-system-update.timer" run toggle-updates enable flatpak --yes
check "enable on a half-enabled flatpak: planned as completing it, BOTH timers get the enable (the user one is the missing one)" bash -c "[ $rc = 0 ] && grep -q 'completes it' '$root/out' && grep -q 'systemctl\[user\] enable --now user:flatpak-user-update.timer\|systemctl\[user\] enable --now flatpak-user-update.timer' '$LOG' && grep -q 'systemctl\[system\] enable --now flatpak-system-update.timer' '$LOG'"
FAKE_ENABLED="flatpak-system-update.timer user:flatpak-user-update.timer" run toggle-updates enable flatpak --yes
check "enable on a fully enabled flatpak: nothing to change, no systemctl call" bash -c "[ $rc = 0 ] && grep -q 'Nothing to change' '$root/out' && ! grep -q 'systemctl\[' '$LOG'"
FAKE_ENABLED="flatpak-system-update.timer" run toggle-updates disable flatpak --yes
check "disable on a half-enabled flatpak turns the whole source off" bash -c "[ $rc = 0 ] && grep -q 'turn off  flatpak' '$root/out' && grep -q 'disable --now flatpak-system-update.timer' '$LOG'"
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

# ---- the units and the overrides of the base recipes
u="$here/system_files/usr/lib/systemd/user"
check "the distrobox service runs distrobox upgrade --all" grep -qx 'ExecStart=/usr/bin/distrobox upgrade --all' "$u/octarine-distrobox-upgrade.service"
check "the distrobox timer is installable and persistent" bash -c "grep -q '^WantedBy=timers.target' '$u/octarine-distrobox-upgrade.timer' && grep -q '^Persistent=true' '$u/octarine-distrobox-upgrade.timer'"
PATH="$root/fakebin:$PATH" OCTARINE_UPDATE_LIB="$lib" FAKE_ENABLED="" just --justfile "$root/Justfile" update --no >"$root/out" 2>&1 </dev/null; rc=$?
check "our update beats the imported base recipe" bash -c "! grep -q BASE-UPDATE '$root/out' && grep -q 'No update source' '$root/out'"
PATH="$root/fakebin:$PATH" OCTARINE_UPDATE_LIB="$lib" FAKE_ENABLED="" just --justfile "$root/Justfile" upgrade --all --no >"$root/out" 2>&1 </dev/null; rc=$?
check "the base alias upgrade runs our update" bash -c "! grep -q BASE-UPDATE '$root/out' && grep -q 'Would run' '$root/out'"
PATH="$root/fakebin:$PATH" OCTARINE_UPDATE_LIB="$lib" FAKE_ENABLED="" just --justfile "$root/Justfile" auto-update status >"$root/out" 2>&1 </dev/null; rc=$?
check "the base alias auto-update runs our toggle-updates" bash -c "! grep -q BASE-TOGGLE '$root/out' && grep -q '^image' '$root/out'"
PATH="$root/fakebin:$PATH" just --justfile "$root/Justfile" changelogs >"$root/out" 2>&1 </dev/null; rc=$?
check "the base's other recipes (changelogs) still come through" has BASE-CHANGELOGS
check "build.sh keeps the base file as 10-update-base.just" grep -q '10-update 30-distrobox' "$here/build_files/build.sh"

echo
echo "$pass passed, $failn failed"
[ "$failn" = 0 ]
