#!/usr/bin/env bash
# Thin test: menu_one gives real gum a list height so a list that fits the screen never pages (Kevin, 2026-11-17).
# A stub ugum records GUM_CHOOSE_HEIGHT; a user-set value is left alone. Needs: bash.
# Run: tests/recipes/menu-one-height.sh
set -uo pipefail

here=$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)
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
mkdir -p "$root/bin"
printf '#!/bin/bash\necho "${GUM_CHOOSE_HEIGHT-unset}" >"$LOG"; echo "$2"\n' >"$root/bin/ugum"
chmod +x "$root/bin/ugum"
export LOG="$root/log" OCTARINE_MENU_FORCE_TTY=1

# run_one LINES COUNT: height ugum saw for COUNT items on a terminal of LINES rows
run_one() {
	local items=() i
	for i in $(seq 1 "$2"); do items+=("id$i^Item $i^0"); done
	env -u GUM_CHOOSE_HEIGHT ${3:+GUM_CHOOSE_HEIGHT=$3} PATH="$root/bin:$PATH" LINES="$1" \
		bash -c '. "$1"; shift; menu_one H "$@" >/dev/null' _ "$menu" "${items[@]}" </dev/null
	cat "$LOG"
}

[ "$(run_one 40 12)" = 12 ] && ok "12 items on 40 rows: height 12" || bad "12 items on 40 rows"
[ "$(run_one 20 30)" = 16 ] && ok "30 items on 20 rows: height 16 (rows - 4)" || bad "30 items on 20 rows"
[ "$(run_one 40 2)" = 3 ] && ok "2 items: height at least 3" || bad "2 items"
[ "$(run_one 40 12 7)" = 7 ] && ok "a user-set GUM_CHOOSE_HEIGHT is left alone" || bad "user-set height"

echo
echo "passed: $pass, failed: $failn"
[ "$failn" = 0 ]
