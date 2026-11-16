#!/usr/bin/env bash
# Tests for `ujust user-setup` (system_files/usr/share/ublue-os/just/60-custom.just).
# flatpak, sudo, id, getent and usermod are fakes on PATH; nothing real is changed. Needs: bash, just.
# Run: tests/user-setup.sh
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
justfile="$here/../system_files/usr/share/ublue-os/just/60-custom.just"
root=$(mktemp -d)
trap 'rm -rf -- "$root"' EXIT
pass=0
failn=0
bin="$root/bin"
mkdir -p "$bin"
export LOG="$root/log" INSTALLED="$root/installed" OVR="$root/ovr" GROUPS_OF="$root/groups" FAILAPP="$root/failapp"
export HOME="$root/home"
mkdir -p "$HOME"
export BREW_CASKS="$root/casks" FC_FAMILIES="$root/families"
export USER_SETUP_FONTS_BREWFILE="$here/../system_files/usr/share/octarine-os/homebrew/fonts.Brewfile"
export GUMQ="$root/gumq" UGUMQ="$root/ugumq" OCTARINE_MENU_LIB="$here/../system_files/usr/share/octarine-os/lib/menu.sh"
export GS="$root/gs" SHELLF="$root/shell" CALLS="$root/calls"
export USER_SETUP_FISH="$root/fakefish" USER_SETUP_ZSH="$root/fakezsh" USER_SETUP_SHELLS="$root/shells" USER_SETUP_SKEL="$root/skel"
export USER_SETUP_SEARCH_DIRS="$root/sp1:$root/sp2" XDG_CACHE_HOME="$root/cache"
mkdir -p "$root/skel" "$root/sp1" "$root/sp2"
printf '#!/bin/sh\n' >"$USER_SETUP_FISH"; chmod +x "$USER_SETUP_FISH"
printf '#!/bin/sh\n' >"$USER_SETUP_ZSH"; chmod +x "$USER_SETUP_ZSH"
echo skelrc >"$root/skel/.zshrc"
REAL_JUST=$(command -v just)
# a PATH with only the basics, so the real ptyxis, brew, starship, git and gsettings are never seen
sysbin="$root/sysbin"
mkdir -p "$sysbin"
for c in chmod wc bash sh env cat grep awk tr cut sed mkdir cp mv rm realpath dirname head tail sort uniq date touch ls readlink mktemp tee cmp basename wc; do
    p=$(command -v "$c") && ln -sf "$p" "$sysbin/$c"
done

cat >"$bin/flatpak" <<'F'
#!/usr/bin/env bash
echo "flatpak $*" >>"$LOG"
case "$1" in
    info) grep -qx -- "$2" "$INSTALLED" ;;
    override)
        if [ "$2 $3" = "--user --show" ]; then
            app=$4
            [ -f "$OVR.$app" ] && cat "$OVR.$app"
            exit 0
        fi
        app=${!#}
        if [ -f "$FAILAPP" ] && grep -qx -- "$app" "$FAILAPP"; then exit 1; fi
        for a in "${@:3:$#-3}"; do
            case "$a" in
                --device=*) echo "devices=${a#--device=};" >>"$OVR.$app" ;;
                --socket=*) echo "sockets=${a#--socket=};" >>"$OVR.$app" ;;
                --nofilesystem=*) echo "filesystems=!${a#--nofilesystem=};" >>"$OVR.$app" ;;
                --filesystem=*) echo "filesystems=${a#--filesystem=};" >>"$OVR.$app" ;;
            esac
        done
        ;;
esac
F
cat >"$bin/sudo" <<'F'
#!/usr/bin/env bash
echo "sudo $*" >>"$LOG"
[ "$1" = sh ] && exit 0
exec "$@"
F
cat >"$bin/usermod" <<'F'
#!/usr/bin/env bash
echo "usermod $*" >>"$LOG"
if [ "$1" = -s ]; then echo "$2" >"$SHELLF"; exit 0; fi
echo "$2" >>"$GROUPS_OF"
F
cat >"$bin/getent" <<'F'
#!/usr/bin/env bash
if [ "$1" = passwd ]; then echo "$2:x:1000:1000::/home/$2:$(cat "$SHELLF")"; exit 0; fi
[ "$2" = libvirt ] && [ -n "${NO_LIBVIRT_GROUP:-}" ] && exit 2
case "$2" in gamemode | input | libvirt) echo "$2:x:1:" ;; *) exit 2 ;; esac
F
cat >"$bin/id" <<'F'
#!/usr/bin/env bash
case "$1" in
    -un) echo tester ;;
    -nG) echo "tester wheel $(cat "$GROUPS_OF" 2>/dev/null | tr '\n' ' ')" ;;
    *) [ "$1" = tester ] ;;
esac
F
cat >"$bin/gsettings" <<'F'
#!/usr/bin/env bash
# state file: "schema[:path] key=value" lines
echo "gsettings $*" >>"$LOG"
case "$1" in
    get)
        v=$(grep -F -- "$2 $3=" "$GS" 2>/dev/null | tail -1 | sed "s/^[^=]*=//")
        if [ -z "$v" ]; then
            case "$3" in
                profile-uuids | enabled | disabled) v="@as []" ;;
                sort-order) v="['org.gnome.Settings.desktop', 'org.gnome.Contacts.desktop', 'org.gnome.Nautilus.desktop']" ;;
                default-profile-uuid | label | custom-command) v="''" ;;
                use-custom-command) v=false ;;
            esac
        fi
        echo "$v"
        ;;
    set)
        grep -vF -- "$2 $3=" "$GS" >"$GS.n" 2>/dev/null; mv "$GS.n" "$GS"
        v=$4
        case "$v" in \[* | @* | true | false) ;; *) v="'$v'" ;; esac
        echo "$2 $3=$v" >>"$GS"
        ;;
    list-keys) ;;
esac
F
for n in ptyxis; do printf '#!/bin/sh\necho "%s $*" >>"$LOG"\n' "$n" >"$bin/$n"; done
cat >"$bin/brew" <<'F'
#!/bin/sh
echo "brew $*" >>"$LOG"
case "$1" in
    install)
        if [ "$2" = --cask ]; then shift 2; for c in "$@"; do echo "$c" >>"$BREW_CASKS"; done
        else printf '#!/bin/sh\n' >"$bin_dir/starship"; chmod +x "$bin_dir/starship"; fi
        ;;
    list) grep -qx -- "$3" "$BREW_CASKS"; exit $? ;;
    bundle) grep -o 'font-[a-z0-9-]*' "$3" >>"$BREW_CASKS" ;;
    search) printf '%s\n' font-aaa-nerd-font font-bbb-nerd-font font-notnerd ;;
esac
exit 0
F
export bin_dir="$bin"
cat >"$bin/uuidgen" <<'F'
#!/usr/bin/env bash
n=$(( $(cat "$root_cnt" 2>/dev/null || echo 0) + 1 )); echo $n >"$root_cnt"
printf 'AAAAAAAA-0000-0000-0000-%012d\n' "$n"
F
export root_cnt="$root/uuidcnt"
cat >"$bin/fc-list" <<'F'
#!/bin/sh
cat "$FC_FAMILIES" 2>/dev/null
F
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
n=$(( $(cat "$UGUMQ.n" 2>/dev/null || echo 0) + 1 )); echo "$n" >"$UGUMQ.n"
[ -f "$UGUMQ.$n" ] && cat "$UGUMQ.$n"
exit 0
F
chmod +x "$bin"/*

reset() {
    rm -f "$root"/gumq.* "$root"/ugumq.*; unset OCTARINE_MENU_FORCE_TTY GUM_CONFIRM_RC
    rm -f "$bin/starship" "$LOG" "$GROUPS_OF" "$FAILAPP" "$OVR".* "$root_cnt"
    rm -rf "$HOME" "$XDG_CACHE_HOME" "$root"/sp1/* "$root"/sp2/*
    mkdir -p "$HOME"
    : >"$LOG"; : >"$INSTALLED"; : >"$GS"
    echo /bin/bash >"$SHELLF"
    echo "$USER_SETUP_ZSH" >"$USER_SETUP_SHELLS"
    : >"$BREW_CASKS"; : >"$FC_FAMILIES"
}
gumq() { printf '%b' "$2" >"$root/gumq.$1"; }
ugumq() { printf '%b' "$2" >"$root/ugumq.$1"; }
run() { # stdin text, args...
    local input=$1
    shift
    printf '%b' "$input" | PATH="$bin:$sysbin" "$REAL_JUST" --justfile "$justfile" --working-directory "$root" user-setup "$@" >"$root/out" 2>&1
    rc=$?
}
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { failn=$((failn + 1)); echo "FAIL $1"; sed 's/^/     /' "$root/out"; }
check() { local d=$1; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
has() { grep -qF -- "$1" "$root/out"; }
logged() { grep -qF -- "$1" "$LOG"; }
notlogged() { ! grep -qF -- "$1" "$LOG"; }
all_apps='com.valvesoftware.Steam\ncom.usebottles.bottles\nnet.lutris.Lutris\ncom.visualstudio.code\nio.podman_desktop.PodmanDesktop\ncom.google.Chrome\nit.mijorus.gearlever'

# 1. nothing installed, --yes: groups applied, all Flatpak steps skipped
reset
run '' --yes
check "nothing installed: exit 0" test "$rc" = 0
check "nothing installed: groups added" logged "usermod -aG libvirt tester"

# 2. everything installed, --yes: defaults (steam devices and games path skipped)
reset
printf '%b\n' "$all_apps" >"$INSTALLED"
run '' --yes
check "yes: exit 0" test "$rc" = 0

# 3. idempotent second run
: >"$LOG"
run '' --yes
check "second run: exit 0" test "$rc" = 0
check "second run: no usermod" notlogged "usermod"

# 4. --no changes nothing
reset
printf '%b\n' "$all_apps" >"$INSTALLED"
run '' --no
check "no: exit 0" test "$rc" = 0
check "no: nothing changed" notlogged "usermod"
check "no: no override" notlogged "flatpak override --user --socket"

# 5. a failing step does not stop the rest, exit status non-zero
reset
printf '%b\n' "$all_apps" >"$INSTALLED"
echo com.visualstudio.code >"$FAILAPP"
run '' --yes
check "failure: exit non-zero" test "$rc" != 0
check "failure: later step still ran" logged "it.mijorus.gearlever"
reset
printf '%b\n' "$all_apps" >"$INSTALLED"
run '/\n\n\n\n\n\n' --only flatpak
check "games path: / refused" has "Refusing to expose"
check "shell: not in /etc/shells no change" notlogged "usermod -s"
reset
run '' --no
check "shell: --no changes nothing" notlogged "usermod -s"
p=org.gnome.Ptyxis.Profile:/org/gnome/Ptyxis/Profiles/bbbb/
check "only: flatpak did not run" notlogged "flatpak override"
reset
export OCTARINE_MENU_FORCE_TTY=1
run ''
check "gum checklist: Esc (empty) changes nothing" notlogged "usermod"
NO_LIBVIRT_GROUP=1 run ''
reset
export OCTARINE_MENU_FORCE_TTY=1 GUM_CONFIRM_RC=1
gumq 1 'Account: Login shell zsh (sudo)\n'
run ''
check "gum checklist: declining the confirmation changes nothing" notlogged "usermod"

# ---- editor step: fake editors in temp directories (PATH and the extra search directories), temp HOME
edir="$root/edbin"; extra="$root/edextra"; mkdir -p "$edir" "$extra"
export USER_SETUP_EDITOR_DIRS="$extra" USER_SETUP_EDITOR_SYSDIRS="$edir"
mked() { local d=$1; shift; for t in "$@"; do printf '#!/bin/sh\nexit 0\n' >"$d/$t"; chmod +x "$d/$t"; done; }
edrun() { local input=$1; shift; printf '%b' "$input" | PATH="$bin:$sysbin:$edir" "$REAL_JUST" --justfile "$justfile" --working-directory "$root" user-setup "$@" >"$root/out" 2>&1; rc=$?; }
edf() { echo "$HOME/.config/environment.d/50-editor.conf"; }
edreset() { reset; rm -f "$edir"/* "$extra"/*; unset EDITOR VISUAL SUDO_EDITOR; }
edreset; mked "$edir" nano vim; mked "$extra" hx
edrun '' --only editor --no
check "editor --no: prints the plan, writes nothing" bash -c "[ $rc = 0 ] && grep -q 'Plan: would ask which editor' '$root/out' && [ ! -e '$(edf)' ]"
edrun '' --only editor --yes
check "editor --yes alone: keeps the current settings, writes nothing" bash -c "[ $rc = 0 ] && grep -q 'Kept: --yes alone does not change the editor' '$root/out' && [ ! -e '$(edf)' ] && grep -q 'editor .*skipped (kept current)' '$root/out'"
EDITOR=/usr/bin/nano VISUAL= SUDO_EDITOR= edrun '\n' --only editor
snip="$here/../system_files/etc/profile.d/octarine-os-editor.sh"
unset USER_SETUP_EDITOR_DIRS USER_SETUP_EDITOR_SYSDIRS

echo "passed: $pass, failed: $failn"
[ "$failn" = 0 ]
