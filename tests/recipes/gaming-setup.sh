#!/usr/bin/env bash
# Thin test for `ujust gaming-setup` on the gx image (60-custom.just): with the steam RPM installed the Flatpak steps (steam, extensions, desktop) say so and
# do nothing, the other steps and a machine without the RPM behave as before. Nothing real changes: flatpak and rpm are fakes, HOME is a temp dir.
# Needs: bash, just. Run: tests/recipes/gaming-setup.sh
set -uo pipefail

here=$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)
justfile="$here/system_files/usr/share/ublue-os/just/60-custom.just"
root=$(mktemp -d)
trap 'rm -rf -- "$root"' EXIT
pass=0; failn=0; rc=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { failn=$((failn + 1)); echo "FAIL $1"; sed 's/^/     /' "$root/out" 2>/dev/null; echo "     rc=$rc"; }
check() { local d=$1; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }
has() { grep -qF -- "$1" "$root/out"; }
hasnt() { ! grep -qF -- "$1" "$root/out"; }
export LOG="$root/log" HOME="$root/home" OCTARINE_MENU_LIB="$here/system_files/usr/share/octarine-os/lib/menu.sh"
unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME GAMING_SETUP_NATIVE_STEAM
bin="$root/bin"; mkdir -p "$bin" "$HOME"
mk() { printf '#!/bin/bash\n%s\n' "$2" > "$bin/$1"; chmod +x "$bin/$1"; }
mk flatpak 'echo "flatpak $*" >>"$LOG"; case "$1" in info | list | remote-info) exit 1 ;; esac; exit 0'
mk rpm 'echo "rpm $*" >>"$LOG"; [ "${FAKE_STEAM_RPM:-}" = 1 ] && [ "$1 $2" = "-q steam" ]'
run() { : > "$LOG"; PATH="$bin:$PATH" just --justfile "$justfile" gaming-setup "$@" > "$root/out" 2>&1 < /dev/null; rc=$?; }

FAKE_STEAM_RPM=1 run steam extensions desktop --yes
check "steam RPM installed: the three Flatpak Steam steps run, exit 0" test "$rc" = 0
check "...each says Steam comes from the image and is recorded as skipped" test "$(grep -c 'skipped (Steam is installed from the image)' "$root/out")" = 3
check "...and nothing is installed or overridden with flatpak" bash -c "! grep -qE '^flatpak (install|override|remote-add)' '$LOG'"

FAKE_STEAM_RPM=1 run steam extensions desktop --no
check "steam RPM installed, plan only: steam is a skip, no install" bash -c "test $rc = 0 && ! grep -qE '^flatpak (install|override)' '$LOG'"

FAKE_STEAM_RPM=0 run steam --yes
check "no steam RPM: the Flatpak path is unchanged (it asks Flathub's verified list, installs nothing unverified)" bash -c "test $rc = 0" && hasnt "from the image" && has "Not installing com.valvesoftware.Steam"

FAKE_STEAM_RPM=1 run gamemode --no
check "other steps are unaffected by the RPM (gamemode is still planned)" bash -c "test $rc = 0" && has "gamemode" && hasnt "from the image"

GAMING_SETUP_NATIVE_STEAM=1 run steam --yes
check "GAMING_SETUP_NATIVE_STEAM=1 forces the native answer without rpm" bash -c "test $rc = 0" && has "skipped (Steam is installed from the image)"

echo; echo "passed: $pass, failed: $failn"
[ "$failn" = 0 ]
