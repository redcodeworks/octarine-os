#!/usr/bin/env bash
# Tests for `ujust niri-setup` (system_files/usr/share/ublue-os/just/60-custom.just) and the files it copies.
# gum, ugum, noctalia and sudo are fakes on a restricted PATH; HOME is a temp dir and the sources are a fake tree
# (OCTARINE_NIRI_SETUP_SRC); nothing real is touched. The shipped niri files are validated with `niri validate` when niri
# exists. Needs: bash, just. Run: tests/niri-setup.sh
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$here/..
justfile="$repo/system_files/usr/share/ublue-os/just/60-custom.just"
etc_niri="$repo/system_files/etc/niri"
share="$repo/system_files/usr/share/octarine-os/niri-setup"
root=$(mktemp -d)
trap 'rm -rf -- "$root"' EXIT
pass=0
failn=0
bin="$root/bin"
sysbin="$root/sysbin"
mkdir -p "$bin" "$sysbin"
export LOG="$root/log" HOME="$root/home" GUMQ="$root/gumq" UGUMQ="$root/ugumq"
export OCTARINE_MENU_LIB="$repo/system_files/usr/share/octarine-os/lib/menu.sh"
unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME OCTARINE_MENU_FORCE_TTY
REAL_JUST=$(command -v just)
for c in bash sh env cat grep awk sed cut tr date cmp diff mktemp mv rm cp mkdir head sort dirname basename wc chmod printf ls touch tee; do
    p=$(command -v "$c") && ln -sf "$p" "$sysbin/$c"
done
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
exit 0
F
cat >"$bin/ugum" <<'F'
#!/usr/bin/env bash
echo "ugum $*" >>"$LOG"
exit 0
F
cat >"$bin/noctalia" <<'F'
#!/bin/sh
exit 0
F
cat >"$bin/sudo" <<'F'
#!/usr/bin/env bash
echo "sudo $*" >>"$LOG"
exit 1
F
chmod +x "$bin"/*

# fake sources: three niri parts, the portal file and the Noctalia drop-in
src="$root/src"
mkfake() {
    rm -rf "$src"
    mkdir -p "$src/niri"
    printf 'include "10-a.kdl"\ninclude "20-b.kdl"\n' >"$src/niri/config.kdl"
    echo '// a' >"$src/niri/10-a.kdl"
    echo '// b' >"$src/niri/20-b.kdl"
    printf '[preferred]\nSecret=oo7-portal;\n' >"$src/niri-portals.conf"
    printf '# note\n[shell]\npolkit_agent = true\n' >"$src/10-octarine-os.toml"
}
reset() {
    rm -f "$root"/gumq.* "$LOG"
    unset OCTARINE_MENU_FORCE_TTY GUM_CONFIRM_RC
    rm -rf "$HOME"
    mkdir -p "$HOME"
    : >"$LOG"
    mkfake
    export PATH_BIN="$bin"
}
run() { # stdin text, args...
    local input=$1
    shift
    printf '%b' "$input" | PATH="$PATH_BIN:$sysbin" OCTARINE_NIRI_SETUP_SRC="${SRC_OVERRIDE:-$src}" "$REAL_JUST" --justfile "$justfile" --working-directory "$root" niri-setup "$@" >"$root/out" 2>&1
    rc=$?
}
gumq() { printf '%b' "$2" >"$root/gumq.$1"; }
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { failn=$((failn + 1)); echo "FAIL $1"; sed 's/^/     /' "$root/out" 2>/dev/null; }
check() { local d=$1; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
has() { grep -qF -- "$1" "$root/out"; }
hasnt() { ! grep -qF -- "$1" "$root/out"; }
logged() { grep -qF -- "$1" "$LOG"; }
notlogged() { ! grep -qF -- "$1" "$LOG"; }
cfg() { echo "$HOME/.config"; }
nbak() { ls "$1".bak-* 2>/dev/null | wc -l; }

# ---- fresh home
reset
run '' --yes
check "fresh home: exit 0" test "$rc" = 0
check "fresh home: niri parts copied" bash -c "cmp '$src/niri/10-a.kdl' '$HOME/.config/niri/10-a.kdl' && cmp '$src/niri/config.kdl' '$HOME/.config/niri/config.kdl' && cmp '$src/niri/20-b.kdl' '$HOME/.config/niri/20-b.kdl'"
check "fresh home: portal file copied (directories created)" cmp "$src/niri-portals.conf" "$HOME/.config/xdg-desktop-portal/niri-portals.conf"
check "fresh home: Noctalia drop-in copied" cmp "$src/10-octarine-os.toml" "$HOME/.config/noctalia/10-octarine-os.toml"
check "fresh home: three steps applied" bash -c "[ \$(grep -cE '^(niri|portals|polkit) +applied' '$root/out') = 3 ]"
check "fresh home: undo line per step" bash -c "grep -q '  niri: delete' '$root/out' && grep -q '  portals: delete' '$root/out' && grep -q '  polkit: delete' '$root/out'"
check "fresh home: tells what applies when" bash -c "grep -q 'reloads included config files live' '$root/out' && grep -q 'portals: applies at your next login' '$root/out' && grep -q 'restart Noctalia' '$root/out'"
check "fresh home: no backup files" test "$(find "$HOME" -name '*.bak-*' | wc -l)" = 0
check "no sudo anywhere" notlogged "sudo"

# ---- idempotent
: >"$LOG"
run '' --yes
check "second run: exit 0" test "$rc" = 0
check "second run: every step already done" bash -c "[ \$(grep -cE '^(niri|portals|polkit) +already done' '$root/out') = 3 ]"
check "second run: nothing applied, nothing to undo" bash -c "! grep -q 'To undo' '$root/out'"
check "second run: still no backups" test "$(find "$HOME" -name '*.bak-*' | wc -l)" = 0

# ---- a different existing file is kept by default
reset
mkdir -p "$HOME/.config/niri"
echo '// mine' >"$HOME/.config/niri/10-a.kdl"
run '' --yes
check "differing file with --yes: kept" test "$(cat "$HOME/.config/niri/10-a.kdl")" = "// mine"
check "differing file: diff shown" has "+// a"
check "differing file: exit 0 and reported as kept" bash -c "[ $rc = 0 ] && grep -q 'Kept your' '$root/out'"
check "differing file: no backup when kept" test "$(nbak "$HOME/.config/niri/10-a.kdl")" = 0
check "differing file: the other parts were still copied" cmp "$src/niri/20-b.kdl" "$HOME/.config/niri/20-b.kdl"
reset
mkdir -p "$HOME/.config/niri"
echo '// mine' >"$HOME/.config/niri/10-a.kdl"
run 'y\nn\n' --only niri
check "replace question answered n: kept" test "$(cat "$HOME/.config/niri/10-a.kdl")" = "// mine"
reset
mkdir -p "$HOME/.config/niri"
echo '// mine' >"$HOME/.config/niri/10-a.kdl"
run 'y\n\n' --only niri
check "replace question answered with Enter: kept (default is NO)" test "$(cat "$HOME/.config/niri/10-a.kdl")" = "// mine"
reset
mkdir -p "$HOME/.config/niri"
echo '// mine' >"$HOME/.config/niri/10-a.kdl"
run '' --only niri
check "no answer to read (no terminal): kept" test "$(cat "$HOME/.config/niri/10-a.kdl")" = "// mine"
reset
mkdir -p "$HOME/.config/niri"
echo '// mine' >"$HOME/.config/niri/10-a.kdl"
run 'y\ny\n' --only niri
check "replace question answered y: file replaced" cmp "$src/niri/10-a.kdl" "$HOME/.config/niri/10-a.kdl"
check "replace: timestamped backup with the old content" bash -c "b=\$(ls '$HOME'/.config/niri/10-a.kdl.bak-* | head -1); [[ \$b =~ \.bak-[0-9]{8}-[0-9]{6}(-[0-9]+)?\$ ]] && [ \"\$(cat \$b)\" = '// mine' ]"
check "replace: exactly one backup" test "$(nbak "$HOME/.config/niri/10-a.kdl")" = 1
check "replace: summary says applied" bash -c "grep -qE '^niri +applied' '$root/out'"
reset
mkdir -p "$HOME/.config/niri"
echo '// my own config' >"$HOME/.config/niri/config.kdl"
run '' --yes --only niri
check "kept config.kdl: the user is told the parts are unused" has "your config.kdl was kept"
reset
mkdir -p "$HOME/.config/noctalia"
printf '[shell]\npolkit_agent = false\n' >"$HOME/.config/noctalia/10-octarine-os.toml"
run '' --yes --only polkit
check "different Noctalia drop-in is kept too" bash -c "grep -q 'false' '$HOME/.config/noctalia/10-octarine-os.toml'"
reset
mkdir -p "$HOME/.config/xdg-desktop-portal"
echo 'mine' >"$HOME/.config/xdg-desktop-portal/niri-portals.conf"
run '' --yes --only portals
check "different portal file is kept too" test "$(cat "$HOME/.config/xdg-desktop-portal/niri-portals.conf")" = mine

# ---- --no, --only, errors, help
reset
run '' --no
check "--no: exit 0, nothing written" bash -c "[ $rc = 0 ] && [ ! -e '$HOME/.config' ]"
check "--no: plan lists three planned steps" bash -c "[ \$(grep -c 'planned' '$root/out') -ge 3 ]"
reset
mkdir -p "$HOME/.config/niri"
echo '// mine' >"$HOME/.config/niri/10-a.kdl"
run '' --no
check "--no: existing different file untouched and no backup" bash -c "[ \"\$(cat '$HOME/.config/niri/10-a.kdl')\" = '// mine' ] && [ \$(ls '$HOME'/.config/niri/*.bak-* 2>/dev/null | wc -l) = 0 ]"
reset
run '' --yes --only portals
check "--only portals: only the portal file" bash -c "[ -f '$HOME/.config/xdg-desktop-portal/niri-portals.conf' ] && [ ! -e '$HOME/.config/niri' ] && [ ! -e '$HOME/.config/noctalia' ]"
reset
run '' --yes --only polkit,portals
check "--only with a list: both steps, not niri" bash -c "[ -f '$HOME/.config/noctalia/10-octarine-os.toml' ] && [ -f '$HOME/.config/xdg-desktop-portal/niri-portals.conf' ] && [ ! -e '$HOME/.config/niri' ]"
reset
run '' --yes --only nonsense
check "--only unknown step: exit 2" test "$rc" = 2
run '' --bogus
check "unknown option: exit 2" test "$rc" = 2
run '' extra
check "stray argument: exit 2" test "$rc" = 2
run '' --only
check "--only without a list: exit 2" test "$rc" = 2
run '' --help
check "--help: exit 0 and describes the steps" bash -c "[ $rc = 0 ] && grep -q 'niri (copies' '$root/out' && grep -q 'bak-YYYYMMDD-HHMMSS' '$root/out'"
run '' help
check "help: exit 0" test "$rc" = 0
check "a failed run is not reported for --help (nothing written)" test ! -e "$HOME/.config"

# ---- missing noctalia, missing sources
reset
PATH_BIN="$root/nonoct"
mkdir -p "$PATH_BIN"
cp "$bin"/gum "$bin"/ugum "$bin"/sudo "$PATH_BIN"/
run '' --yes
check "no noctalia: polkit skipped, exit 0" bash -c "[ $rc = 0 ] && grep -qE '^polkit +skipped \(noctalia not installed\)' '$root/out' && [ ! -e '$HOME/.config/noctalia' ]"
check "no noctalia: the other steps still ran" bash -c "[ -f '$HOME/.config/niri/config.kdl' ] && [ -f '$HOME/.config/xdg-desktop-portal/niri-portals.conf' ]"
reset
rm -rf "$src/niri"
run '' --yes
check "no niri sources: step skipped, not failed" bash -c "grep -qE '^niri +skipped \(no source files\)' '$root/out'"
reset
rm -f "$src/niri-portals.conf"
run '' --yes
check "missing portal source: FAILED, exit 1, other steps ran, re-run hint" bash -c "[ $rc = 1 ] && grep -qE '^portals +FAILED' '$root/out' && grep -q 'ujust niri-setup --only portals' '$root/out' && [ -f '$HOME/.config/niri/config.kdl' ]"

# ---- menus: no terminal means no menu; a faked terminal opens the checklist
reset
run '' --yes
check "no terminal: no gum call" notlogged "gum choose"
reset
export OCTARINE_MENU_FORCE_TTY=1
gumq 1 'Portal config with the oo7 secret portal\n'
run ''
check "checklist: chosen step runs without a second Apply? question" bash -c "[ -f '$HOME/.config/xdg-desktop-portal/niri-portals.conf' ] && ! grep -q 'Apply?' '$root/out'"
check "checklist: unchosen steps do not run" bash -c "[ ! -e '$HOME/.config/niri' ] && [ ! -e '$HOME/.config/noctalia' ]"
check "checklist: all three rows preselected, no divider rows" bash -c "grep -q -- '--selected Niri config files in ~/.config/niri,Portal config with the oo7 secret portal,Noctalia polkit agent drop-in' '$LOG' && ! grep -q '──' '$LOG'"
reset
export OCTARINE_MENU_FORCE_TTY=1
run ''
check "checklist: Esc (nothing chosen) changes nothing, exit 0" bash -c "[ $rc = 0 ] && [ ! -e '$HOME/.config' ]"
reset
export OCTARINE_MENU_FORCE_TTY=1 GUM_CONFIRM_RC=1
gumq 1 'Niri config files in ~/.config/niri\n'
run ''
check "checklist: declining the confirmation changes nothing" test ! -e "$HOME/.config"
reset
export OCTARINE_MENU_FORCE_TTY=1
mkdir -p "$HOME/.config/niri"
echo '// mine' >"$HOME/.config/niri/10-a.kdl"
gumq 1 'Niri config files in ~/.config/niri\n'
run 'n\n'
check "checklist: replacing a different file is still its own question (default keep)" test "$(cat "$HOME/.config/niri/10-a.kdl")" = "// mine"
reset
export OCTARINE_MENU_FORCE_TTY=1
run '' --yes
check "menus: --yes opens none" notlogged "gum choose"
run '' --only niri
check "menus: --only opens none" notlogged "gum choose"
unset OCTARINE_MENU_FORCE_TTY

# ---- the recipe itself
awk '/^niri-setup \*args:/{f=1} f&&/^# Themes and icons/{exit} f' "$justfile" >"$root/body.sh"
check "recipe has the Setup group and a one-line comment above it" bash -c "grep -B2 '^niri-setup' '$justfile' | grep -q '^\[group(.Setup.)\]' && grep -B3 '^niri-setup' '$justfile' | grep -qE '^# .{20,80}\$'"
check "recipe never runs sudo" bash -c "! grep -v '^ *#' '$root/body.sh' | grep -v 'printf' | grep -v 'No sudo' | grep -qE '(^|[^a-z-])sudo '"
check "recipe sets no color" bash -c "! grep -qE '\\\\033|tput' '$root/body.sh'"

# ---- shipped files
check "config.kdl only holds include lines (and comments), all relative, one per part" bash -c "cd '$etc_niri' && ! grep -vE '^(//.*|include \"[0-9][0-9]-[a-z-]+\.kdl\"|)\$' config.kdl && [ \$(grep -c '^include' config.kdl) = \$(ls [0-9][0-9]-*.kdl | wc -l) ] && ! grep -E 'include.*(/|~)' config.kdl"
check "every part is included" bash -c "cd '$etc_niri' && for f in [0-9][0-9]-*.kdl; do grep -qx \"include \\\"\$f\\\"\" config.kdl || exit 1; done"
check "no personal key model, theme or machine data" bash -c "! grep -nEi 'gruvbox|meh|hypr|helix|ghostty|/home/|/var/home|nox|asgard|kevin|riley|output \"(DP|HDMI|eDP)-' '$etc_niri'/*.kdl | grep -vE '^[^:]*:[0-9]+:\\s*//\\s+output|DP-1'"
check "no ghostty or ptyxis anywhere in the shipped niri files; the terminal is alacritty" bash -c "! grep -niE 'ghostty|ptyxis' '$etc_niri'/*.kdl && grep -q 'spawn \"alacritty\"' '$etc_niri/40-binds.kdl'"
check "no Ctrl+Shift+Alt binds (the MEH layer)" bash -c "! grep -q 'Ctrl+Shift+Alt' '$etc_niri'/*.kdl"
check "startup: exactly one spawn-at-startup, the documented noctalia one" bash -c "[ \$(cat '$etc_niri'/*.kdl | grep -cE '^[[:space:]]*spawn(-sh)?-at-startup') = 1 ] && grep -qx 'spawn-at-startup \"noctalia\"' '$etc_niri/50-noctalia.kdl'"
check "no second polkit agent is started" bash -c "! grep -iE 'spawn.*polkit' '$etc_niri'/*.kdl"
check "the packaged niri default spawns waybar; ours must not" bash -c "! grep -q waybar '$etc_niri'/*.kdl | grep -v '^[[:space:]]*//'"
check "binds keep niri's usual keys (Mod+T terminal, Mod+Q close, Mod+O overview)" bash -c "grep -qE '^ *Mod\\+T .*spawn' '$etc_niri/40-binds.kdl' && grep -q 'Mod+Q' '$etc_niri/40-binds.kdl' && grep -q 'Mod+O' '$etc_niri/40-binds.kdl'"
check "the shipped Noctalia drop-in says exactly what was agreed" bash -c "[ \"\$(grep -v '^#' '$share/10-octarine-os.toml' | tr '\n' '|')\" = '[shell]|polkit_agent = true|' ] && [ \"\$(grep '^#' '$share/10-octarine-os.toml' | sed 's/^# *//' | tr '\n' ' ' | sed 's/ \$//')\" = 'Added by \`ujust niri-setup\`: Noctalia'\\''s built-in polkit authentication agent is off by default; niri has no agent of its own, so without this privileged prompts fail in a niri session. Do not run another polkit agent beside it.' ]"
check "the Noctalia drop-in parses as TOML" python3 -I -c "
import tomllib,sys
d=tomllib.load(open(sys.argv[1],'rb')); assert d=={'shell':{'polkit_agent':True}}, d" "$share/10-octarine-os.toml"
check "portal file keeps the packaged lines and sets the oo7 Secret portal" bash -c "f='$share/niri-portals.conf'; grep -qx '\\[preferred\\]' \$f && grep -qx 'default=gnome;gtk;' \$f && grep -qx 'org.freedesktop.impl.portal.Access=gtk;' \$f && grep -qx 'org.freedesktop.impl.portal.Notification=gtk;' \$f && grep -qx 'org.freedesktop.impl.portal.Secret=oo7-portal;' \$f && ! grep -qiE 'EXAMPLE|do not install' \$f"
check "the portal and polkit sources are NOT in /etc (nothing applies without the recipe)" bash -c "[ ! -e '$repo/system_files/etc/xdg-desktop-portal' ] && [ ! -e '$repo/system_files/etc/noctalia' ] && [ ! -e '$repo/system_files/usr/share/xdg-desktop-portal' ]"
check "user-setup has no polkit step" bash -c "! grep 'valid_steps=\" groups' '$justfile' | grep -q polkit"
check "smoke tests check the niri files and the three sources in both workflows" bash -c "for w in build.yml build-beta.yml; do grep -q '/etc/niri/config.kdl' '$repo/.github/workflows/'\$w && grep -q 'niri-setup/niri-portals.conf' '$repo/.github/workflows/'\$w && grep -q 'niri-setup/10-octarine-os.toml' '$repo/.github/workflows/'\$w || exit 1; done"

if command -v niri >/dev/null 2>&1; then
    # every combination of parts: leave out any subset of the include lines (a user deleting lines), in a copy under a
    # temp home, so the relative paths are exercised where `ujust niri-setup` puts them
    parts=("$etc_niri"/[0-9][0-9]-*.kdl)
    n=${#parts[@]}
    allok=1
    for ((mask = 0; mask < (1 << n); mask++)); do
        d="$root/combo/$mask/niri"
        mkdir -p "$d"
        cp "$etc_niri"/*.kdl "$d"/
        for ((k = 0; k < n; k++)); do
            if (( (mask >> k) & 1 )); then sed -i "/^include \"$(basename "${parts[$k]}")\"/d" "$d/config.kdl"; fi
        done
        niri validate -c "$d/config.kdl" >"$root/v.out" 2>&1 || { allok=0; echo "combination $mask failed:"; tail -5 "$root/v.out"; }
    done
    check "niri validate: all $((1 << n)) include combinations in a copied directory" test "$allok" = 1
    check "niri validate: the shipped /etc/niri set as it is" bash -c "niri validate -c '$etc_niri/config.kdl' >/dev/null 2>&1"
    check "niri validate: each part alone (including a part without the others)" bash -c "for f in '$etc_niri'/[0-9][0-9]-*.kdl; do niri validate -c \$f >/dev/null 2>&1 || exit 1; done"
    check "niri validate: the copy that niri-setup makes (against the shipped sources)" bash -c "cd '$root' && rm -rf real && mkdir real; mkdir -p '$root/shipped/niri' && cp '$etc_niri'/*.kdl '$root/shipped/niri/' && cp '$share'/* '$root/shipped/' && PATH='$bin:$sysbin' HOME='$root/real' OCTARINE_NIRI_SETUP_SRC='$root/shipped' '$REAL_JUST' --justfile '$justfile' --working-directory '$root' niri-setup --yes --only niri >/dev/null 2>&1 && niri validate -c '$root/real/.config/niri/config.kdl' >/dev/null 2>&1 && cmp '$etc_niri/40-binds.kdl' '$root/real/.config/niri/40-binds.kdl'"
else
    echo "skip niri validate (niri is not installed here)"
fi

echo "passed: $pass, failed: $failn"
[ "$failn" = 0 ]
