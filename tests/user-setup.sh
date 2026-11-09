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
cat >"$bin/git" <<'F'
#!/usr/bin/env bash
echo "git $*" >>"$LOG"
[ -n "${GIT_FAIL:-}" ] && exit 1
if [ "$1" = clone ]; then d=${@: -1}; mkdir -p "$d/.git" "$d/config/kitty" "$d/config/niri" "$d/config/noctalia"; echo "install:" >"$d/justfile"; fi
exit 0
F
cat >"$bin/just" <<'F'
#!/usr/bin/env bash
echo "just $*" >>"$LOG"
for a in "$@"; do
    if [ "$a" = --summary ]; then echo "${JUST_SUMMARY-install hint brew gnome-apply}"; fi
done
exit 0
F
chmod +x "$bin"/*

reset() {
    rm -f "$bin/starship" "$LOG" "$GROUPS_OF" "$FAILAPP" "$OVR".* "$root_cnt"
    rm -rf "$HOME" "$XDG_CACHE_HOME" "$root"/sp1/* "$root"/sp2/*
    mkdir -p "$HOME"
    : >"$LOG"; : >"$INSTALLED"; : >"$GS"
    echo /bin/bash >"$SHELLF"
    echo "$USER_SETUP_ZSH" >"$USER_SETUP_SHELLS"
    unset GIT_FAIL JUST_SUMMARY DOT_FILES_APPS
    : >"$BREW_CASKS"; : >"$FC_FAMILIES"
}
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
check "nothing installed: no override" notlogged "flatpak override"
check "nothing installed: steps skipped" has "skipped (not installed)"

# 2. everything installed, --yes: defaults (steam devices and games path skipped)
reset
printf '%b\n' "$all_apps" >"$INSTALLED"
run '' --yes
check "yes: exit 0" test "$rc" = 0
check "yes: vscode" logged "--socket=wayland --filesystem=xdg-run/podman com.visualstudio.code"
check "yes: podman desktop" logged "--nofilesystem=/run/docker.sock io.podman_desktop.PodmanDesktop"
check "yes: chrome" logged "com.google.Chrome"
check "yes: gearlever" logged "--filesystem=~/Applications it.mijorus.gearlever"
check "yes: steam devices not applied" notlogged "--device=usb"
check "yes: games path skipped" has "skipped (needs a path)"
check "yes: undo printed" has "flatpak override --user --nosocket=wayland"

# 3. idempotent second run
: >"$LOG"
run '' --yes
check "second run: exit 0" test "$rc" = 0
check "second run: no override" notlogged "flatpak override --user --socket"
check "second run: no override (fs)" notlogged "flatpak override --user --nofilesystem"
check "second run: no usermod" notlogged "usermod"
check "second run: already done" has "already done"

# 4. --no changes nothing
reset
printf '%b\n' "$all_apps" >"$INSTALLED"
run '' --no
check "no: exit 0" test "$rc" = 0
check "no: nothing changed" notlogged "usermod"
check "no: no override" notlogged "flatpak override --user --socket"
check "no: plan printed" has "planned (would ask)"

# 5. a failing step does not stop the rest, exit status non-zero
reset
printf '%b\n' "$all_apps" >"$INSTALLED"
echo com.visualstudio.code >"$FAILAPP"
run '' --yes
check "failure: exit non-zero" test "$rc" != 0
check "failure: reported" has "FAILED"
check "failure: later step still ran" logged "it.mijorus.gearlever"

# 6. interactive: Enter takes defaults, steam devices yes, games path given
reset
printf '%b\n' "$all_apps" >"$INSTALLED"
run "$root/games\ny\n\n\n\n\n" --only flatpak
check "interactive: exit 0" test "$rc" = 0
check "interactive: steam devices yes" logged "--device=usb"
check "interactive: games path applied" logged "--filesystem=$root/games net.lutris.Lutris"
reset
printf '%b\n' "$all_apps" >"$INSTALLED"
run '\n\n\n\n\n\n' --only flatpak
check "interactive: steam devices default no" notlogged "--device=usb"

# 7. unknown flag is an error, unsafe games path refused
reset
run '' --bogus
check "unknown flag: error" test "$rc" = 2
reset
printf '%b\n' "$all_apps" >"$INSTALLED"
run '/\n\n\n\n\n\n' --only flatpak
check "games path: / refused" has "Refusing to expose"

# ---- login shell
reset
run '' --yes
check "shell: switched with --yes" logged "usermod -s $USER_SETUP_ZSH tester"
check "shell: skeleton copied" test -f "$HOME/.zshrc"
check "shell: undo printed" has "usermod -s /bin/bash tester"
: >"$LOG"
run '' --yes
check "shell: second run no usermod -s" notlogged "usermod -s"
reset
echo "$USER_SETUP_ZSH" >"$SHELLF"
run '' --yes
check "shell: already zsh skipped" notlogged "usermod -s"
reset
echo /usr/bin/other >"$USER_SETUP_SHELLS"
run '' --yes
check "shell: not in /etc/shells skipped with reason" has "is not listed in"
check "shell: not in /etc/shells no change" notlogged "usermod -s"
reset
echo mine >"$HOME/.zshenv"
run '' --yes
check "shell: skeleton not copied when a zsh file exists" test ! -f "$HOME/.zshrc"
reset
run '' --no
check "shell: --no changes nothing" notlogged "usermod -s"
check "shell: --no copies nothing" test ! -f "$HOME/.zshrc"

# ---- fish profile and starship
reset
run '' --yes
check "fish: profile created" grep -q 'custom-command=.*fakefish' "$GS"
check "fish: default set" grep -q 'default-profile-uuid=.aaaaaaaa' "$GS"
check "fish: starship hook written" grep -q 'starship init fish' "$HOME/.config/fish/conf.d/starship.fish"
check "fish: brew install ran" logged "brew install starship"
n1=$(grep -c "Profiles" "$GS"); cp "$HOME/.config/fish/conf.d/starship.fish" "$root/hook1"
: >"$LOG"
run '' --yes
check "fish: second run no new uuid" test "$(grep -c "Profiles" "$GS")" = "$n1"
check "fish: second run no gsettings set" notlogged "gsettings set"
check "fish: second run hook untouched" cmp -s "$HOME/.config/fish/conf.d/starship.fish" "$root/hook1"
check "fish: profile list has no duplicate" test "$(grep 'profile-uuids=' "$GS" | grep -o "'[^']*'" | wc -l)" = 1
reset
p=org.gnome.Ptyxis.Profile:/org/gnome/Ptyxis/Profiles/bbbb/
printf "org.gnome.Ptyxis profile-uuids=['aaaa', 'bbbb']\n%s custom-command='%s'\n%s use-custom-command=true\norg.gnome.Ptyxis default-profile-uuid='aaaa'\n" "$p" "$USER_SETUP_FISH" "$p" >"$GS"
run '' --yes
check "fish: existing profile reused as default" grep -q "default-profile-uuid='bbbb'" "$GS"
check "fish: existing profile, list unchanged" grep -q "profile-uuids=\['aaaa', 'bbbb'\]" "$GS"
check "fish: previous default in undo" has "default-profile-uuid 'aaaa'"
reset
rm "$USER_SETUP_FISH"
run '' --yes
printf '#!/bin/sh\n' >"$USER_SETUP_FISH"; chmod +x "$USER_SETUP_FISH"
check "fish missing: whole item skipped" has "skipped (no fish)"
check "fish missing: no starship install" notlogged "brew install starship"
reset
rm "$bin/ptyxis"
run '' --yes
printf '#!/bin/sh\n' >"$bin/ptyxis"; chmod +x "$bin/ptyxis"
check "ptyxis missing: no profile" notlogged "Ptyxis.Profile"
check "ptyxis missing: starship still set up" test -f "$HOME/.config/fish/conf.d/starship.fish"
reset
mv "$bin/brew" "$root/brew.off"
run '' --yes
mv "$root/brew.off" "$bin/brew"
check "brew missing: starship skipped" has "skipped (no brew)"
check "brew missing: no hook file" test ! -f "$HOME/.config/fish/conf.d/starship.fish"
reset
mkdir -p "$HOME/.config/fish/conf.d"; echo "# mine" >"$HOME/.config/fish/conf.d/starship.fish"
run '' --yes
check "other starship.fish left alone" test "$(cat "$HOME/.config/fish/conf.d/starship.fish")" = "# mine"
check "other starship.fish reported" has "has other content"
reset
run '' --no
check "fish: --no changes nothing" notlogged "gsettings set"
check "fish: --no no hook" test ! -f "$HOME/.config/fish/conf.d/starship.fish"
check "fish: --no no brew" notlogged "brew install starship"

# ---- --only
reset
run '' --yes --only groups,shell
check "only: groups ran" logged "usermod -aG"
check "only: shell ran" logged "usermod -s"
check "only: flatpak did not run" notlogged "flatpak override"
check "only: brew did not run" notlogged "brew bundle"
reset
run '' --only nonsense
check "only: unknown step is an error" test "$rc" = 2
reset
run '' --with-dotfiles
check "old --with-dotfiles flag is gone" test "$rc" = 2

# ---- dot-files
reset
run '' --yes
check "dotfiles: not run by default" notlogged "git clone"
check "dotfiles: default no noted" has "skipped (default no; use --only dotfiles)"
reset
run '' --yes --only dotfiles
check "dotfiles: --only --yes consents, no app chosen, nothing installed" notlogged "install preserve"
check "dotfiles: --only --yes clones" logged "git clone"
check "dotfiles: no app noted" has "skipped (no app chosen)"
: >"$LOG"
DOT_FILES_APPS=niri,noctalia run '' --yes --only dotfiles
check "dotfiles: apps from DOT_FILES_APPS" logged "install preserve niri noctalia"
check "dotfiles: hint printed for the chosen apps" logged "hint niri noctalia"
check "dotfiles: second run reuses cache" notlogged "git clone"
check "dotfiles: second run fetches" logged "fetch"
reset
run 'y\nn\ny\ny\n' --only dotfiles
check "dotfiles: per-app answers build the argument list" logged "install preserve niri noctalia"
check "dotfiles: declined app absent" notlogged "install preserve kitty"
reset
run 'y\nn\nn\nn\n' --only dotfiles
check "dotfiles: all apps no copies nothing" notlogged "install preserve"
reset
run 'n\n' --only dotfiles
check "dotfiles: first question default/no stops" notlogged "git clone"
reset
JUST_SUMMARY="install" DOT_FILES_APPS=niri run '' --yes --only dotfiles
check "dotfiles: missing hint recipe noted" has "has no hint recipe yet"
check "dotfiles: install still ran" logged "install preserve niri"
reset
JUST_SUMMARY="" DOT_FILES_APPS=niri run '' --yes --only dotfiles
check "dotfiles: missing install recipe skips" has "has no install recipe yet"
reset
mv "$bin/git" "$root/git.off"
run '' --yes --only dotfiles
mv "$root/git.off" "$bin/git"
check "dotfiles: git missing skipped" has "skipped (no git/just)"
reset
export GIT_FAIL=1; run '' --yes --only dotfiles
check "dotfiles: clone failure exits non-zero" test "$rc" != 0
check "dotfiles: clone failure reported" has "FAILED"
reset
run '' --no --only dotfiles
check "dotfiles: --no changes nothing" notlogged "git clone"

# ---- gnome settings
reset
run '' --yes
check "gnome: default no" notlogged "gnome-apply"
reset
run '' --yes --only gnome
check "gnome: --only --yes applies" logged "just --justfile"
check "gnome: gnome-apply called" logged "gnome-apply"
reset
run 'n\n' --only gnome
check "gnome: n applies nothing" notlogged "gnome-apply"
reset
run 'p\nn\n' --only gnome
check "gnome: p runs the dry run" logged "gnome-apply --dry-run"
check "gnome: p then n applies nothing" test "$(grep -c 'gnome-apply' "$LOG")" = 1
reset
run 'y\n' --only gnome
check "gnome: y applies" logged "gnome-apply"
reset
JUST_SUMMARY="install" run '' --yes --only gnome
check "gnome: missing recipe skip" has "has no gnome-apply recipe yet"

# ---- brew tools
reset
run '' --yes
check "brew: default no (no recipe call)" notlogged "dry-run"
reset
run 'n\n' --only brew
check "brew: dry run shown before asking" logged "brew --dry-run"
check "brew: n runs only the dry run" test "$(grep -c "brew$" "$LOG")" = 0
reset
run '' --yes --only brew
check "brew: --only --yes shows the dry run" logged "brew --dry-run"
check "brew: just brew called" grep -q 'just .* brew$' "$LOG"
reset
mv "$bin/brew" "$root/brew.off"
run '' --yes --only brew
mv "$root/brew.off" "$bin/brew"
check "brew: homebrew missing skipped" has "Homebrew is missing"
reset
JUST_SUMMARY="install" run '' --yes --only brew
check "brew: missing recipe skip" has "has no brew recipe yet"

# ---- fonts
reset
run '' --yes --only fonts
check "fonts: --yes installs Kevin's set with brew bundle" logged "brew bundle --file"
check "fonts: no fc-cache or curl" notlogged "curl"
check "fonts: casks recorded" grep -q font-0xproto-nerd-font "$BREW_CASKS"
check "fonts: twelve casks" test "$(wc -l <"$BREW_CASKS")" = 12
check "fonts: Fantasque Nerd Font in the set" grep -qx font-fantasque-sans-mono-nerd-font "$BREW_CASKS"
: >"$LOG"
run '' --yes --only fonts
check "fonts: second run is idempotent" notlogged "brew bundle"
check "fonts: second run says already done" has "already done"
reset
run '2\n\n' --only fonts
check "fonts: option 2 installs JetBrains Mono only" logged "brew install --cask font-jetbrains-mono-nerd-font"
check "fonts: option 2 no bundle" notlogged "brew bundle"
reset
run '3\n1 font-bbb-nerd-font font-unknown-nerd-font 9\n\n' --only fonts
check "fonts: picker installs chosen casks" logged "brew install --cask font-aaa-nerd-font font-bbb-nerd-font"
check "fonts: picker rejects unknown name" has "Ignoring 'font-unknown-nerd-font'"
check "fonts: picker rejects out of range number" has "Ignoring '9'"
reset
run '4\n' --only fonts
check "fonts: skip" notlogged "brew install --cask"
check "fonts: skip no bundle" notlogged "brew bundle"
reset
mv "$bin/brew" "$root/brew.off"
run '' --yes --only fonts
mv "$root/brew.off" "$bin/brew"
check "fonts: brew missing skipped" has "skipped (no brew)"
reset
run '' --no --only fonts
check "fonts: --no changes nothing" notlogged "brew bundle"
reset
printf 'JetBrainsMono Nerd Font\nFiraCode Nerd Font\n' >"$FC_FAMILIES"
run '4\n1\n' --only fonts
check "fonts: terminal font set on explicit choice" grep -q "font-name='FiraCode Nerd Font Medium 10'" "$GS"
check "fonts: use-system-font false" grep -q 'use-system-font=false' "$GS"
reset
printf 'JetBrainsMono Nerd Font\n' >"$FC_FAMILIES"
run '4\n\n' --only fonts
check "fonts: terminal font untouched by default" notlogged "font-name"
reset
printf 'JetBrainsMono Nerd Font\n' >"$FC_FAMILIES"
run '' --yes --only fonts
check "fonts: --yes does not change the terminal font" notlogged "font-name"

# ---- gnome search
reset
printf 'DesktopId=org.gnome.Calculator.desktop\n' >"$root/sp1/calc.ini"
printf 'DesktopId=io.github.kolunmi.Bazaar.desktop\n' >"$root/sp2/bazaar.ini"
run '' --yes
check "search: both enabled" grep -q "enabled=\['io.github.kolunmi.Bazaar.desktop', 'org.gnome.Calculator.desktop'\]\|enabled=\['org.gnome.Calculator.desktop', 'io.github.kolunmi.Bazaar.desktop'\]" "$GS"
check "search: calculator first" grep -q "sort-order=\['org.gnome.Calculator.desktop', 'org.gnome.Settings.desktop'" "$GS"
: >"$LOG"
run '' --yes
check "search: second run no search change" notlogged "gsettings set org.gnome.desktop.search-providers"
reset
printf 'DesktopId=io.github.kolunmi.Bazaar.desktop\n' >"$root/sp2/bazaar.ini"
run '' --yes
check "search: calculator provider missing, not enabled" test "$(grep -c 'Calculator' "$GS")" = 0
check "search: bazaar still enabled" grep -q "enabled=\['io.github.kolunmi.Bazaar.desktop'\]" "$GS"
reset
printf 'DesktopId=io.github.kolunmi.Bazaar.desktop\n' >"$root/sp2/bazaar.ini"
printf "org.gnome.desktop.search-providers enabled=['x.desktop', 'io.github.kolunmi.Bazaar.desktop']\norg.gnome.desktop.search-providers disabled=['io.github.kolunmi.Bazaar.desktop', 'org.mozilla.firefox.desktop']\n" >"$GS"
run '' --yes
check "search: disabled bazaar removed, others kept" grep -q "disabled=\['org.mozilla.firefox.desktop'\]" "$GS"
check "search: user enabled list kept in order" grep -q "enabled=\['x.desktop', 'io.github.kolunmi.Bazaar.desktop'\]" "$GS"
reset
printf 'DesktopId=org.gnome.Calculator.desktop\n' >"$root/sp1/calc.ini"
printf "org.gnome.desktop.search-providers enabled=['org.gnome.Calculator.desktop']\norg.gnome.desktop.search-providers sort-order=['org.gnome.Calculator.desktop', 'a.desktop']\n" >"$GS"
run '' --yes
check "search: sort-order already first untouched" notlogged "gsettings set org.gnome.desktop.search-providers sort-order"
reset
printf 'DesktopId=org.gnome.Calculator.desktop\n' >"$root/sp1/calc.ini"
run '' --no
check "search: --no changes nothing" notlogged "gsettings set org.gnome.desktop.search-providers"

# ---- search: four providers, merge with the current lists
reset
for id in org.gnome.Calculator org.gnome.Characters org.gnome.clocks io.github.kolunmi.Bazaar; do printf 'DesktopId=%s.desktop\n' "$id" >"$root/sp1/$id.ini"; done
printf "org.gnome.desktop.search-providers enabled=['org.gnome.Extension-Manager.desktop', 'org.gnome.Weather.desktop']\norg.gnome.desktop.search-providers sort-order=['z1.desktop', 'org.gnome.Calculator.desktop', 'z2.desktop', 'z3.desktop']\n" >"$GS"
run '' --yes --only search
check "search: unrelated enabled entries kept in order" grep -q "enabled=\['org.gnome.Extension-Manager.desktop', 'org.gnome.Weather.desktop', 'org.gnome.Calculator.desktop'" "$GS"
check "search: all four providers enabled" test "$(grep 'enabled=' "$GS" | grep -o ".desktop'" | wc -l)" = 6
check "search: custom sort-order kept, calculator moved first" grep -q "sort-order=\['org.gnome.Calculator.desktop', 'z1.desktop', 'z2.desktop', 'z3.desktop'\]" "$GS"
: >"$LOG"
run '' --yes --only search
check "search: second run writes nothing" notlogged "gsettings set org.gnome.desktop.search-providers"

echo "passed: $pass, failed: $failn"
[ "$failn" = 0 ]
