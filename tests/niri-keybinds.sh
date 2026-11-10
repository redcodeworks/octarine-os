#!/usr/bin/env bash
# Tests for the EXPERIMENTAL keybind wizard, the `keybinds` step of `ujust niri-setup`
# (system_files/usr/share/ublue-os/just/60-custom.just, templates in system_files/usr/share/octarine-os/niri-setup/keybinds/).
# gum, ugum and niri are fakes on a restricted PATH unless a test needs the real niri (the matrix); HOME is a temp dir and the
# sources are a copy of the shipped tree (OCTARINE_NIRI_SETUP_SRC); nothing real is touched.
# Needs: bash, just, python3 (the duplicate-bind check); niri when installed (`niri validate`). Run: tests/niri-keybinds.sh
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$here/..
justfile="$repo/system_files/usr/share/ublue-os/just/60-custom.just"
etc_niri="$repo/system_files/etc/niri"
share="$repo/system_files/usr/share/octarine-os/niri-setup"
kbdir="$share/keybinds"
root=$(mktemp -d)
trap 'rm -rf -- "$root"' EXIT
pass=0
failn=0
bin="$root/bin"
sysbin="$root/sysbin"
realbin="$root/realbin"
mkdir -p "$bin" "$sysbin" "$realbin"
export LOG="$root/log" HOME="$root/home" UGUMQ="$root/ugumq" GUMQ="$root/gumq"
export OCTARINE_MENU_LIB="$repo/system_files/usr/share/octarine-os/lib/menu.sh"
unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME OCTARINE_MENU_FORCE_TTY
REAL_JUST=$(command -v just)
for c in bash sh env cat grep awk sed cut tr date cmp diff mktemp mv rm cp mkdir head sort dirname basename wc chmod printf ls touch tee find; do
    p=$(command -v "$c") && ln -sf "$p" "$sysbin/$c"
done
have_niri=0
if command -v niri >/dev/null 2>&1; then have_niri=1; ln -sf "$(command -v niri)" "$realbin/niri"; fi

# gum: checklist rows come from a queue file (the exact row text); ugum: the queue holds the 1-based index of the item
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
if [ "$1" = choose ]; then
    shift
    n=$(( $(cat "$UGUMQ.n" 2>/dev/null || echo 0) + 1 )); echo "$n" >"$UGUMQ.n"
    for a in "$@"; do echo "item: $a" >>"$LOG"; done
    if [ -s "$UGUMQ.$n" ]; then idx=$(cat "$UGUMQ.$n"); printf '%s\n' "${!idx}"; fi
fi
exit 0
F
cat >"$bin/sudo" <<'F'
#!/usr/bin/env bash
echo "sudo $*" >>"$LOG"
exit 1
F
# a niri whose validate always fails (restore test)
mkdir -p "$root/failbin"
cat >"$root/failbin/niri" <<'F'
#!/usr/bin/env bash
echo "niri $*" >>"$LOG"
echo "Error: fake parse error at line 1" >&2
exit 1
F
chmod +x "$bin"/* "$root/failbin/niri"

# the source tree: the real shipped files
src="$root/src"
mkreal() {
    rm -rf "$src"
    mkdir -p "$src/niri"
    cp "$etc_niri"/*.kdl "$src/niri/"
    cp -r "$share"/* "$src/"
}
reset() {
    rm -f "$root"/ugumq.* "$root"/gumq.* "$LOG"
    unset OCTARINE_MENU_FORCE_TTY GUM_CONFIRM_RC
    rm -rf "$HOME"
    mkdir -p "$HOME"
    : >"$LOG"
    mkreal
    PATH_BIN="$bin"
}
run() { # stdin text, args...
    local input=$1
    shift
    printf '%b' "$input" | PATH="$PATH_BIN:$sysbin" OCTARINE_NIRI_SETUP_SRC="$src" "$REAL_JUST" --justfile "$justfile" --working-directory "$root" niri-setup "$@" >"$root/out" 2>&1
    rc=$?
}
ugumq() { printf '%s' "$2" >"$root/ugumq.$1"; }
gumq() { printf '%b' "$2" >"$root/gumq.$1"; }
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { failn=$((failn + 1)); echo "FAIL $1"; sed 's/^/     /' "$root/out" 2>/dev/null | tail -30; }
check() { local d=$1; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
has() { grep -qF -- "$1" "$root/out"; }
hasnt() { ! grep -qF -- "$1" "$root/out"; }
logged() { grep -qF -- "$1" "$LOG"; }
notlogged() { ! grep -qF -- "$1" "$LOG"; }
nd() { echo "$HOME/.config/niri"; }
nbak() { ls "$1".bak-* 2>/dev/null | wc -l; }
generated() { ls "$(nd)"/40-binds-standard.kdl "$(nd)"/41-binds-*.kdl 2>/dev/null | wc -l; }

# ---- the duplicate-bind checker: parses the bind lines of the given files, normalizes Mod to Super, sorts the modifiers
cat >"$root/dups.py" <<'F'
import re, sys
seen = {}
dups = []
for path in sys.argv[1:]:
    inbinds = False
    for line in open(path):
        s = line.strip()
        if not s or s.startswith("//"):
            continue
        if s.startswith("binds"):
            inbinds = True
            continue
        if s == "}":
            inbinds = False
            continue
        if not inbinds:
            continue
        tok = re.split(r"[\s{]", s, maxsplit=1)[0]
        parts = [p.lower() for p in tok.split("+")]
        key = parts[-1]
        mods = tuple(sorted("super" if m == "mod" else m for m in parts[:-1]))
        ident = (mods, key)
        if ident in seen:
            dups.append("%s: %s (also in %s)" % (path.split("/")[-1], tok, seen[ident]))
        else:
            seen[ident] = path.split("/")[-1]
if dups:
    print("\n".join(dups))
    sys.exit(1)
F
# ---- templates
check "three templates exist" bash -c "[ -f '$kbdir/standard.kdl.in' ] && [ -f '$kbdir/compact.kdl.in' ] && [ -f '$kbdir/hhkb.kdl.in' ]"
check "templates use only the placeholders SWITCH, MOVE, OTHER (the DEFAULT_AUDIO ones are wpctl arguments)" bash -c "! grep -ohE '@[A-Z_]+@' '$kbdir'/*.kdl.in | grep -vE '^@(SWITCH|MOVE|OTHER|DEFAULT_AUDIO_SINK|DEFAULT_AUDIO_SOURCE)@\$' | grep -q ."
check "templates hard-code no MEH, HYPR or personal launcher, folder or app" bash -c "! grep -hvE '^\s*//' '$kbdir'/*.kdl.in | grep -qEi 'Ctrl\\+Alt\\+Shift|Ctrl\\+Shift\\+Alt|ghostty|yazi|helix|fuzzel|swaylock|/home/|Documents|Downloads|Projects|firefox|zellij'"
check "compact and HHKB use only the switch and move placeholders" bash -c "! grep -qF '@OTHER@' '$kbdir/compact.kdl.in' '$kbdir/hhkb.kdl.in'"
check "standard template terminal is alacritty" grep -q 'spawn "alacritty"' "$kbdir/standard.kdl.in"
check "no ghostty or ptyxis in the shipped keybind files" bash -c "! grep -qiE 'ghostty|ptyxis' '$kbdir'/*"

# ---- NO path: the shipped 40-binds.kdl is niri's upstream default, with documented deviations only
up=/usr/share/doc/niri/default-config.kdl
if [ -f "$up" ]; then
    cat >"$root/updiff.py" <<'F'
import re, sys
def binds(path):
    out, inb = {}, False
    for line in open(path):
        s = re.sub(r"\s+", " ", line.strip())
        if not s or s.startswith("//"):
            continue
        if s.startswith("binds {"):
            inb = True
            continue
        if inb and s == "}":
            inb = False
            continue
        if inb:
            out[re.split(r"[\s{]", s, maxsplit=1)[0]] = s
    return out
up, ours = binds(sys.argv[1]), binds(sys.argv[2])
removed = {"Mod+D", "Super+Alt+L"}  # launcher (fuzzel) and screen locker (swaylock): the image ships neither
guarded = {"XF86AudioPlay", "XF86AudioStop", "XF86AudioPrev", "XF86AudioNext", "XF86MonBrightnessUp", "XF86MonBrightnessDown"}
errs = []
for k in up:
    if k not in ours:
        if k not in removed:
            errs.append("missing from ours: " + k)
    elif up[k] != ours[k] and k not in guarded:
        errs.append("differs: " + k)
for k in ours:
    if k not in up:
        errs.append("only in ours: " + k)
for k in removed:
    if k in ours:
        errs.append("should be removed: " + k)
for k in guarded:
    if "command -v" not in ours.get(k, ""):
        errs.append("not guarded: " + k)
print("\n".join(errs))
sys.exit(1 if errs else 0)
F
    python3 -I "$root/updiff.py" "$up" "$etc_niri/40-binds.kdl" >"$root/out" 2>&1
    rc=$?
    check "NO path: 40-binds.kdl equals niri's upstream default binds except the documented deviations (fuzzel and swaylock removed, six keys guarded with command -v)" test "$rc" = 0
else
    echo "skip upstream default comparison ($up is not installed here)"
fi

# ---- --yes alone and the NO answers keep niri's defaults
reset
run '' --yes
check "--yes alone: wizard not started, exit 0, no generated files" bash -c "[ $rc = 0 ] && [ \$(ls '$HOME'/.config/niri/4[01]-binds-* 2>/dev/null | wc -l) = 0 ] && grep -qF 'include \"40-binds.kdl\"' '$HOME/.config/niri/config.kdl' && grep -qE '^keybinds +skipped \(wizard not started\)' '$root/out'"
reset
run '' --yes --no-wizard
check "--no-wizard: same, exit 0" bash -c "[ $rc = 0 ] && [ \$(ls '$HOME'/.config/niri/4[01]-binds-* 2>/dev/null | wc -l) = 0 ] && grep -qE '^keybinds +skipped' '$root/out'"
run '' --no-wizard --keybinds compact
check "--no-wizard with a wizard option: exit 2" test "$rc" = 2
reset
run 'n\n' --only keybinds
check "opening question answered n: nothing written, defaults stay" bash -c "[ $rc = 0 ] && [ ! -e '$HOME/.config/niri' ] && grep -qE '^keybinds +skipped \(wizard not started\)' '$root/out'"
reset
run '\n' --only keybinds
check "opening question answered with Enter: default is NO" bash -c "[ $rc = 0 ] && [ ! -e '$HOME/.config/niri' ]"
reset
run '' --no --keybinds hhkb --only keybinds
check "--no with options: plan only, nothing written" bash -c "[ $rc = 0 ] && [ ! -e '$HOME/.config' ] && grep -qE '^keybinds +planned' '$root/out'"

# ---- EXPERIMENTAL label everywhere the user sees the wizard
reset
run '' --help
check "--help says experimental" bash -c "grep -qi 'experimental' '$root/out' && grep -qF 'restores the previous files on failure' '$root/out' && grep -qF 'niri validate' '$root/out'"
run '' help
check "help says experimental too" has "EXPERIMENTAL keybind wizard"
reset
run 'n\n' --only keybinds
check "the opening question reads 'Start the keybind wizard (experimental)?'" has "Start the keybind wizard (experimental)?"
check "an experimental notice is printed before the first question" bash -c "grep -n -i 'Notice: the keybind wizard is experimental' '$root/out' | head -1 | cut -d: -f1 | { read n; q=\$(grep -n 'Start the keybind wizard' '$root/out' | tail -1 | cut -d: -f1); [ \"\$n\" -lt \"\$q\" ]; }"
reset
export OCTARINE_MENU_FORCE_TTY=1
gumq 1 'Keybind wizard (experimental)\n'
run 'n\n'
check "checklist: the entry reads 'Keybind wizard (experimental)' and is not preselected" bash -c "grep -qF 'Keybind wizard (experimental)' '$LOG' && grep -qF -- '--selected Niri config files in ~/.config/niri,Portal config with the oo7 secret portal,Noctalia polkit agent drop-in Niri' '$LOG'"
check "checklist: the entry is one readable line, no divider rows" bash -c "! grep -q '──' '$LOG'"
check "checklist: choosing it asks the experimental question and --yes-less run keeps the defaults when answered n" bash -c "grep -qF 'Start the keybind wizard (experimental)?' '$root/out' && [ \$(ls '$HOME'/.config/niri/4[01]-binds-* 2>/dev/null | wc -l) = 0 ]"
unset OCTARINE_MENU_FORCE_TTY

# ---- non-interactive: flags, defaults, errors
reset
run '' --yes --only niri
run '' --yes --only keybinds --keybinds standard
check "standard with all defaults: exit 0, one generated file, include replaced" bash -c "[ $rc = 0 ] && [ -f '$(nd)/40-binds-standard.kdl' ] && [ ! -e '$(nd)/41-binds-compact.kdl' ] && [ ! -e '$(nd)/41-binds-hhkb.kdl' ] && grep -qx 'include \"40-binds-standard.kdl\"' '$(nd)/config.kdl' && ! grep -qx 'include \"40-binds.kdl\"' '$(nd)/config.kdl'"
check "defaults: switching Ctrl+Alt, moving Ctrl+Super, other actions Mod" bash -c "grep -q '^    Ctrl+Alt+Left ' '$(nd)/40-binds-standard.kdl' && grep -q '^    Ctrl+Super+Left ' '$(nd)/40-binds-standard.kdl' && grep -q '^    Mod+T ' '$(nd)/40-binds-standard.kdl'"
check "no placeholder is left in the generated file" bash -c "! grep -E '@(SWITCH|MOVE|OTHER)@' '$(nd)/40-binds-standard.kdl'"
check "config.kdl keeps the order: generated binds before 50-noctalia.kdl" bash -c "a=\$(grep -n '40-binds-standard' '$(nd)/config.kdl' | cut -d: -f1); b=\$(grep -n '50-noctalia' '$(nd)/config.kdl' | cut -d: -f1); [ \"\$a\" -lt \"\$b\" ]"
check "config.kdl: a timestamped backup of the old file" bash -c "[ \$(ls '$(nd)'/config.kdl.bak-* | wc -l) = 1 ] && grep -qx 'include \"40-binds.kdl\"' \$(ls '$(nd)'/config.kdl.bak-*)"
check "output prints what was written, the undo and that niri reloads live" bash -c "grep -q 'wrote' '$root/out' && grep -q 'keybinds: put include \"40-binds.kdl\" back' '$root/out' && grep -q 'niri reloads the generated key bindings live' '$root/out'"
check "niri is not on the test PATH: validation reported as skipped" has "niri is not installed here: validation was skipped"
check "an experimental notice is printed in the non-interactive run too" has "the keybind wizard is experimental"
for lay in compact hhkb; do
    reset
    run '' --yes --keybinds "$lay"
    check "$lay with defaults: exit 0, standard plus 41-binds-$lay.kdl, both included" bash -c "[ $rc = 0 ] && [ -f '$(nd)/40-binds-standard.kdl' ] && [ -f '$(nd)/41-binds-$lay.kdl' ] && grep -qx 'include \"41-binds-$lay.kdl\"' '$(nd)/config.kdl'"
    check "$lay: defaults do not depend on the layout (Ctrl+Alt switch, Ctrl+Super move)" bash -c "grep -q '^    Ctrl+Alt+' '$(nd)/41-binds-$lay.kdl' && grep -q '^    Ctrl+Super+' '$(nd)/41-binds-$lay.kdl' && ! grep -qE 'Ctrl\\+Alt\\+Shift' '$(nd)/41-binds-$lay.kdl'"
done
reset
run '' --yes --keybinds standard --switch-mod meh --move-mod hypr --other-mod ctrl-super
check "MEH, HYPR and Ctrl+Super render as Ctrl+Alt+Shift, Ctrl+Alt+Shift+Super and Ctrl+Super" bash -c "grep -q '^    Ctrl+Alt+Shift+Left ' '$(nd)/40-binds-standard.kdl' && grep -q '^    Ctrl+Alt+Shift+Super+Left ' '$(nd)/40-binds-standard.kdl' && grep -q '^    Ctrl+Super+T ' '$(nd)/40-binds-standard.kdl'"
reset
run '' --yes --keybinds standard --move-mod ctrl-alt
check "only --move-mod ctrl-alt: switching moves to the next free one (ctrl-super)" bash -c "[ $rc = 0 ] && grep -q '^    Ctrl+Super+Left *{ focus-column-left' '$(nd)/40-binds-standard.kdl' && grep -q '^    Ctrl+Alt+Left *{ move-column-left' '$(nd)/40-binds-standard.kdl'"
for bad in "--keybinds nonsense" "--switch-mod nonsense" "--move-mod super" "--switch-mod super" "--other-mod nonsense" "--switch-mod ctrl-alt --move-mod ctrl-alt" "--switch-mod meh --move-mod meh" "--keybinds"; do
    reset
    # shellcheck disable=SC2086
    run '' --yes $bad
    check "bad option '$bad': exit 2, nothing written" bash -c "[ $rc = 2 ] && [ ! -e '$HOME/.config' ]"
done
reset
run '' --yes --switch-mod hypr --move-mod hypr
check "same modifier for switching and moving: clear message" bash -c "grep -q 'cannot be used for switching and for moving' '$root/out'"
run '' --yes --keybinds=hhkb --switch-mod=ctrl-super --move-mod=meh --other-mod=hypr --only niri
check "the --name=value form is accepted" test "$rc" = 0

# ---- interactive (plain prompts, no terminal): refusal and re-ask, defaults, MEH and HYPR never the default
reset
run '' --yes --only niri
# y; layout Enter (standard); switch 1 (ctrl-alt); move 1 (same: refused) then 2 (ctrl-super); other Enter (super)
run 'y\n\n1\n1\n2\n\n' --only keybinds
check "same modifier for moving as for switching is refused with a message and asked again" bash -c "[ $rc = 0 ] && [ \$(grep -c 'Modifier for MOVING' '$root/out') = 2 ] && grep -q 'The same modifier cannot be used for switching and for moving' '$root/out'"
check "after the refusal the second answer is used (Ctrl+Super moves)" bash -c "grep -q '^    Ctrl+Super+Left *{ move-column-left' '$(nd)/40-binds-standard.kdl'"
reset
run '' --yes --only niri
run 'y\n\n\n\n\n' --only keybinds
check "Enter at every question: standard, Ctrl+Alt, Ctrl+Super, Mod (never MEH or HYPR)" bash -c "[ $rc = 0 ] && grep -q '^    Ctrl+Alt+Left *{ focus-column-left' '$(nd)/40-binds-standard.kdl' && grep -q '^    Ctrl+Super+Left *{ move-column-left' '$(nd)/40-binds-standard.kdl' && grep -q '^    Mod+T ' '$(nd)/40-binds-standard.kdl' && [ ! -e '$(nd)/41-binds-hhkb.kdl' ]"
reset
run '' --yes --only niri
# switch ctrl-super (2): the default for moving becomes ctrl-alt; EOF afterwards takes the defaults
run 'y\n3\n2\n' --only keybinds
check "switching Ctrl+Super: the move default moves to Ctrl+Alt (HHKB picked as layout 3), EOF takes defaults" bash -c "[ $rc = 0 ] && [ -f '$(nd)/41-binds-hhkb.kdl' ] && grep -q '^    Ctrl+Super+Semicolon *{ focus-column-left' '$(nd)/41-binds-hhkb.kdl' && grep -q '^    Ctrl+Alt+Semicolon *{ move-column-left' '$(nd)/41-binds-hhkb.kdl'"
reset
run '' --yes --only niri
run 'y\n2\n\n\n\n' --only keybinds
check "layout 2 is Compact (adds hjkl on top of Standard)" bash -c "[ -f '$(nd)/41-binds-compact.kdl' ] && [ -f '$(nd)/40-binds-standard.kdl' ] && grep -q 'Ctrl+Alt+H *{ focus-column-left' '$(nd)/41-binds-compact.kdl'"
check "the prompts list the three layouts, Standard named with its keys" bash -c "grep -qF 'Standard keyboard (arrows, PageUp, PageDown, Home, End)' '$root/out' && grep -qF 'Compact keyboard (adds vim-style hjkl)' '$root/out' && grep -qF 'HHKB layout' '$root/out'"
check "plain prompts: MEH and HYPR carry the QMK note and no (default) marker; Super is offered for other actions only" bash -c "
  [ \$(grep -c 'MEH (Ctrl+Alt+Shift): needs these keys mapped in your keyboard firmware (a custom QMK mapping); most keyboards do not have them' '$root/out') = 3 ] &&
  [ \$(grep -c 'HYPR (Ctrl+Alt+Shift+Super): needs these keys mapped in your keyboard firmware (a custom QMK mapping); most keyboards do not have them' '$root/out') = 3 ] &&
  ! grep -E 'MEH|HYPR' '$root/out' | grep -q '(default)' &&
  [ \$(grep -c '[0-9]) Super\$' '$root/out') = 0 ] && [ \$(grep -c '[0-9]) Super (default)\$' '$root/out') = 1 ]"
# a menu (ugum on a faked terminal)
reset
run '' --yes --only niri
export OCTARINE_MENU_FORCE_TTY=1
ugumq 1 1
ugumq 2 3
ugumq 3 4
ugumq 4 5
run 'y\n' --only keybinds
check "menus: Standard, then MEH for switching, HYPR for moving, HYPR... the answers are applied by index" bash -c "[ $rc = 0 ] && grep -q '^    Ctrl+Alt+Shift+Left *{ focus-column-left' '$(nd)/40-binds-standard.kdl' && grep -q '^    Ctrl+Alt+Shift+Super+Left *{ move-column-left' '$(nd)/40-binds-standard.kdl' && grep -q '^    Ctrl+Alt+Shift+Super+T ' '$(nd)/40-binds-standard.kdl'"
check "menus: four questions, one ugum choose each" bash -c "[ \$(grep -c '^ugum choose' '$LOG') = 4 ]"
check "menus: every MEH and HYPR item carries the QMK note, none is marked (default)" bash -c "[ \$(grep -c '^item: MEH .*a custom QMK mapping); most keyboards do not have them' '$LOG') = 3 ] && [ \$(grep -c '^item: HYPR .*a custom QMK mapping); most keyboards do not have them' '$LOG') = 3 ] && ! grep -E '^item: (MEH|HYPR)' '$LOG' | grep -q '(default)'"
check "menus: the marked defaults are Ctrl+Alt (switch), Ctrl+Super (move), Super (other)" bash -c "grep -q '^item: Ctrl+Alt (default)' '$LOG' && grep -q '^item: Ctrl+Super (default)' '$LOG' && grep -q '^item: Super (default)' '$LOG'"
reset
run '' --yes --only niri
ugumq 1 1
ugumq 2 1
ugumq 3 1
ugumq 4 2
ugumq 5 1
export OCTARINE_MENU_FORCE_TTY=1
run 'y\n' --only keybinds
unset OCTARINE_MENU_FORCE_TTY
check "menu: the refused same modifier asks again (5 menus), and the layout menu keeps working" bash -c "[ \$(grep -c '^ugum choose' '$LOG') = 5 ] && grep -q 'cannot be used for switching and for moving' '$root/out' && grep -q '^    Ctrl+Super+Left *{ move-column-left' '$(nd)/40-binds-standard.kdl'"
reset
run '' --yes --only niri
ugumq 1 ""
export OCTARINE_MENU_FORCE_TTY=1
run 'y\n' --only keybinds
unset OCTARINE_MENU_FORCE_TTY
check "menu: Esc on the first question cancels, nothing changes, exit 0" bash -c "[ $rc = 0 ] && grep -q 'Wizard cancelled; nothing changed' '$root/out' && [ \$(ls '$(nd)'/4[01]-binds-* 2>/dev/null | wc -l) = 0 ] && grep -qx 'include \"40-binds.kdl\"' '$(nd)/config.kdl'"
unset OCTARINE_MENU_FORCE_TTY

# ---- recipe flow: existing files, backups, validation
reset
run '' --yes --only keybinds --keybinds standard
check "no config.kdl yet: step skipped with the hint to run the niri step, exit 0, nothing written" bash -c "[ $rc = 0 ] && grep -q 'run ujust niri-setup --only niri first' '$root/out' && [ ! -e '$HOME/.config/niri' ]"
reset
run '' --yes --only niri
run '' --yes --only keybinds --keybinds standard
cp -p "$(nd)/config.kdl" "$root/config.after1"
: >"$LOG"
run '' --yes --only keybinds --keybinds standard
check "second identical run: already done, no new backup, files unchanged" bash -c "[ $rc = 0 ] && grep -qE '^keybinds +already done' '$root/out' && [ \$(ls '$(nd)'/*.bak-* | wc -l) = 1 ] && cmp '$root/config.after1' '$(nd)/config.kdl'"
# different settings: diff, default keep
run '' --yes --only keybinds --keybinds standard --other-mod ctrl-alt --switch-mod meh
check "different settings under --yes: the existing generated file is kept (default keep), diff shown, config.kdl untouched" bash -c "[ $rc = 0 ] && grep -q 'exists and differs' '$root/out' && grep -q '^    Ctrl+Alt+Left ' '$(nd)/40-binds-standard.kdl' && grep -qE '^keybinds +skipped \(kept' '$root/out' && cmp '$root/config.after1' '$(nd)/config.kdl'"
run 'y\n' --only keybinds --keybinds standard --other-mod ctrl-alt --switch-mod meh
check "answer y to the replace question: file replaced, backup with the old content" bash -c "[ $rc = 0 ] && grep -q '^    Ctrl+Alt+Shift+Left ' '$(nd)/40-binds-standard.kdl' && [ \$(ls '$(nd)'/40-binds-standard.kdl.bak-* | wc -l) = 1 ] && grep -q '^    Ctrl+Alt+Left ' \$(ls '$(nd)'/40-binds-standard.kdl.bak-*)"
# switching layout leaves the old extra file alone and out of config.kdl
run '' --yes --only keybinds --keybinds hhkb
run 'y\n' --only keybinds --keybinds compact
check "layout change: config.kdl lists standard and the new extra file only; nothing is deleted" bash -c "grep -qx 'include \"41-binds-compact.kdl\"' '$(nd)/config.kdl' && ! grep -q '41-binds-hhkb' '$(nd)/config.kdl' && [ -f '$(nd)/41-binds-hhkb.kdl' ] && [ \$(grep -c '^include \"4[01]-binds' '$(nd)/config.kdl') = 2 ]"
# a config.kdl without the standard include list: diff and ask, default keep
reset
run '' --yes --only niri
printf 'include "10-environment.kdl"\n// my own binds below\n' >"$(nd)/config.kdl"
run '' --yes --only keybinds --keybinds standard
check "unusual config.kdl under --yes: kept, the lines to add are printed, the generated parts are written" bash -c "[ $rc = 0 ] && ! grep -q '40-binds-standard' '$(nd)/config.kdl' && grep -q 'add these lines' '$root/out' && grep -q 'include \"40-binds-standard.kdl\"' '$root/out' && [ -f '$(nd)/40-binds-standard.kdl' ]"
run 'y\n' --only keybinds --keybinds standard
check "unusual config.kdl, answer y: the include is added (appended, no 50-noctalia line), backup made" bash -c "grep -qx 'include \"40-binds-standard.kdl\"' '$(nd)/config.kdl' && [ \$(ls '$(nd)'/config.kdl.bak-* | wc -l) = 1 ]"
# failed validation restores
reset
run '' --yes --only niri
cp -p "$(nd)/config.kdl" "$root/config.before"
PATH_BIN="$root/failbin:$bin"
run '' --yes --only keybinds --keybinds hhkb
check "failed niri validate: exit 1, the error shown, config.kdl restored, new files removed, FAILED with the re-run command" bash -c "[ $rc = 1 ] && grep -q 'fake parse error' '$root/out' && grep -q 'previous files were restored' '$root/out' && cmp '$root/config.before' '$(nd)/config.kdl' && [ \$(ls '$(nd)'/4[01]-binds-* 2>/dev/null | grep -v '40-binds.kdl' | wc -l) = 0 ] && [ \$(ls '$(nd)'/*.bak-* 2>/dev/null | wc -l) = 0 ] && grep -qE '^keybinds +FAILED' '$root/out' && grep -q 'ujust niri-setup --only keybinds' '$root/out'"
# failed validation with an earlier wizard result in place: the earlier files come back
PATH_BIN="$bin"
run '' --yes --only keybinds --keybinds standard
cp -p "$(nd)/40-binds-standard.kdl" "$root/std.before"
cp -p "$(nd)/config.kdl" "$root/config.before2"
PATH_BIN="$root/failbin:$bin"
run 'y\n' --only keybinds --keybinds compact --switch-mod meh --move-mod hypr
check "failed validation on a re-run: every file is back to the previous content" bash -c "[ $rc = 1 ] && cmp '$root/std.before' '$(nd)/40-binds-standard.kdl' && cmp '$root/config.before2' '$(nd)/config.kdl' && [ ! -e '$(nd)/41-binds-compact.kdl' ]"
PATH_BIN="$bin"
check "no sudo anywhere" notlogged "sudo"

# ---- the matrix, with the real niri: every layout, every switch and move pair (different), every modifier for other actions
if [ "$have_niri" = 1 ]; then
    PATH_BIN="$realbin:$bin"
    mods=(ctrl-alt ctrl-super meh hypr)
    others=(ctrl-alt ctrl-super meh hypr super)
    total=0
    okc=0
    badlist=""
    for lay in standard compact hhkb; do
        for sw in "${mods[@]}"; do
            for mv in "${mods[@]}"; do
                [ "$sw" = "$mv" ] && continue
                for ot in "${others[@]}"; do
                    total=$((total + 1))
                    rm -rf "$HOME"
                    mkdir -p "$HOME"
                    mkreal
                    pass_one=1
                    printf '' | PATH="$PATH_BIN:$sysbin" OCTARINE_NIRI_SETUP_SRC="$src" "$REAL_JUST" --justfile "$justfile" --working-directory "$root" niri-setup --yes --only niri,keybinds --keybinds "$lay" --switch-mod "$sw" --move-mod "$mv" --other-mod "$ot" >"$root/mout" 2>&1 || pass_one=0
                    files=("$HOME/.config/niri/40-binds-standard.kdl")
                    [ "$lay" = standard ] || files+=("$HOME/.config/niri/41-binds-$lay.kdl")
                    for f in "${files[@]}"; do [ -f "$f" ] || pass_one=0; done
                    if [ "$pass_one" = 1 ]; then
                        niri validate -c "$HOME/.config/niri/config.kdl" >"$root/vout" 2>&1 || pass_one=0
                        python3 -I "$root/dups.py" "${files[@]}" >"$root/dout" 2>&1 || pass_one=0
                        # the generated binds plus Noctalia's: only the XF86 keys may repeat (Noctalia replaces them on purpose)
                        python3 -I "$root/dups.py" "${files[@]}" "$HOME/.config/niri/50-noctalia.kdl" 2>&1 | grep -v 'XF86' | grep -q '(also in' && pass_one=0
                    fi
                    if [ "$pass_one" = 1 ]; then okc=$((okc + 1)); else badlist="$badlist $lay/$sw/$mv/$ot"; fi
                done
            done
        done
    done
    echo "matrix: $okc of $total combinations passed"
    [ -n "$badlist" ] && echo "failed:$badlist" | head -c 600 >"$root/out"
    check "matrix: $total combinations (3 layouts x 12 ordered switch/move pairs x 5 other-action modifiers): every one renders, passes niri validate and has no duplicate key combination" test "$okc" = "$total"
    check "matrix size is 180" test "$total" = 180
    # a duplicate really is detected by the checker (the test itself is sound)
    printf 'binds {\n    Mod+T { quit; }\n    Super+T { quit; }\n}\n' >"$root/dupfile.kdl"
    check "the duplicate checker catches Mod+T versus Super+T" bash -c "! python3 -I '$root/dups.py' '$root/dupfile.kdl' >/dev/null"
    # a complete real run through the recipe against the shipped tree
    rm -rf "$HOME"
    mkdir -p "$HOME"
    mkreal
    printf '' | PATH="$PATH_BIN:$sysbin" OCTARINE_NIRI_SETUP_SRC="$src" "$REAL_JUST" --justfile "$justfile" --working-directory "$root" niri-setup --yes --only niri,keybinds --keybinds hhkb >"$root/out" 2>&1
    rc=$?
    check "with the real niri: the recipe validates the result itself and says so" bash -c "[ $rc = 0 ] && grep -q 'niri validate: .* is valid' '$root/out'"
    # the generated parts leave the Noctalia binds on Mod; its keys never overlap the generated Mod keys
    check "Noctalia's launcher keys (Mod+Space, Mod+D, Mod+S, Mod+Shift+S) are not bound by the generated parts" bash -c "! grep -E '^    (Mod|Super)\\+(Space|D|S|Shift\\+S) ' '$kbdir'/*.kdl.in"
else
    echo "skip matrix (niri is not installed here)"
fi

echo "passed: $pass, failed: $failn"
[ "$failn" = 0 ]
