#!/usr/bin/env bash
# Tests for `ujust flatpak-preinstall` (system_files/usr/share/ublue-os/just/60-custom.just) with a fake flatpak.
# Needs: bash, just. Run: tests/flatpak-preinstall.sh
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
justfile="$here/../system_files/usr/share/ublue-os/just/60-custom.just"
root=$(mktemp -d)
trap 'rm -rf -- "$root"' EXIT
pass=0
failn=0
bin="$root/bin"
sysbin="$root/sysbin"
mkdir -p "$bin" "$sysbin" "$root/lists"
REAL_JUST=$(command -v just)
for c in bash sh env cat grep mktemp rm tee id mkdir; do
    p=$(command -v "$c") && ln -sf "$p" "$sysbin/$c"
done
printf '[Flatpak Preinstall org.example.One]\nBranch=stable\n\n[Flatpak Preinstall org.example.Two]\nBranch=stable\n' >"$root/lists/a.preinstall"
export LOG="$root/log" FLATPAK_PREINSTALL_DIR="$root/lists" FLATPAK_BIN="$bin/flatpak"
export DBUS_SESSION_BUS_ADDRESS=unix:path=/nonexistent REMOTES="$root/remotes" FP_STATUS=0 FP_OUT="Nothing to do."

cat >"$bin/flatpak" <<'F'
#!/usr/bin/env bash
echo "flatpak $*" >>"$LOG"
case "$1" in
    remotes) cat "$REMOTES" ;;
    preinstall) echo "$FP_OUT"; exit "$FP_STATUS" ;;
esac
F
cat >"$bin/getent" <<'F'
#!/usr/bin/env bash
[ -z "${NO_NET:-}" ]
F
chmod +x "$bin"/*

run() {
    PATH="$bin:$sysbin" "$REAL_JUST" --justfile "$justfile" --working-directory "$root" flatpak-preinstall "$@" >"$root/out" 2>&1
    rc=$?
}
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { failn=$((failn + 1)); echo "FAIL $1"; sed 's/^/     /' "$root/out"; }
check() { local d=$1; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
has() { grep -qF -- "$1" "$root/out"; }
logged() { grep -qF -- "$1" "$LOG"; }
reset() { : >"$LOG"; echo flathub >"$REMOTES"; unset NO_NET; export FP_STATUS=0 FP_OUT="Nothing to do."; export DBUS_SESSION_BUS_ADDRESS=unix:path=/nonexistent; }

reset
run --dry-run
check "dry run: exit 0" test "$rc" = 0
check "dry run: plan lists the refs" has "org.example.Two"
check "dry run: installs nothing" bash -c "! grep -q 'preinstall' '$LOG'"

reset
run
check "success: exit 0" test "$rc" = 0
check "success: preinstall ran" logged "flatpak preinstall -y"
check "success: reported" has "Done (exit status 0)"
check "success: idempotent output passes" has "Nothing to do."

reset
DBUS_SESSION_BUS_ADDRESS= run
check "no session bus: exit 1" test "$rc" = 1
check "no session bus: message" has "No desktop session bus"
check "no session bus: nothing run" bash -c "! grep -q 'preinstall -y' '$LOG'"

reset
: >"$REMOTES"
run
check "no flathub: exit 1" test "$rc" = 1
check "no flathub: says how to check" has "flatpak remotes"

reset
NO_NET=1 run
check "no network: exit 1" test "$rc" = 1
check "no network: message" has "No network"

reset
FP_STATUS=1 FP_OUT="error: Cannot autolaunch D-Bus without X11 \$DISPLAY" run
check "failure: exit status passed on" test "$rc" = 1
check "failure: status reported" has "Failed (exit status 1)"
check "failure: autolaunch explained" has "fedora' OCI remote"

reset
run --bogus
check "unknown option: exit 2" test "$rc" = 2

echo "passed: $pass, failed: $failn"
[ "$failn" = 0 ]
