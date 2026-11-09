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
sysjq="$root/sysjq"
syspy="$root/syspy"
mkdir -p "$sysjq" "$syspy"
for c in "$sysbin"/*; do ln -sf "$(readlink -f "$c")" "$sysjq/$(basename "$c")"; ln -sf "$(readlink -f "$c")" "$syspy/$(basename "$c")"; done
p=$(command -v jq) && ln -sf "$p" "$sysjq/jq"
p=$(command -v python3) && ln -sf "$p" "$syspy/python3"
export LOG="$root/log" GUMQ="$root/q/gum" UGUMQ="$root/q/ugum" OCTARINE_MENU_LIB="$lib" HOME="$root/home" XDG_CACHE_HOME="$root/cache"
mkdir -p "$HOME"

cat >"$bin/gum" <<'F'
#!/usr/bin/env bash
echo "gum $*" >>"$LOG"
env | grep '^GUM_' | sort | sed 's/^/env /' >>"$LOG"
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
case " $* " in
    *" --dump "*) printf '%s' "${DUMP_JSON-}" ;;
    *" --summary "*) printf '%s\n' "${SUMMARY-a b}" ;;
esac
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
queue gum.1 'Apps: Steam\nApps: Lutris\n'
h 'menu_multi "Pick" "^── Apps ───^0" "steam^Steam^1" "protonup^ProtonUp-Qt^0" "lutris^Lutris^1"; echo "rc=$? result=${MENU_RESULT[*]}"'
check "multi: chosen texts map back to ids" grep -q 'result=steam lutris' "$root/out"
check "multi: --no-limit and the Bluefin prefixes" logged "choose --no-limit --height"
check "multi: selected prefix" logged "--selected-prefix ◉   --unselected-prefix ○   --cursor ▸   "
check "multi: header passed" logged "--header Pick"
check "multi: preselection uses the exact item texts (with the group prefix)" logged "--selected Apps: Steam,Apps: Lutris"
check "multi: a group label is never a row" notlogged "── Apps"
check "multi: the group label is not an item of its own" bash -c "! grep -q 'choose.* Apps ProtonUp' '$LOG'"
check "multi: key hint in the header" logged "x or space ticks an entry, ENTER confirms the ticked ones"
reset
export OCTARINE_MENU_FORCE_TTY=1
queue gum.1 '── Apps ───\n'
h 'menu_multi "" "^── Apps ───^0" "steam^Steam^0"; echo "rc=$? n=${#MENU_RESULT[@]}"'
check "multi: nothing returned for a stray divider" grep -q 'rc=0 n=0' "$root/out"
check "multi: nothing ticked prints a hint" grep -q "Nothing ticked: press x" "$root/out"
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

# ---- palette: ANSI colors only, user settings win
reset
export OCTARINE_MENU_FORCE_TTY=1
h 'menu_multi "" "a^A^0"; menu_confirm "Go?" y; menu_title T'
check "palette: cursor green" logged "env GUM_CHOOSE_CURSOR_FOREGROUND=2"
check "palette: selected green" logged "env GUM_CHOOSE_SELECTED_FOREGROUND=2"
check "palette: header blue" logged "env GUM_CHOOSE_HEADER_FOREGROUND=4"
check "palette: confirm prompt, selected and unselected buttons" bash -c "grep -q 'env GUM_CONFIRM_PROMPT_FOREGROUND=4' '$LOG' && grep -q 'env GUM_CONFIRM_SELECTED_BACKGROUND=2' '$LOG' && grep -q 'env GUM_CONFIRM_UNSELECTED_BACKGROUND=8' '$LOG'"
check "palette: titles use an ANSI color" logged "style --bold --foreground 4 T"
check "palette: no 256-color or hex values" bash -c "! grep '^env GUM_' '$LOG' | grep -E '=([0-9]{2,3}|#)'"
reset
export OCTARINE_MENU_FORCE_TTY=1
GUM_CHOOSE_CURSOR_FOREGROUND=212 GUM_CHOOSE_HEADER_FOREGROUND= h 'menu_multi "" "a^A^0"'
check "palette: a user's own value is kept" logged "env GUM_CHOOSE_CURSOR_FOREGROUND=212"
check "palette: a user's empty value is kept" logged "env GUM_CHOOSE_HEADER_FOREGROUND="
check "palette: unset ones still get the default" logged "env GUM_CHOOSE_SELECTED_FOREGROUND=2"

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

# ---- scoped menus: gnome-candy with no arguments (recipes read from `just --dump --dump-format json`)
JSON='{"first":"default","recipes":{
 "default":{"private":false,"doc":null,"attributes":[],"parameters":[]},
 "_hidden":{"private":true,"doc":"hidden","attributes":[],"parameters":[]},
 "install-theme":{"private":false,"doc":"Install a theme","attributes":[{"group":"themes"},"positional-arguments"],"parameters":[{"name":"name","default":"","kind":"singular"}]},
 "switch-icon":{"private":false,"doc":"Switch the icon set","attributes":[{"group":"icons"}],"parameters":[{"name":"name","default":null,"kind":"singular"}]},
 "list-themes":{"private":false,"doc":null,"attributes":[{"group":"themes"}],"parameters":[{"name":"rest","default":null,"kind":"star"}]}}}'
runc() { # PATH dir, stdin, args...
    local pd=$1 input=$2
    shift 2
    printf '%b' "$input" | PATH="$bin:$pd" "$REAL_JUST" --justfile "$justfile" --working-directory "$root" gnome-candy "$@" >"$root/out" 2>&1
    rc=$?
}
for variant in jq py; do
    if [ "$variant" = jq ]; then pd=$sysjq; else pd=$syspy; fi
    reset
    export OCTARINE_MENU_FORCE_TTY=1 DUMP_JSON="$JSON"
    queue ugum.1 'install-theme - Install a theme\n'
    runc "$pd" ''
    check "gnome-candy menu ($variant): public recipes only, name - comment, grouped order" logged "ugum choose switch-icon - Switch the icon set install-theme - Install a theme list-themes"
    check "gnome-candy menu ($variant): no private or default recipe" bash -c "! grep -E 'ugum choose' '$LOG' | grep -qE '_hidden|default'"
    check "gnome-candy menu ($variant): no group headings" bash -c "! grep -E 'ugum choose' '$LOG' | grep -qF '['"
    check "gnome-candy menu ($variant): an optional parameter never prompts" bash -c "grep -q 'install-theme\$' '$LOG' && ! grep -q 'name:' '$root/out'"
    reset
    export OCTARINE_MENU_FORCE_TTY=1 DUMP_JSON="$JSON"
    queue ugum.1 'switch-icon - Switch the icon set\n'
    runc "$pd" 'Papirus-Dark\n'
    check "gnome-candy menu ($variant): a required parameter prompts and is passed on" logged "switch-icon Papirus-Dark"
    reset
    export OCTARINE_MENU_FORCE_TTY=1 DUMP_JSON="$JSON"
    queue ugum.1 'switch-icon - Switch the icon set\n'
    runc "$pd" '\n'
    check "gnome-candy menu ($variant): an empty required value runs nothing" bash -c "! grep -q 'switch-icon' '$LOG' || ! grep -q '^just .*switch-icon' '$LOG'"
done
reset
export OCTARINE_MENU_FORCE_TTY=1 DUMP_JSON='{ not json'
runc "$sysjq" ''
check "gnome-candy menu: corrupt JSON shows the plain list, no menu" bash -c "! grep -q ugum '$LOG' && grep -q '  a' '$root/out'"
reset
export OCTARINE_MENU_FORCE_TTY=1 DUMP_JSON="$JSON"
runc "$sysbin" ''
check "gnome-candy menu: no jq and no python falls back to the plain list" bash -c "! grep -q ugum '$LOG' && grep -q 'Recipes of gnome-themes' '$root/out'"
reset
export OCTARINE_MENU_FORCE_TTY=1 DUMP_JSON="$JSON"
runc "$sysjq" '' list-themes
check "gnome-candy with arguments: straight through, no menu" bash -c "grep -q 'list-themes' '$LOG' && ! grep -q ugum '$LOG'"
reset
DUMP_JSON="$JSON" runc "$sysjq" ''
check "gnome-candy without a terminal: no menu" notlogged "ugum"

echo "passed: $pass, failed: $failn"
[ "$failn" = 0 ]
