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
check "recipe never runs sudo" bash -c "! grep -v '^ *#' '$root/body.sh' | grep -v 'printf' | grep -v 'No sudo' | grep -qE '(^|[^a-z-])sudo '"
check "recipe sets no color" bash -c "! grep -qE '\\\\033|tput' '$root/body.sh'"

# ---- the promoted defaults (layout, gestures, workspaces, Noctalia look, touchpad, window rules)
preinstall_dir="$repo/system_files/usr/share/flatpak/preinstall.d"
rules="$etc_niri/60-window-rules.kdl"
check "layout: centered focus on overflow, a centered single column, five presets, third-width default, shadow on behind windows, 32 pixel struts, tab indicator, hotkey overlay skipped, niri's colors" bash -c "f='$etc_niri/30-layout.kdl'; grep -q 'center-focused-column \"on-overflow\"' \$f && grep -q 'always-center-single-column true' \$f && [ \$(grep -c '^        proportion' \$f) = 5 ] && grep -q 'default-column-width { proportion 0.33333; }' \$f && grep -q 'draw-behind-window true' \$f && [ \$(grep -cE '^        (left|right|top|bottom) 32' \$f) = 4 ] && grep -q 'hide-when-single-tab' \$f && grep -q 'skip-at-startup' \$f && grep -q 'active-color \"#7fc8ff\"' \$f && grep -q 'screenshot-path' \$f && ! grep -qE 'a9b665|7daea3|gradient' \$f"
check "gestures: edge scroll, edge workspace switch, hot corners off" bash -c "f='$etc_niri/35-gestures.kdl'; grep -q 'trigger-width 30' \$f && grep -q 'trigger-height 50' \$f && [ \$(grep -c 'max-speed 1500' \$f) = 2 ] && grep -qE '^ +off\$' \$f"
check "touchpad: the shipped tap and natural-scroll stay, plus drag-lock, clickfinger and scroll-factor 0.3, each once; no mouse, trackpoint or empty extra blocks" bash -c "f='$etc_niri/20-input.kdl'; for k in '^ +tap\$' '^ +natural-scroll\$' '^ +drag-lock\$' 'click-method \"clickfinger\"' '^ +scroll-factor 0.3\$'; do [ \$(grep -cE \"\$k\" \$f) = 1 ] || exit 1; done; ! grep -qE '^ +(mouse|trackpoint)' \$f"
check "Noctalia part: its binds are unchanged (Mod+D, Mod+Space, Mod+S, Mod+Shift+S) and the look is added (corner radius, blur without xray, wallpaper on the backdrop, transparent background, layer rules, debug flag)" bash -c "f='$etc_niri/50-noctalia.kdl'; for k in 'Mod[+]D [{]' 'Mod[+]Space ' 'Mod[+]S ' 'Mod[+]Shift[+]S [{]' 'geometry-corner-radius 20' 'clip-to-geometry true' 'dev.noctalia.Noctalia' 'place-within-backdrop true' 'background-color \"transparent\"' 'workspace-shadow' 'honor-xdg-activation-with-invalid-serial' 'noctalia-window-switcher' 'passes 2'; do grep -qE \"\$k\" \$f || { echo missing \$k; exit 1; }; done; ! grep -q 'Mod+Comma' \$f"
check "the four named workspaces exist and every open-on-workspace of the window rules names one of them" bash -c "cd '$etc_niri' && for w in General Web Media Games; do grep -qx \"workspace \\\"\$w\\\"\" 45-workspaces.kdl || exit 1; done; for w in \$(grep -ho 'open-on-workspace \"[A-Za-z]*\"' 60-window-rules.kdl | sed 's/.*\"\\(.*\\)\"/\\1/' | sort -u); do grep -qx \"workspace \\\"\$w\\\"\" 45-workspaces.kdl || { echo unknown \$w; exit 1; }; done"
check "every app of the Flatpak preinstall lists has a deliberate entry in the window rules: a rule with its id, or an '// unrouted: <id>' line with the reason" bash -c "
  ids=\$(cat '$preinstall_dir'/*.preinstall | sed -n 's/^\\[Flatpak Preinstall \\(.*\\)\\]\$/\\1/p'); [ \$(wc -w <<<\"\$ids\") -ge 30 ] || exit 1
  for id in \$ids; do esc=\${id//./\\\\.}; grep -qF \"\$esc\" '$rules' || grep -qF \"// unrouted: \$id\" '$rules' || { echo \"no entry for \$id\"; exit 1; }; done"
check "password managers are hidden from screen capture (KeePassXC, GNOME Secrets), the dialog titles float, and no personal-only app is routed" bash -c "grep -q 'block-out-from \"screen-capture\"' '$rules' && grep -qF 'org\\.keepassxc\\.KeePassXC' '$rules' && grep -qF 'org\\.gnome\\.World\\.Secrets' '$rules' && grep -qF '(Open|Save|Save As' '$rules' && ! grep -qiE 'plex|cider|jetbrains|sunshine|fuzzel|zellij|vesktop|slack|discord|telegram' '$rules'"
# ---- terminal for Mod+T (step `terminal`): fake terminals on a temp PATH, a temp HOME, the real shipped files as the source tree
tbin="$root/tbin"; mkdir -p "$tbin"
realsrc="$root/realsrc"
rm -rf "$realsrc"; mkdir -p "$realsrc"; cp -r "$etc_niri" "$realsrc/niri"; cp -r "$share"/. "$realsrc/"
mkterm() { for t in "$@"; do printf '#!/bin/sh\nexit 0\n' >"$tbin/$t"; chmod +x "$tbin/$t"; done; }
rmterm() { rm -f "$tbin"/*; }
treset() { reset; rmterm; export PATH_BIN="$bin:$tbin"; SRC_OVERRIDE="$realsrc"; run '' --yes --only niri; }
bindline() { grep -E '^[[:space:]]*Mod\+T ' "$HOME/.config/niri/40-binds.kdl"; }
shipped_same() { cmp -s "$etc_niri/40-binds.kdl" "$realsrc/niri/40-binds.kdl" && grep -q 'spawn "alacritty"' "$etc_niri/40-binds.kdl"; }
treset
check "terminal: a fresh copy has the shipped alacritty line" bash -c "grep -q 'Open a Terminal: alacritty\" { spawn \"alacritty\"; }' '$HOME/.config/niri/40-binds.kdl'"
mkterm alacritty ptyxis ghostty kitty wezterm foot
for t in alacritty ptyxis ghostty kitty wezterm foot; do
    case $t in ptyxis) want="spawn \"ptyxis\" \"--new-window\";" ;; *) want="spawn \"$t\";" ;; esac
    run '' --only terminal --terminal "$t"
    check "terminal --terminal $t: exit 0, the user's Mod+T line is 'Open a Terminal: $t' with $want" bash -c "[ $rc = 0 ] && l=\$(grep -E '^[[:space:]]*Mod\\+T ' '$HOME/.config/niri/40-binds.kdl') && [[ \"\$l\" == *'hotkey-overlay-title=\"Open a Terminal: $t\"'* && \"\$l\" == *'$want'* ]]"
    check "terminal --terminal $t: only that one line of the user's file differs from the shipped one, the choice is recorded, the shipped files are untouched" bash -c "[ \$(diff '$etc_niri/40-binds.kdl' '$HOME/.config/niri/40-binds.kdl' | grep -c '^[<>]') -le 2 ] && grep -qx 'terminal=$t' '$HOME/.config/octarine-os/niri-terminal' && cmp '$etc_niri/40-binds.kdl' '$realsrc/niri/40-binds.kdl'"
    if command -v niri >/dev/null 2>&1; then check "terminal $t: niri validate accepts the user's copy" bash -c "niri validate -c '$HOME/.config/niri/config.kdl' >/dev/null 2>&1"; fi
done
check "terminal: nothing in the SHIPPED niri files or templates names ghostty, ptyxis, kitty, wezterm or foot (only the user copy may); the one exception is niri's own default window rule for WezTerm in 60-window-rules.kdl" bash -c "! grep -rniwE 'ghostty|ptyxis|kitty|wezterm|foot' '$etc_niri' '$share/keybinds' | grep -v '60-window-rules.kdl'"
run '' --only terminal --terminal foot
check "terminal: re-running with the same choice is already done and changes nothing" bash -c "[ $rc = 0 ] && grep -q 'already set to Foot' '$root/out' && grep -qE '^terminal +already done' '$root/out'"
run '' --only terminal --terminal kitty
check "terminal: re-running with another choice changes it (idempotent switch), shows the old and the new line" bash -c "[ $rc = 0 ] && grep -q '^    - Mod+T.*foot' '$root/out' && grep -q '^    + Mod+T.*kitty' '$root/out'"
check "terminal: the run shows the current choice and the undo command" bash -c "grep -q 'Current terminal for Mod+T: Foot' '$root/out' && grep -q 'terminal: run ujust niri-setup --only terminal --terminal alacritty' '$root/out'"
# detection: only installed terminals are offered, Alacritty always and first
treset; mkterm ptyxis kitty
run '2\n' --only terminal
check "terminal picker: Alacritty first and always, then only the installed ones (Ptyxis, Kitty); the missing ones are named in one line" bash -c "grep -q '1) Alacritty (shipped default)' '$root/out' && grep -q '2) Ptyxis' '$root/out' && grep -q '3) Kitty' '$root/out' && ! grep -qE '[0-9]\\) (Ghostty|WezTerm|Foot)' '$root/out' && grep -q 'Not found on this system (so not offered): Ghostty, WezTerm, Foot' '$root/out'"
check "terminal picker: choosing 2 sets Ptyxis" bash -c "grep -E '^[[:space:]]*Mod[+]T ' '$HOME/.config/niri/40-binds.kdl' | grep -q 'Open a Terminal: ptyxis\" { spawn \"ptyxis\" \"--new-window\"; }'"
run '' --only terminal
check "terminal picker: Enter keeps the CURRENT choice (Ptyxis here): already done, nothing changes" bash -c "[ $rc = 0 ] && grep -q 'already set to Ptyxis' '$root/out' && grep -E '^[[:space:]]*Mod[+]T ' '$HOME/.config/niri/40-binds.kdl' | grep -q ptyxis"
treset; mkterm
run '' --only terminal
check "terminal picker: with no terminal installed Alacritty is still offered" bash -c "grep -q '1) Alacritty (shipped default)' '$root/out' && ! grep -qE '[0-9]\\) (Ptyxis|Ghostty|Kitty|WezTerm|Foot)' '$root/out'"
# detection outside PATH: ~/.local/bin and the absolute path in the bind
treset; mkdir -p "$HOME/.local/bin"; printf '#!/bin/sh\nexit 0\n' >"$HOME/.local/bin/ghostty"; chmod +x "$HOME/.local/bin/ghostty"
run '' --only terminal --terminal ghostty
check "terminal: a Ghostty found only in ~/.local/bin is detected and spawned by absolute path (the niri session may not have it on PATH)" bash -c "[ $rc = 0 ] && grep -E '^[[:space:]]*Mod[+]T ' '$HOME/.config/niri/40-binds.kdl' | grep -q 'Open a Terminal: ghostty\" { spawn \"$HOME/.local/bin/ghostty\"; }' && ! grep -q 'not installed' '$root/out'"
run '' --only terminal --terminal ghostty
check "terminal: that absolute-path line is recognized as the recipe's own on the next run (already done)" bash -c "grep -q 'already set to Ghostty' '$root/out'"
# not installed / unknown
treset; mkterm alacritty
run '' --only terminal --terminal nosuch
check "terminal: an unknown name exits 2 with the list" bash -c "[ $rc = 2 ] && grep -q 'Unknown terminal: nosuch (use alacritty, ptyxis, ghostty, kitty, wezterm or foot)' '$root/out'"
run '' --only terminal --terminal
check "terminal: --terminal without a value exits 2" test "$rc" = 2
run 'n\n' --only terminal --terminal wezterm
check "terminal: a terminal that is not installed warns and asks (default no): answered n, nothing changes" bash -c "[ $rc = 0 ] && grep -q 'WezTerm is not installed here' '$root/out' && grep -E '^[[:space:]]*Mod[+]T ' '$HOME/.config/niri/40-binds.kdl' | grep -q alacritty && grep -q 'skipped (not installed)' '$root/out'"
run '' --only terminal --terminal wezterm --yes
check "terminal: --yes takes the default (no) for a missing terminal: nothing changes and it says --force" bash -c "grep -E '^[[:space:]]*Mod[+]T ' '$HOME/.config/niri/40-binds.kdl' | grep -q alacritty && grep -q -- '--force' '$root/out'"
run 'y\n' --only terminal --terminal wezterm
check "terminal: a missing terminal confirmed with y is set" bash -c "grep -E '^[[:space:]]*Mod[+]T ' '$HOME/.config/niri/40-binds.kdl' | grep -q 'Open a Terminal: wezterm\" { spawn \"wezterm\"; }'"
treset; mkterm alacritty
run '' --only terminal --terminal foot --force
check "terminal: --force sets a missing terminal without asking, with the warning" bash -c "[ $rc = 0 ] && grep -q 'Continuing because of --force' '$root/out' && grep -E '^[[:space:]]*Mod[+]T ' '$HOME/.config/niri/40-binds.kdl' | grep -q 'Open a Terminal: foot'"
# modes
treset; mkterm kitty
run '' --only terminal --terminal kitty --no
check "terminal: --no only prints the plan, nothing is written" bash -c "[ $rc = 0 ] && grep -q 'Plan: would set Mod+T to Kitty' '$root/out' && grep -E '^[[:space:]]*Mod[+]T ' '$HOME/.config/niri/40-binds.kdl' | grep -q alacritty && [ ! -e '$HOME/.config/octarine-os/niri-terminal' ]"
run '' --only terminal --yes
check "terminal: --yes alone does not change the terminal" bash -c "[ $rc = 0 ] && grep -q 'Skipped: --yes alone does not change the terminal' '$root/out' && grep -E '^[[:space:]]*Mod[+]T ' '$HOME/.config/niri/40-binds.kdl' | grep -q alacritty"
# a line the user changed is never touched
treset; mkterm kitty
f="$HOME/.config/niri/40-binds.kdl"
sed -i 's|^\( *\)Mod+T .*|\1Mod+T hotkey-overlay-title="My terminal" { spawn "my-term" "--special"; }|' "$f"; cp "$f" "$root/mine.kdl"
run '' --only terminal --terminal kitty
check "terminal: a Mod+T line the user changed is NOT clobbered; the exact line to use is printed; the run is not a failure" bash -c "[ $rc = 0 ] && cmp '$f' '$root/mine.kdl' && grep -q 'was changed by you, so it was left alone' '$root/out' && grep -q '    Mod+T hotkey-overlay-title=\"Open a Terminal: kitty\" { spawn \"kitty\"; }' '$root/out' && grep -q 'skipped (your Mod+T line is customized' '$root/out'"
sed -i 's|^\( *\)Mod+T .*|\1Mod+T { spawn "alacritty" "--class" "x"; }|' "$f"; cp "$f" "$root/mine.kdl"
run '' --only terminal --terminal kitty
check "terminal: a line without our title is customized too (left alone)" bash -c "cmp '$f' '$root/mine.kdl' && grep -q 'left alone' '$root/out'"
treset; mkterm kitty
sed -i 's|^\( *\)Mod+T hotkey-overlay-title="Open a Terminal: alacritty" { spawn "alacritty"; }|\1Mod+T hotkey-overlay-title="Open a Terminal: alacritty" { spawn "alacritty" "-e" "zsh"; }|' "$f"; cp "$f" "$root/mine.kdl"
run '' --only terminal --terminal kitty
check "terminal: our title with extra spawn arguments counts as the user's own line (left alone)" bash -c "cmp '$f' '$root/mine.kdl'"
# no copy yet
treset; rm -rf "$HOME/.config/niri"; mkterm kitty
run '' --only terminal --terminal kitty
check "terminal: with no copied niri config the choice is recorded for the keybind wizard and the run says to run the niri step" bash -c "[ $rc = 0 ] && grep -qx 'terminal=kitty' '$HOME/.config/octarine-os/niri-terminal' && grep -q 'run ujust niri-setup --only niri first' '$root/out'"
check "terminal: it is a listed step and part of --help" bash -c "cd '$root' && PATH='$bin:$sysbin' '$REAL_JUST' --justfile '$justfile' --working-directory '$root' niri-setup --help 2>&1 | grep -q 'Terminal for Mod+T (step terminal)'"
PATH_BIN="$bin"; SRC_OVERRIDE=""

# ---- shipped files
check "config.kdl only holds include lines (and comments), all relative, one per part" bash -c "cd '$etc_niri' && ! grep -vE '^(//.*|include \"[0-9][0-9]-[a-z-]+\.kdl\"|)\$' config.kdl && [ \$(grep -c '^include' config.kdl) = \$(ls [0-9][0-9]-*.kdl | wc -l) ] && ! grep -E 'include.*(/|~)' config.kdl"
check "every part is included" bash -c "cd '$etc_niri' && for f in [0-9][0-9]-*.kdl; do grep -qx \"include \\\"\$f\\\"\" config.kdl || exit 1; done"
check "no personal key model, theme or machine data" bash -c "! grep -nEi 'gruvbox|meh|hypr|helix|ghostty|/home/|/var/home|nox|asgard|kevin|riley|output \"(DP|HDMI|eDP)-' '$etc_niri'/*.kdl | grep -vE '^[^:]*:[0-9]+:\\s*//\\s+output|DP-1'"
check "no ghostty, ptyxis, kitty or foot anywhere in the shipped niri files (WezTerm only in niri's own default window rule); the terminal is alacritty" bash -c "! grep -niwE 'ghostty|ptyxis|kitty|foot' '$etc_niri'/*.kdl && ! grep -hvE '^[[:space:]]*//' '$etc_niri'/*.kdl | grep -iw wezterm | grep -vE 'org.{1,2}wezfurlong.{1,2}wezterm' && grep -q 'spawn \"alacritty\"' '$etc_niri/40-binds.kdl'"
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
check "smoke tests check the niri files and the three sources" bash -c "s='$repo/.github/scripts/default-smoke.sh'; grep -q '/etc/niri/config.kdl' \$s && grep -q 'niri-setup/niri-portals.conf' \$s && grep -q 'niri-setup/10-octarine-os.toml' \$s"

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
    check "niri validate: the copy that niri-setup makes (against the shipped sources)" bash -c "cd '$root' && rm -rf real && mkdir real; mkdir -p '$root/shipped/niri' && cp '$etc_niri'/*.kdl '$root/shipped/niri/' && cp -r '$share'/* '$root/shipped/' && PATH='$bin:$sysbin' HOME='$root/real' OCTARINE_NIRI_SETUP_SRC='$root/shipped' '$REAL_JUST' --justfile '$justfile' --working-directory '$root' niri-setup --yes --only niri >/dev/null 2>&1 && niri validate -c '$root/real/.config/niri/config.kdl' >/dev/null 2>&1 && cmp '$etc_niri/40-binds.kdl' '$root/real/.config/niri/40-binds.kdl'"
else
    echo "skip niri validate (niri is not installed here)"
fi

echo "passed: $pass, failed: $failn"
[ "$failn" = 0 ]
