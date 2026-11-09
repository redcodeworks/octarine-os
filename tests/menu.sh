#!/usr/bin/env bash
# Tests for the shared menu helper (system_files/usr/share/octarine-os/lib/menu.sh) and the scoped menus of
# `ujust toolbox` and `ujust gnome-candy`, with fake gum, ugum, ujust, just and git. Run: tests/menu.sh
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
lib="$here/../system_files/usr/share/octarine-os/lib/menu.sh"
justfile="$here/../system_files/usr/share/ublue-os/just/60-custom.just"
root=$(mktemp -d)
trap 'rm -rf -- "$root"' EXIT
pass=0
failn=0
bin="$root/bin"
sysbin="$root/sysbin"
mkdir -p "$bin" "$sysbin" "$root/q"
REAL_JUST=$(command -v just)
for c in bash sh env cat grep sed awk tr cut mkdir rm mktemp id head basename dirname sort printf tput wc cmp mv cp date readlink touch ls; do
    p=$(command -v "$c") && ln -sf "$p" "$sysbin/$c"
done
export LOG="$root/log" GUMQ="$root/q/gum" UGUMQ="$root/q/ugum" OCTARINE_MENU_LIB="$lib" HOME="$root/home" XDG_CACHE_HOME="$root/cache"
mkdir -p "$HOME"

cat >"$bin/gum" <<'F'
#!/usr/bin/env bash
echo "gum $*" >>"$LOG"
case "$1" in
    choose)
        n=$(( $(cat "$GUMQ.n" 2>/dev/null || echo 0) + 1 )); echo "$n" >"$GUMQ.n"
        [ -f "$GUMQ.$n" ] && cat "$GUMQ.$n"
        exit 0
        ;;
    confirm) exit "${GUM_CONFIRM_RC:-0}" ;;
    style) echo "${@: -1}" ;;
esac
F
cat >"$bin/ugum" <<'F'
#!/usr/bin/env bash
echo "ugum $*" >>"$LOG"
n=$(( $(cat "$UGUMQ.n" 2>/dev/null || echo 0) + 1 )); echo "$n" >"$UGUMQ.n"
[ -f "$UGUMQ.$n" ] && cat "$UGUMQ.$n"
exit 0
F
cat >"$bin/ujust" <<'F'
#!/usr/bin/env bash
echo "ujust $*" >>"$LOG"
F
cat >"$bin/git" <<'F'
#!/usr/bin/env bash
if [ "$1" = clone ]; then mkdir -p "${@: -1}/.git"; echo "x:" >"${@: -1}/justfile"; fi
exit 0
F
cat >"$bin/just" <<'F'
#!/usr/bin/env bash
echo "just $*" >>"$LOG"
case " $* " in *" --list "*) printf '%b' "${JUST_LIST-}" ;; esac
exit 0
F
chmod +x "$bin"/*

ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { failn=$((failn + 1)); echo "FAIL $1"; [ -f "$root/out" ] && sed 's/^/     /' "$root/out"; }
check() { local d=$1; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
logged() { grep -qF -- "$1" "$LOG"; }
notlogged() { ! grep -qF -- "$1" "$LOG"; }
reset() { : >"$LOG"; rm -f "$root"/q/*; unset GUM_CONFIRM_RC OCTARINE_MENU_FORCE_TTY JUST_LIST; : >"$root/out"; }
queue() { printf '%b' "$2" >"$root/q/$1"; } # gum.1 / ugum.1 contents

# helper functions in a subshell with the fake binaries on PATH
h() { # script text; the helper library is sourced; PATH is restricted
    PATH="$bin:$sysbin" bash -c ". '$lib'; $1" >"$root/out" 2>&1
}

# ---- availability
reset
h 'menu_ready'
check "no terminal: menu_ready false" test $? -ne 0
export OCTARINE_MENU_FORCE_TTY=1
h 'menu_ready'
check "forced terminal with gum: menu_ready true" test $? -eq 0
h 'menu_ready_one'
check "forced terminal with ugum: menu_ready_one true" test $? -eq 0
PATH="$sysbin" bash -c ". '$lib'; menu_ready" >/dev/null 2>&1
check "no gum: menu_ready false" test $? -ne 0

# ---- menu_multi
reset
export OCTARINE_MENU_FORCE_TTY=1
queue gum.1 'Steam\nLutris\n'
h 'menu_multi "Pick" "^── Apps ───^0" "steam^Steam^1" "protonup^ProtonUp-Qt^0" "lutris^Lutris^1"; echo "rc=$? result=${MENU_RESULT[*]}"'
check "multi: chosen texts map back to ids" grep -q 'result=steam lutris' "$root/out"
check "multi: --no-limit and the Bluefin prefixes" logged "choose --no-limit --height"
check "multi: selected prefix" logged "--selected-prefix ◉   --unselected-prefix ○   --cursor ▸   "
check "multi: header passed" logged "--header Pick"
check "multi: preselection uses the exact item texts" logged "--selected Steam,Lutris"
check "multi: heading shown as an item" logged "── Apps ───"
reset
export OCTARINE_MENU_FORCE_TTY=1
queue gum.1 '── Apps ───\n'
h 'menu_multi "" "^── Apps ───^0" "steam^Steam^0"; echo "rc=$? n=${#MENU_RESULT[@]}"'
check "multi: a heading is never returned" grep -q 'rc=0 n=0' "$root/out"
reset
export OCTARINE_MENU_FORCE_TTY=1
h 'menu_multi "" "steam^Steam^1"; echo "rc=$? n=${#MENU_RESULT[@]}"'
check "multi: Esc or empty output is rc 0 with nothing chosen" grep -q 'rc=0 n=0' "$root/out"
reset
export OCTARINE_MENU_FORCE_TTY=1
queue gum.1 'Add a; b\n'
h 'menu_multi "" "x^Add a, b^0"; echo "result=${MENU_RESULT[*]}"'
check "multi: commas in text become semicolons and still map back" grep -q 'result=x' "$root/out"
reset
PATH="$sysbin" bash -c ". '$lib'; OCTARINE_MENU_FORCE_TTY=1 menu_multi '' 'a^A^0'; echo rc=\$?" >"$root/out" 2>&1
check "multi: no gum returns 3 (caller falls back)" grep -q 'rc=3' "$root/out"
reset
h 'menu_multi "" "a^A^0"; echo rc=$?'
check "multi: no terminal returns 3" grep -q 'rc=3' "$root/out"

# ---- menu_one
reset
export OCTARINE_MENU_FORCE_TTY=1
queue ugum.1 'Second one\n'
h 'menu_one "Header" "a^First one" "b^Second one"; echo "rc=$? one=$MENU_ONE"'
check "one: chosen text maps back to the id" grep -q 'rc=0 one=b' "$root/out"
check "one: the header is printed, not passed to ugum" bash -c "grep -q '^Header' '$root/out' && ! grep -q -- '--header' '$LOG'"
check "one: ugum gets only the items" logged "ugum choose First one Second one"
reset
export OCTARINE_MENU_FORCE_TTY=1
h 'menu_one "" "a^A"; echo "rc=$? one=[$MENU_ONE]"'
check "one: empty output means cancelled (rc 1)" grep -q 'rc=1 one=\[\]' "$root/out"
PATH="$sysbin" bash -c ". '$lib'; OCTARINE_MENU_FORCE_TTY=1 menu_one '' 'a^A'; echo rc=\$?" >"$root/out" 2>&1
check "one: no ugum returns 3" grep -q 'rc=3' "$root/out"

# ---- menu_confirm
reset
export OCTARINE_MENU_FORCE_TTY=1
h 'menu_confirm "Go?" y; echo rc=$?'
check "confirm with gum: yes" grep -q 'rc=0' "$root/out"
check "confirm with gum: default y passes no --default flag" bash -c "! grep -q -- '--default=false' '$LOG'"
GUM_CONFIRM_RC=1 h 'menu_confirm "Go?" y; echo rc=$?'
check "confirm with gum: Esc or no is no" grep -q 'rc=1' "$root/out"
: >"$LOG"
h 'menu_confirm "Go?"; echo rc=$?'
check "confirm with gum: default n sets --default=false" logged "confirm --default=false Go?"
unset OCTARINE_MENU_FORCE_TTY
plain() { printf '%b' "$2" | PATH="$sysbin" bash -c ". '$lib'; menu_confirm 'Go?' $1; echo rc=\$?" 2>&1 | grep -o 'rc=[0-9]'; }
check "confirm plain: y is yes" test "$(plain n 'y\n')" = rc=0
check "confirm plain: empty answer is no (default n)" test "$(plain n '\n')" = rc=1
check "confirm plain: end of input is no" test "$(plain n '')" = rc=1
check "confirm plain: empty answer is yes when the default is y" test "$(plain y '\n')" = rc=0
check "confirm plain: n is no even when the default is y" test "$(plain y 'n\n')" = rc=1

# ---- scoped menus: toolbox with no arguments
tdefs="$root/defs"
mkdir -p "$tdefs"
printf '[a]\nimage=example.com/a:latest\n' >"$tdefs/a.ini"
runrecipe() { # recipe, stdin, args...
    local r=$1 input=$2
    shift 2
    printf '%b' "$input" | PATH="$bin:$sysbin" TOOLBOX_DEFINITIONS="$tdefs" UPM_CONF="$root/distrobox.conf" UPM_BREW_DIR="$root/brew" \
        "$REAL_JUST" --justfile "$justfile" --working-directory "$root" "$r" "$@" >"$root/out" 2>&1
    rc=$?
}
reset
export OCTARINE_MENU_FORCE_TTY=1
queue ugum.1 'a\n'
queue ugum.2 'show tools and state\n'
runrecipe toolbox ''
check "toolbox menu: the chosen action runs ujust toolbox <name> --list" logged "ujust toolbox a --list"
reset
export OCTARINE_MENU_FORCE_TTY=1
queue ugum.1 'a\n'
queue ugum.2 'remove the box\n'
GUM_CONFIRM_RC=1 runrecipe toolbox ''
check "toolbox menu: remove asks first and no stops" notlogged "ujust toolbox a --remove"
reset
export OCTARINE_MENU_FORCE_TTY=1
runrecipe toolbox ''
check "toolbox menu: cancelled choice exits quietly" test "$rc" = 0
check "toolbox menu: nothing run" notlogged "ujust toolbox"
reset
runrecipe toolbox ''
check "toolbox without a terminal: list only, no menu" notlogged "ugum"
reset
export OCTARINE_MENU_FORCE_TTY=1
runrecipe toolbox '' a --list
check "toolbox with arguments: no menu" notlogged "ugum"

# ---- scoped menus: gnome-candy with no arguments
reset
export OCTARINE_MENU_FORCE_TTY=1 JUST_LIST='install-theme  # Install a theme\nswitch-icon NAME  # Switch the icon set\n'
queue ugum.1 'install-theme - Install a theme\n'
runrecipe gnome-candy ''
check "gnome-candy menu: items are name - comment" logged "ugum choose install-theme - Install a theme switch-icon - Switch the icon set"
check "gnome-candy menu: the choice runs in the checkout" logged "install-theme"
reset
export OCTARINE_MENU_FORCE_TTY=1 JUST_LIST='install-theme  # Install a theme\nswitch-icon NAME  # Switch the icon set\n'
queue ugum.1 'switch-icon - Switch the icon set\n'
runrecipe gnome-candy 'Papirus-Dark\n'
check "gnome-candy menu: a recipe with parameters asks for them" logged "switch-icon Papirus-Dark"
reset
export OCTARINE_MENU_FORCE_TTY=1 JUST_LIST='install-theme  # x\n'
runrecipe gnome-candy '' list-themes
check "gnome-candy with arguments: straight through, no menu" bash -c "grep -q 'list-themes' '$LOG' && ! grep -q ugum '$LOG'"
reset
JUST_LIST='install-theme  # x\n' runrecipe gnome-candy ''
check "gnome-candy without a terminal: no menu" notlogged "ugum"

echo "passed: $pass, failed: $failn"
[ "$failn" = 0 ]
