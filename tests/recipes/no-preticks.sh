#!/usr/bin/env bash
# Thin test: no interactive checklist starts with a row ticked (Kevin, 2026-11-17). One assertion per recipe family, with a fake gum that
# logs its arguments and returns nothing: the real recipe must call `gum choose` without --selected. Needs: bash, just.
# Run: tests/recipes/no-preticks.sh
set -uo pipefail

here=$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)
just_dir="$here/system_files/usr/share/ublue-os/just"
menu="$here/system_files/usr/share/octarine-os/lib/menu.sh"
root=$(mktemp -d)
trap 'rm -rf -- "$root"' EXIT
pass=0
failn=0
ok() {
	pass=$((pass + 1))
	echo "ok   $1"
}
bad() {
	failn=$((failn + 1))
	echo "FAIL $1"
}
bin="$root/bin"
mkdir -p "$bin" "$root/home"
export HOME="$root/home" LOG="$root/log" OCTARINE_MENU_LIB="$menu" OCTARINE_MENU_FORCE_TTY=1
unset XDG_CONFIG_HOME
printf '#!/bin/bash\necho "gum $*" >>"$LOG"; exit 0\n' >"$bin/gum"
chmod +x "$bin/gum"

# recipe_ticks NAME FILE RECIPE [ARG...]: the recipe opens a gum checklist and nothing is pre-ticked
recipe_ticks() {
	local d=$1 file=$2
	shift 2
	: >"$LOG"
	PATH="$bin:$PATH" timeout 60 just --justfile "$file" "$@" >"$root/out" 2>&1 </dev/null
	if grep -q 'gum choose' "$LOG" && ! grep -q -- '--selected ' "$LOG"; then ok "$d: checklist opens with nothing ticked"; else
		bad "$d"
		sed 's/^/     /' "$root/out"
	fi
}

# the helper itself: the third field is ignored; only MENU_KEEP_SELECTED=1 (toggle-updates, a state editor) preselects
helper() {
	: >"$LOG"
	PATH="$bin:$PATH" bash -c '. "$1"; shift; "$@"' _ "$menu" "$@" >/dev/null 2>&1 </dev/null
}
helper menu_multi "H" "a^Alpha^1" "b^Beta^1"
if grep -q 'gum choose' "$LOG" && ! grep -q -- '--selected ' "$LOG"; then ok "menu_multi ignores a preselect flag"; else bad "menu_multi ignores a preselect flag"; fi
MENU_KEEP_SELECTED=1 helper menu_multi "H" "a^Alpha^1" "b^Beta^0"
if grep -q -- '--selected Alpha' "$LOG"; then ok "menu_multi preselects only with MENU_KEEP_SELECTED=1"; else bad "menu_multi preselects only with MENU_KEEP_SELECTED=1"; fi

recipe_ticks "user-setup" "$just_dir/60-custom.just" user-setup
recipe_ticks "gaming-setup" "$just_dir/60-custom.just" gaming-setup
recipe_ticks "niri-setup" "$just_dir/60-custom.just" niri-setup
if [ -r "$here/variants/dx/system_files/usr/share/ublue-os/just/75-octarine-virthost.just" ]; then
	recipe_ticks "virthost-setup" "$here/variants/dx/system_files/usr/share/ublue-os/just/75-octarine-virthost.just" virthost-setup
	recipe_ticks "dev" "$here/variants/dx/system_files/usr/share/ublue-os/just/70-octarine-dev.just" dev
fi

# the plain step question ("Apply?") defaults to N without a checklist: it is the `s` kind of ask(), never a Y default
if ! grep -rqE 'ask y "(Apply\?|Install )' "$just_dir" "$here/variants/dx/system_files/usr/share/ublue-os/just"; then ok "no step question defaults to Y"; else bad "no step question defaults to Y"; fi

echo
echo "passed: $pass, failed: $failn"
[ "$failn" = 0 ]
