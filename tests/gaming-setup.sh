#!/usr/bin/env bash
# Tests for `ujust gaming-setup` (system_files/usr/share/ublue-os/just/60-custom.just).
# flatpak, cargo, git, distrobox and friends are fakes on a restricted PATH; nothing real is installed.
# Needs: bash, just, gzip. Run: tests/gaming-setup.sh
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
justfile="$here/../system_files/usr/share/ublue-os/just/60-custom.just"
shipped_ini="$here/../system_files/usr/share/octarine-os/gamemode.ini"
root=$(mktemp -d)
trap 'rm -rf -- "$root"' EXIT
pass=0
failn=0
bin="$root/bin"
sysbin="$root/sysbin"
mkdir -p "$bin" "$sysbin"
REAL_JUST=$(command -v just)
for c in bash sh env cat grep awk sed zcat gzip cut tr date cmp diff sha256sum mktemp readlink mv rm cp install mkdir id head sort dirname basename wc chmod printf rmdir tee ls touch; do
    p=$(command -v "$c") && ln -sf "$p" "$sysbin/$c"
done
export LOG="$root/log" INSTALLED="$root/installed" REMOTE="$root/remote" HOME="$root/home"
export GAMING_SETUP_APPSTREAM_DIRS="$root/appstream" GAMING_SETUP_GAMEMODE_SRC="$shipped_ini"
export GUMQ="$root/gumq" UGUMQ="$root/ugumq" OCTARINE_MENU_LIB="$here/../system_files/usr/share/octarine-os/lib/menu.sh"
export EXTEST_SRC="$root/extest-src" EXTEST_DEST="$root/extest-dest"
unset XDG_DATA_HOME XDG_STATE_HOME XDG_CONFIG_HOME
printf 'active\n' >"$root/pstate-active"
printf 'passive\n' >"$root/pstate-passive"
export GAMING_SETUP_PSTATE_STATUS="$root/pstate-active"
mkdir -p "$HOME" "$root/appstream"

cat >"$bin/flatpak" <<'F'
#!/usr/bin/env bash
echo "flatpak $*" >>"$LOG"
case "$1" in
    info)
        if [ "$2" = --show-runtime ]; then echo "org.freedesktop.Platform/x86_64/24.08"; exit 0; fi
        grep -qx -- "$2" "$INSTALLED"
        exit $?
        ;;
    list) grep -x 'com.valvesoftware.Steam' "$INSTALLED" | sed 's/$/\tuser/' ;;
    remote-info) grep -qx -- "$3" "$REMOTE"; exit $? ;;
    install)
        for a in "$@"; do case "$a" in --* | install | -y | flathub) ;; *) echo "$a" >>"$INSTALLED" ;; esac; done
        ;;
    override)
        shift
        f="$HOME/.local/share/flatpak/overrides/com.valvesoftware.Steam"
        mkdir -p "$(dirname "$f")"
        for a in "$@"; do case "$a" in --env=*) echo "${a#--env=}" >>"$f" ;; esac; done
        ;;
esac
exit 0
F
cat >"$bin/git" <<'F'
#!/usr/bin/env bash
echo "git $*" >>"$LOG"
if [ "$1" = clone ]; then mkdir -p "${@: -1}/.git"; fi
exit 0
F
cat >"$bin/cargo" <<'F'
#!/usr/bin/env bash
echo "cargo $*" >>"$LOG"
mkdir -p target/x86_64-unknown-linux-gnu/release
echo so >target/x86_64-unknown-linux-gnu/release/libextest.so
F
cat >"$bin/distrobox" <<'F'
#!/usr/bin/env bash
echo "distrobox $*" >>"$LOG"
shift 3
PATH="$BINDIR:$PATH" "$@"
F
export BINDIR="$bin"
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

appstream() { # verified ids...
    {
        echo "<components>"
        for id in "$@"; do
            echo "<component type=\"desktop-application\">"
            echo "<id>$id</id>"
            echo "<custom><value key=\"flathub::verification::verified\">true</value></custom>"
            echo "</component>"
        done
        echo "<component><id>org.example.Unverified</id></component></components>"
    } | gzip >"$root/appstream/appstream.xml.gz"
}
reset() {
    rm -f "$root"/gumq.* "$root"/ugumq.*; unset OCTARINE_MENU_FORCE_TTY GUM_CONFIRM_RC
    rm -rf "$HOME" "$root/extest-src" "$root/extest-dest"
    mkdir -p "$HOME"
    : >"$LOG"; : >"$INSTALLED"; : >"$REMOTE"
    appstream
    unset GAMING_SETUP_RES
}
gumq() { printf '%b' "$2" >"$root/gumq.$1"; }
run() { # stdin text, args...
    local input=$1
    shift
    printf '%b' "$input" | PATH="$bin:$sysbin" "$REAL_JUST" --justfile "$justfile" --working-directory "$root" gaming-setup "$@" >"$root/out" 2>&1
    rc=$?
}
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { failn=$((failn + 1)); echo "FAIL $1"; sed 's/^/     /' "$root/out"; }
check() { local d=$1; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
has() { grep -qF -- "$1" "$root/out"; }
logged() { grep -qF -- "$1" "$LOG"; }
notlogged() { ! grep -qF -- "$1" "$LOG"; }
apps="$HOME/.local/share/applications"
ovr="$HOME/.local/share/flatpak/overrides/com.valvesoftware.Steam"

# usage
reset
run '' bogus
check "unknown step: usage, exit 1" test "$rc" = 1
run '' --bogus
check "unknown flag: exit 1" test "$rc" = 1

# app installs and the verified check
reset
run '' --yes steam
check "steam: not verified, not installed" notlogged "flatpak install"
check "steam: reason printed" has "does not list it as verified"
appstream com.valvesoftware.Steam net.davidotek.pupgui2
run '' --yes
check "yes: steam installed (verified, user installation)" logged "flatpak install --user -y flathub com.valvesoftware.Steam"
check "yes: protonup installed" logged "flatpak install --user -y flathub net.davidotek.pupgui2"
check "yes: lutris not installed by default" notlogged "flathub net.lutris.Lutris"
: >"$LOG"
run '' --yes
check "second run: no install" notlogged "flatpak install"
check "second run: already installed" has "already installed"
reset
appstream net.lutris.Lutris
run '' lutris
check "lutris: named step installs when verified" logged "flatpak install --user -y flathub net.lutris.Lutris"
: >"$LOG"
run '' lutris
check "lutris: idempotent" notlogged "flatpak install"
reset
run '' --no
check "--no changes nothing" notlogged "flatpak install"

# extensions and PATH override
reset
printf 'com.valvesoftware.Steam\n' >"$INSTALLED"
printf '%s\n' 'org.freedesktop.Platform.VulkanLayer.gamescope//24.08' 'org.freedesktop.Platform.VulkanLayer.MangoHud//24.08' >"$REMOTE"
run '' --yes extensions
check "extensions: gamescope and MangoHud installed with the runtime branch" logged "flatpak install --user -y flathub org.freedesktop.Platform.VulkanLayer.gamescope//24.08 org.freedesktop.Platform.VulkanLayer.MangoHud//24.08"
check "extensions: Proton-GE not on Flathub is reported, not installed" has "Not available on Flathub: com.valvesoftware.Steam.CompatibilityTool.Proton-GE//stable"
check "extensions: PATH override with both bin dirs" grep -q 'PATH=/app/bin:/app/utils/bin:/usr/bin:/usr/lib/extensions/vulkan/gamescope/bin:/usr/lib/extensions/vulkan/MangoHud/bin' "$ovr"
printf 'org.freedesktop.Platform.VulkanLayer.gamescope//24.08\norg.freedesktop.Platform.VulkanLayer.MangoHud//24.08\n' >>"$INSTALLED"
: >"$LOG"
run '' --yes extensions
check "extensions: second run changes nothing" notlogged "flatpak install"
check "extensions: second run no override" notlogged "flatpak override"

# extest build
reset
run '' extest
check "extest: builds with host cargo" logged "cargo build --release --locked --target x86_64-unknown-linux-gnu"
check "extest: pinned commit checked out" logged "checkout --quiet --detach cb77cd4f80f83393a24bae17dd975e14fa6eb1b2"
check "extest: library installed" test -f "$EXTEST_DEST/lib64/libextest.so"
: >"$LOG"
run '' extest
check "extest: second run already built" notlogged "cargo build"
reset
mv "$bin/cargo" "$root/cargo.off"
run '' extest
mv "$root/cargo.off" "$bin/cargo"
check "extest: no host cargo uses the dev-toolbox" logged "distrobox enter -n dev-toolbox"
reset
EXTEST_COMMIT=nothex run '' extest
check "extest: bad commit rejected" test "$rc" != 0
reset
run '' --yes
check "extest: default no" notlogged "cargo build"

# desktop launchers
reset
printf 'com.valvesoftware.Steam\n' >"$INSTALLED"
GAMING_SETUP_RES=2560x1440@143.912 run '' desktop
check "desktop: plain launcher written" test -f "$apps/octarine-gaming-steam.desktop"
check "desktop: marker present" grep -qx 'X-Octarine-Generated=ujust gaming-setup' "$apps/octarine-gaming-steam.desktop"
check "desktop: no extest hook when not built" bash -c "! grep -q LD_PRELOAD '$apps/octarine-gaming-steam.desktop'"
check "desktop: gamescope args from the display mode" grep -q -- '-f -W 2560 -H 1440 -r 144 --adaptive-sync' "$apps/octarine-gaming-steam-gamescope.desktop"
: >"$LOG"
GAMING_SETUP_RES=2560x1440@143.912 run '' desktop
check "desktop: second run already up to date" has "already done"
mkdir -p "$EXTEST_DEST/lib64"; echo so >"$EXTEST_DEST/lib64/libextest.so"
GAMING_SETUP_RES=2560x1440@143.912 run '' desktop
check "desktop: extest hooked in once built" grep -q -- "--env=LD_PRELOAD=$EXTEST_DEST/lib64/libextest.so" "$apps/octarine-gaming-steam.desktop"
check "desktop: extest filesystem read-only" grep -q -- "--filesystem=$EXTEST_DEST:ro" "$apps/octarine-gaming-steam-gamescope.desktop"
rm "$apps/octarine-gaming-steam.desktop"; echo "[Desktop Entry]" >"$apps/octarine-gaming-steam.desktop"
GAMING_SETUP_RES=2560x1440@143.912 run '' desktop
check "desktop: file without marker is never overwritten" has "no generated-file marker"
check "desktop: foreign file untouched" test "$(cat "$apps/octarine-gaming-steam.desktop")" = "[Desktop Entry]"
reset
printf 'com.valvesoftware.Steam\n' >"$INSTALLED"
run '' desktop
check "desktop: no display mode, no gamescope launcher" test ! -f "$apps/octarine-gaming-steam-gamescope.desktop"
check "desktop: no display mode says so" has "No display mode found"
reset
run '' desktop
check "desktop: skipped without Steam" has "skipped (no Steam)"

# gamemode
reset
mkdir -p "$HOME/.config"
run '' --yes gamemode
check "gamemode: installed" cmp -s "$shipped_ini" "$HOME/.config/gamemode.ini"
check "gamemode: no [gpu] section shipped" bash -c "! grep -q '^\[gpu\]' '$shipped_ini'"
run '' gamemode
check "gamemode: idempotent" has "already has the tuning"
reset
mkdir -p "$HOME/.config"
echo "; mine" >"$HOME/.config/gamemode.ini"
run '' --yes gamemode
check "gamemode: existing differing file shown as a diff" has "--- "
check "gamemode: explicit step replaces with a backup" test -n "$(ls "$HOME"/.config/gamemode.ini.bak-* 2>/dev/null)"
check "gamemode: replaced content" cmp -s "$shipped_ini" "$HOME/.config/gamemode.ini"
run '' reset --yes
check "reset: backup restored" test "$(cat "$HOME/.config/gamemode.ini")" = "; mine"
reset
run '' gamemode
echo "; edited" >>"$HOME/.config/gamemode.ini"
run '' reset --yes
check "reset: changed gamemode file left alone" has "changed since it was installed"
reset
run '' gamemode
run '' reset --yes
check "reset: unchanged gamemode file removed" test ! -f "$HOME/.config/gamemode.ini"

# reset of launchers and the PATH line only
reset
printf 'com.valvesoftware.Steam\n' >"$INSTALLED"
mkdir -p "$apps" "$(dirname "$ovr")"
GAMING_SETUP_RES=1920x1080@60 run '' desktop
echo "[Desktop Entry]" >"$apps/other.desktop"
printf '[Environment]\nPATH=/app/bin:/usr/lib/extensions/vulkan/gamescope/bin\nFOO=bar\n' >"$ovr"
run '' reset --yes
check "reset: generated launchers removed" test ! -f "$apps/octarine-gaming-steam.desktop"
check "reset: other launchers kept" test -f "$apps/other.desktop"
check "reset: PATH line removed, other override kept" bash -c "! grep -q '^PATH=' '$ovr' && grep -qx 'FOO=bar' '$ovr'"
mkdir -p "$EXTEST_DEST/lib64"; echo so >"$EXTEST_DEST/lib64/libextest.so"
run '' reset --yes
check "reset: library kept under --yes" test -f "$EXTEST_DEST/lib64/libextest.so"
run 'n\nn\ny\nn\n' reset
check "reset: library removed when asked" test ! -f "$EXTEST_DEST/lib64/libextest.so"

# ---- gum checklist (a terminal is faked with OCTARINE_MENU_FORCE_TTY)
reset
appstream net.lutris.Lutris
export OCTARINE_MENU_FORCE_TTY=1
gumq 1 'Apps: Lutris\n'
run ''
check "gum checklist: the chosen step runs" logged "flatpak install --user -y flathub net.lutris.Lutris"
check "gum checklist: unchosen steps do not run" notlogged "flathub com.valvesoftware.Steam"
check "gum checklist: defaults preselected, Lutris not" logged "--selected Apps: Steam,Apps: ProtonUp-Qt,"
check "gum checklist: summary confirmed" logged "gum confirm Run these steps?"
reset
export OCTARINE_MENU_FORCE_TTY=1
run ''
check "gum checklist: Esc (empty) changes nothing" notlogged "flatpak install"
check "gum checklist: Esc is not a failure" test "$rc" = 0
reset
appstream net.lutris.Lutris
export OCTARINE_MENU_FORCE_TTY=1 GUM_CONFIRM_RC=1
gumq 1 'Apps: Lutris\n'
run ''
check "gum checklist: declining changes nothing" notlogged "flatpak install"
reset
export OCTARINE_MENU_FORCE_TTY=1
run '' --yes
check "gum: --yes asks nothing" notlogged "gum choose"
reset
export OCTARINE_MENU_FORCE_TTY=1
run '' reset --yes
check "gum: a named step (reset) opens no checklist" notlogged "gum choose"

# gamemode without amd-pstate in active mode: the desiredgov workaround is left out, the tuned part stays
reset
GAMING_SETUP_PSTATE_STATUS="$root/pstate-passive" run '' --yes gamemode
check "gamemode (no amd-pstate active): no desiredgov line and no workaround comment" bash -c "! grep -q '^desiredgov=\|gamemode#419\|FeralInteractive' '$HOME/.config/gamemode.ini'"
check "gamemode (no amd-pstate active): renice and the tuned start/end stay" bash -c "grep -q '^renice=10' '$HOME/.config/gamemode.ini' && grep -q '^start=tuned-adm' '$HOME/.config/gamemode.ini' && grep -q '^end=tuned-adm' '$HOME/.config/gamemode.ini'"
check "gamemode (no amd-pstate active): the note says why" has "amd-pstate is not in active mode"
GAMING_SETUP_PSTATE_STATUS="$root/pstate-passive" run '' gamemode
check "gamemode (no amd-pstate active): idempotent" has "already has the tuning"
reset
GAMING_SETUP_PSTATE_STATUS="$root/missing" run '' --yes gamemode
check "gamemode (no pstate file at all): also left out" bash -c "! grep -q '^desiredgov=' '$HOME/.config/gamemode.ini'"
reset
run '' --yes gamemode
check "gamemode (amd-pstate active): the workaround is installed" bash -c "grep -q '^desiredgov=powersave' '$HOME/.config/gamemode.ini'"

echo "passed: $pass, failed: $failn"
[ "$failn" = 0 ]
