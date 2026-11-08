#!/usr/bin/env bash
# Tests for `ujust dev-toolbox` and `ujust brew` (system_files/usr/share/ublue-os/just/60-custom.just).
# No network and nothing real is installed or created: curl, distrobox and distrobox-export are fakes,
# keystrokes come from a file through UPM_TTY, and everything runs in a temp dir with its own HOME.
# Needs: bash, just, setpriv (util-linux). Run: tests/dev-toolbox.sh
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
justfile="$here/../system_files/usr/share/ublue-os/just/60-custom.just"
shipped_def="$here/../system_files/usr/share/ublue-os/distrobox/fedora-toolbox.ini"
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
    echo "---- output ----"
    sed 's/^/     /' "$root/out" 2>/dev/null
    echo "----------------"
}
check() { # description, command...
    local d=$1
    shift
    if "$@"; then ok "$d"; else bad "$d"; fi
}
has() { grep -qF -- "$1" "$root/out"; }
hasnt() { ! grep -qF -- "$1" "$root/out"; }
logged() { grep -qF -- "$1" "$LOG" 2>/dev/null; }
notlogged() { ! grep -qF -- "$1" "$LOG" 2>/dev/null; }
instate() { grep -qxF -- "$1" "$state" 2>/dev/null; }
boxes() { cat "$FAKE_STATE/boxes" 2>/dev/null; }

# ---- fakes -----------------------------------------------------------------
tpl="$root/tpl"
mkdir -p "$tpl" "$root/fakebin"

# host side: curl
cat >"$root/fakebin/curl" <<'EOF'
#!/bin/bash
out=""
url=""
while [ $# -gt 0 ]; do
    case "$1" in
        -o) out=$2; shift 2 ;;
        --proto) shift 2 ;;
        -*) shift ;;
        *) url=$1; shift ;;
    esac
done
echo "curl url=$url" >>"$LOG"
case "$url" in
    https://*) ;;
    *) exit 1 ;;
esac
case "$url" in
    *Homebrew*) id=brew ;;
    *sdkman*) id=sdkman ;;
    *nvm*) id=nvm ;;
    *) exit 1 ;;
esac
case " ${FAKE_CURL_FAIL:-} " in *" $id "*) exit 22 ;; esac
cat >"$out" <<EOS
#!/bin/bash
echo "installer $id args=\$* nonint=\${NONINTERACTIVE:-} path0=\${PATH%%:*}" >>"$LOG"
if [ -n "\${FAKE_SUDO:-}" ]; then sudo true || exit 1; fi
mk() { mkdir -p "\$(dirname "\$1")"; echo x >"\$1"; chmod +x "\$1"; }
case "$id" in
    brew) mk "\$UPM_BREW_PREFIX/bin/brew" ;;
    sdkman) mk "\$HOME/.sdkman/bin/sdkman-init.sh" ;;
    nvm) mk "\$HOME/.nvm/nvm.sh" ;;
esac
EOS
EOF

# host side: distrobox (state in $FAKE_STATE)
cat >"$root/fakebin/distrobox" <<'EOF'
#!/bin/bash
case "$1" in
    list)
        echo 'ID | NAME | STATUS | IMAGE'
        while read -r b; do [ -n "$b" ] && echo "abc123 | $b | ${FAKE_BOX_STATUS:-Up 2 hours} | fedora"; done <"$FAKE_STATE/boxes" 2>/dev/null
        exit 0
        ;;
    assemble)
        shift
        [ "$1" = create ] && shift
        [ "$1" = --file ] && f=$2
        echo "assemble $f" >>"$LOG"
        [ -n "${FAKE_ASSEMBLE_FAIL:-}" ] && exit 1
        cp -- "$f" "$FAKE_STATE/assembled.ini"
        sed -n 's/^\[\(.*\)\]$/\1/p' "$f" >>"$FAKE_STATE/boxes"
        ;;
    rm)
        shift
        echo "rm $*" >>"$LOG"
        [ -n "${FAKE_RM_FAIL:-}" ] && exit 1
        for last; do :; done
        grep -vx -- "$last" "$FAKE_STATE/boxes" >"$FAKE_STATE/boxes.new" || true
        mv -- "$FAKE_STATE/boxes.new" "$FAKE_STATE/boxes"
        ;;
    enter)
        shift 2
        [ "$1" = -- ] && shift
        export PATH="$FAKE_BOXBIN"
        exec "$@"
        ;;
esac
EOF

cat >"$root/fakebin/podman" <<'EOF'
#!/bin/bash
# image ids live in $FAKE_STATE/cur_id (what the box was built from) and new_id (what a pull gives)
case "$1" in
    pull)
        echo "podman pull $*" >>"$LOG"
        cat "$FAKE_STATE/new_id"
        ;;
    inspect) cat "$FAKE_STATE/cur_id" ;;
    start)
        shift
        echo "podman start $*" >>"$LOG"
        ;;
    image)
        for last; do :; done
        case "$*" in
            *.Id*) cat "$FAKE_STATE/new_id" ;;
            *.Digest*) echo "sha256:digest-$last" ;;
        esac
        ;;
    run)
        shift
        shift # --rm
        ep=""
        if [ "$1" = --entrypoint ]; then ep=$2; shift 2; fi
        id=$1
        shift
        if [ "$ep" = cat ]; then
            echo "VERSION_ID=$(cat "$FAKE_STATE/ver-$id")"
        fi
        ;;
esac
EOF
chmod +x "$root/fakebin/podman"
sed -i 's/^    enter)$/    upgrade)\n        echo "upgrade $*" >>"$LOG"\n        ;;\n    enter)/' "$root/fakebin/distrobox"

# box side tools, copied into each environment's boxbin
cat >"$tpl/distrobox-export" <<'EOF'
#!/bin/bash
bin=""
dir=""
while [ $# -gt 0 ]; do
    case "$1" in
        --bin) bin=$2; shift 2 ;;
        --export-path) dir=$2; shift 2 ;;
        *) shift ;;
    esac
done
echo "export bin=$bin" >>"$LOG"
printf '#!/bin/sh\n# exported %s\n' "$bin" >"$dir/$(basename "$bin")"
chmod +x "$dir/$(basename "$bin")"
EOF
# Fedora's rustup package ships only rustup-init: the proxies in ~/.cargo/bin exist after it has run
cat >"$tpl/rustup-init" <<'EOF'
#!/bin/bash
echo "rustup-init $*" >>"$LOG"
if [ -n "${FAKE_SUDO:-}" ]; then sudo true || exit 1; fi
if [ "$*" = "-y --no-modify-path --default-toolchain stable" ]; then
    mkdir -p "$HOME/.rustup/toolchains/stable-x86_64" "$HOME/.cargo/bin"
    for t in rustup cargo rustc; do echo x >"$HOME/.cargo/bin/$t"; chmod +x "$HOME/.cargo/bin/$t"; done
else
    exit 2
fi
EOF
for t in gcc make uv uvx lsscsi; do printf '#!/bin/sh\necho %s\n' "$t" >"$tpl/$t"; done
chmod +x "$root/fakebin"/* "$tpl"/*

command -v just >/dev/null || {
    echo "just is required"
    exit 2
}
command -v setpriv >/dev/null || {
    echo "setpriv is required"
    exit 2
}

n=0
ORIG_PATH=$PATH
newenv() { # fresh HOME, temp dir, fake box tools and log
    n=$((n + 1))
    E="$root/e$n"
    mkdir -p "$E/home/.local/bin" "$E/tmp" "$E/run" "$E/boxbin" "$E/fake"
    local t
    for t in bash sh setpriv mkdir dirname basename chmod cat env; do ln -s "$(command -v "$t")" "$E/boxbin/$t"; done
    cp "$tpl"/* "$E/boxbin/"
    export HOME="$E/home" TMPDIR="$E/tmp" XDG_RUNTIME_DIR="$E/run"
    export UPM_BREW_DIR="$E/linuxbrew" UPM_BREW_PREFIX="$E/linuxbrew/.linuxbrew"
    export LOG="$E/log" FAKE_STATE="$E/fake" FAKE_BOXBIN="$E/boxbin"
    : >"$LOG"
    unset FAKE_SUDO FAKE_CURL_FAIL FAKE_ASSEMBLE_FAIL FAKE_RM_FAIL FAKE_BOX_STATUS DEV_TOOLBOX_IMAGE XDG_STATE_HOME XDG_CONFIG_HOME XDG_DATA_HOME
    apps="$HOME/.local/share/applications"
    export UPM_JB_SCRIPTS="$E/jb/scripts"
    mkdir -p "$E/jb/scripts" "$E/jb/apps/PyCharm/ch-0/9.9/bin" "$E/jb/apps/DataGrip/ch-0/9.9/bin"
    for t in pycharm datagrip; do
        case "$t" in pycharm) D=PyCharm ;; *) D=DataGrip ;; esac
        printf '#!/bin/sh\nexec "%s/jb/apps/%s/ch-0/9.9/bin/%s.sh" "$@"\n' "$E" "$D" "$t" >"$E/jb/scripts/$t"
        chmod +x "$E/jb/scripts/$t"
        printf '<svg/>' >"$E/jb/apps/$D/ch-0/9.9/bin/$t.svg"
    done
    export DEV_TOOLBOX_DEFINITION="$shipped_def"
    echo old1 >"$FAKE_STATE/cur_id"
    echo old1 >"$FAKE_STATE/new_id"
    echo 44 >"$FAKE_STATE/ver-old1"
    echo 44 >"$FAKE_STATE/ver-new2"
    export PATH="$root/fakebin:$ORIG_PATH"
    state="$HOME/.local/state/ublue-os/dev-toolbox"
    conf="$HOME/.config/distrobox/distrobox.conf"
}
mkbox() { echo fedora-toolbox >"$FAKE_STATE/boxes"; }
rc=0
run() { # keys, args...
    printf '%s' "$1" >"$root/keys"
    shift
    UPM_TTY="$root/keys" just --justfile "$justfile" dev-toolbox "$@" >"$root/out" 2>&1 </dev/null
    rc=$?
}
runbrew() { # keys
    printf '%s' "$1" >"$root/keys"
    UPM_TTY="$root/keys" just --justfile "$justfile" brew >"$root/out" 2>&1 </dev/null
    rc=$?
}

# ---- the shipped definition ---------------------------------------------------
check "definition has the fedora-toolbox section" grep -qx '\[fedora-toolbox\]' "$shipped_def"
check "definition uses our toolbox image" grep -qx 'image=ghcr.io/redcodeworks/fedora-toolbox:latest' "$shipped_def"
check "definition pulls, does not replace, starts" bash -c "grep -qx 'pull=true' '$shipped_def' && grep -qx 'replace=false' '$shipped_def' && grep -qx 'start_now=true' '$shipped_def'"
check "definition has no additional_packages key" bash -c "! grep -qE '^additional_packages' '$shipped_def'"
check "definition has no home= key" bash -c "! grep -qE '^home=' '$shipped_def'"
check "definition has no exported_bins keys" bash -c "! grep -qE '^exported_bins' '$shipped_def'"
check "definition mounts brew read-only" grep -qx 'volume="/home/linuxbrew:/home/linuxbrew:ro"' "$shipped_def"
check "definition has no pixi" bash -c "! grep -q pixi '$shipped_def'"
check "definition says where the packages live" bash -c "grep -q 'packages/dev.txt' '$shipped_def' && grep -q 'rustup-init' '$shipped_def'"

# ---- --list on an empty machine -----------------------------------------------
newenv
run "" --list
check "--list exits 0" test "$rc" -eq 0
check "--list shows the box missing" has "fedora-toolbox (missing)"
check "--list shows the default name unset" has "not set in"
check "--list shows every row" bash -c "for t in uv rustup sdkman nvm buildchain clitools; do grep -q \"^\$t \" '$root/out' || exit 1; done"
check "--list shows each source" bash -c "grep -qE '^uv .*image:uv' '$root/out' && grep -qE '^rustup .*image:rustup-init' '$root/out' && grep -qE '^sdkman .*installer' '$root/out'"
run "" nosuchtool
check "unknown tool exits 2" test "$rc" -eq 2
run "" --bogus
check "unknown option exits 2" test "$rc" -eq 2
run "" --dry-run
check "--dry-run alone exits 2" test "$rc" -eq 2
run "" --remove nvm
check "--remove with a tool exits 2" test "$rc" -eq 2

# ---- create the box, no brew dir, named tools -------------------------------------
newenv
run "yyy" sdkman nvm
check "first run exits 0" test "$rc" -eq 0
check "box was assembled" logged "assemble "
check "assembled copy has no brew volume while the dir is missing" bash -c "! grep -q '^volume=' '$FAKE_STATE/assembled.ini'"
check "assembled copy keeps the image line" grep -qx 'image=ghcr.io/redcodeworks/fedora-toolbox:latest' "$FAKE_STATE/assembled.ini"
check "the recipe prints the image it uses" has "Image: ghcr.io/redcodeworks/fedora-toolbox:latest"
check "missing brew dir is explained" has "does not exist yet"
check "recreate hint printed" has "ujust dev-toolbox --recreate"
check "box recorded" instate "box fedora-toolbox"
check "no-brew-mount recorded" instate "box-no-brew-mount"
check "default name written" grep -qx 'container_name_default="fedora-toolbox"' "$conf"
check "default name creation recorded" instate "conf created"
check "sdkman installed" test -s "$HOME/.sdkman/bin/sdkman-init.sh"
check "nvm installed" test -s "$HOME/.nvm/nvm.sh"
check "directories recorded as created" bash -c "grep -qxF 'dir $HOME/.sdkman created' '$state' && grep -qxF 'dir $HOME/.nvm created' '$state'"
check "curl url logged" logged "curl url=https://get.sdkman.io?rcupdate=false"
check "sudo stub first on PATH" logged "path0=$E/tmp/upm."
check "hash printed" has "sha256 "
check "vendor warning printed" has "vendor code"
check "build chain exported" test -e "$HOME/.local/bin/gcc" -a -e "$HOME/.local/bin/make"
check "cli tools exported" test -e "$HOME/.local/bin/lsscsi"
check "uv and uvx exported" test -e "$HOME/.local/bin/uv" -a -e "$HOME/.local/bin/uvx"
check "export used distrobox-export" logged "export bin=$E/boxbin/gcc"
check "exports recorded" instate "export $HOME/.local/bin/gcc"
check "sdk wrapper enters the box" grep -q "distrobox enter fedora-toolbox" "$HOME/.local/bin/sdk"
check "sdk wrapper sources sdkman" grep -q "sdkman-init.sh" "$HOME/.local/bin/sdk"
check "sdk wrapper recorded" instate "export $HOME/.local/bin/sdk"
check "rustup not exported before a toolchain exists" test ! -e "$HOME/.local/bin/rustup"
check "undo note printed" has "To undo"
check "rc files untouched" test ! -e "$HOME/.bashrc"
check "no temp files left" bash -c "! ls '$E/tmp'/upm.* >/dev/null 2>&1"

# ---- second run is idempotent ------------------------------------------------------
: >"$LOG"
run "" sdkman nvm
check "rerun exits 0" test "$rc" -eq 0
check "rerun keeps the box" has "exists"
check "rerun does not assemble" notlogged "assemble "
check "rerun does not download" notlogged "curl url="
check "rerun does not export again" notlogged "export bin="
check "rerun says already exported" has "already exported"
check "rerun leaves the default alone" has "already fedora-toolbox"
run "" --list
check "--list shows the box present" has "fedora-toolbox (present)"
check "--list shows the default name" has "Default name:  fedora-toolbox"
check "--list shows uv exported" grep -qE '^uv +installed +image:uv +yes' "$root/out"
check "--list shows sdkman exported" grep -qE '^sdkman +installed +installer +yes' "$root/out"
check "--list shows rustup missing" grep -qE '^rustup +missing' "$root/out"

# ---- brew dir present: the mount stays in the assembled copy ---------------------------
newenv
mkdir -p "$UPM_BREW_DIR"
run "yq"
check "brew mount kept when the dir exists" grep -q 'linuxbrew' "$FAKE_STATE/assembled.ini"
check "no missing-brew note when it exists" hasnt "does not exist yet"
check "no-brew-mount not recorded" bash -c "! grep -qx box-no-brew-mount '$state'"

# ---- definition override ------------------------------------------------------------
newenv
printf '# custom definition\n[fedora-toolbox]\nimage=example\nvolume="/home/linuxbrew:/home/linuxbrew:ro"\n' >"$E/custom.ini"
export DEV_TOOLBOX_DEFINITION="$E/custom.ini"
run "yq"
check "DEV_TOOLBOX_DEFINITION overrides the definition" grep -q 'custom definition' "$FAKE_STATE/assembled.ini"
export DEV_TOOLBOX_DEFINITION="$shipped_def"

# ---- upgrade and update -------------------------------------------------------------
newenv
mkbox
run "" --upgrade
check "same base: exit 0" test "$rc" -eq 0
check "same base: says so" has "already on the latest image"
check "same base: prints the image" has "Toolbox image: ghcr.io/redcodeworks/fedora-toolbox:latest"
check "same base: pulled the image" logged "podman pull"
check "same base: nothing replaced" bash -c "! grep -q '^rm ' '$LOG' && ! grep -q '^assemble' '$LOG'"
check "same base: no package resolution test" notlogged "dnf5"

echo new2 >"$FAKE_STATE/new_id"
run "" --upgrade --check
check "check: exit 0" test "$rc" -eq 0
check "check: shows current digest and release" bash -c "grep -q 'digest sha256:digest-old1, Fedora 44' '$root/out'"
check "check: shows new digest and release" bash -c "grep -q 'digest sha256:digest-new2, Fedora 44' '$root/out'"
check "check: says check only" has "Check only: nothing was changed"
check "check: changes nothing" bash -c "! grep -q '^rm ' '$LOG' && ! grep -q '^assemble' '$LOG'"
check "check: no package resolution test" notlogged "dnf5"

echo 45 >"$FAKE_STATE/ver-new2"
run "no
" --upgrade
check "major change warns" has "Fedora release changes from 44 to 45"
check "major change says tools in home may need a rebuild" has "may need a rebuild"
check "no package resolution test before asking" notlogged "dnf5"
check "declining the upgrade changes nothing" has "Nothing was changed"
check "declining leaves the box" bash -c "! grep -q '^rm ' '$LOG' && grep -qx fedora-toolbox '$FAKE_STATE/boxes'"


newenv
run "yyy" sdkman nvm
echo new2 >"$FAKE_STATE/new_id"
: >"$LOG"
run "yes
" --upgrade
check "newer base: exit 0" test "$rc" -eq 0
check "newer base: container replaced" bash -c "grep -q '^rm --force fedora-toolbox' '$LOG' && grep -q '^assemble' '$LOG'"
check "newer base: no second confirmation" hasnt "remove and recreate the box"
check "newer base: no tool checklist" hasnt "Tools in the box"
check "newer base: exports made again" test -e "$HOME/.local/bin/gcc"
check "newer base: installs in the shared home survive" test -s "$HOME/.sdkman/bin/sdkman-init.sh" -a -s "$HOME/.nvm/nvm.sh"
check "newer base: no installer re-run" notlogged "installer "

newenv
mkbox
run "" --update
check "update runs distrobox upgrade on the box" logged "upgrade fedora-toolbox"
check "update exits 0" test "$rc" -eq 0
newenv
run "" --update
check "update without a box fails" test "$rc" -ne 0
run "" --upgrade --remove
check "upgrade with remove exits 2" test "$rc" -eq 2
run "" --check
check "check alone exits 2" test "$rc" -eq 2

# ---- declining and failing box creation -------------------------------------------------
newenv
run "n"
check "declining creation exits 0" test "$rc" -eq 0
check "declined box is not assembled" notlogged "assemble "
check "declined box writes no default" test ! -e "$conf"
newenv
export FAKE_ASSEMBLE_FAIL=1
run "y"
check "failed assemble exits non-zero" test "$rc" -ne 0
check "failed assemble is reported" has "assemble failed"

# ---- default name: other value asks, appended keeps the rest ----------------------------------
newenv
mkbox
mkdir -p "$(dirname "$conf")"
printf 'container_manager="podman"\ncontainer_name_default="other"\n' >"$conf"
run "n"
check "other value is shown" has "currently set to 'other'"
check "declining leaves the other value" grep -qx 'container_name_default="other"' "$conf"
run "y"
check "accepting changes only that key" bash -c "grep -qx 'container_name_default=\"fedora-toolbox\"' '$conf' && grep -qx 'container_manager=\"podman\"' '$conf'"
check "change recorded with the old value" instate "conf changed other"
newenv
mkbox
mkdir -p "$(dirname "$conf")"
printf 'container_manager="podman"' >"$conf"
run ""
check "missing key is appended on its own line" bash -c "grep -qx 'container_manager=\"podman\"' '$conf' && grep -qx 'container_name_default=\"fedora-toolbox\"' '$conf'"
check "append recorded" instate "conf appended"

# ---- checklist ---------------------------------------------------------------------------------
newenv
mkbox
run "q"
check "q skips the tool list" has "Skipped the tool list"
check "q exits 0" test "$rc" -eq 0
check "q installs nothing" notlogged "installer "
check "q still exports" test -e "$HOME/.local/bin/gcc"

newenv
mkbox
run "$(printf ' \nyy')"
check "checklist install exits 0" test "$rc" -eq 0
check "SPACE toggled rustup off" test ! -d "$HOME/.rustup/toolchains/stable-x86_64"
check "sdkman and nvm installed from the checklist" test -s "$HOME/.sdkman/bin/sdkman-init.sh" -a -s "$HOME/.nvm/nvm.sh"

newenv
mkbox
run "$(printf '\nyyy')"
check "ENTER with defaults runs rustup-init" logged "rustup-init -y --no-modify-path --default-toolchain stable"
check "rustup-init asked first" has "[y] run 'rustup-init"
check "toolchain exists" test -d "$HOME/.rustup/toolchains/stable-x86_64"
check "rustup proxies created in ~/.cargo/bin" test -x "$HOME/.cargo/bin/rustup"
check "rustup proxies exported" test -e "$HOME/.local/bin/cargo" -a -e "$HOME/.local/bin/rustc" -a -e "$HOME/.local/bin/rustup"
check "rustup-init itself is not exported" bash -c "test ! -e '$HOME/.local/bin/rustup-init' && ! grep -q 'rustup-init\$' '$state'"
check "no /usr/bin/rustup is assumed" notlogged "bin=/usr/bin/rustup"
check "rc files untouched by rustup-init" test ! -e "$HOME/.bashrc"
check "rustup exports recorded" instate "export $HOME/.local/bin/cargo"
check "rustup toolchain download explained" has "static.rust-lang.org"
check "rustup directories recorded" bash -c "grep -qxF 'dir $HOME/.rustup created' '$state' && grep -qxF 'dir $HOME/.cargo created' '$state'"
run ""
check "everything set up: checklist says so" has "already set up"

# ---- missing dnf package --------------------------------------------------------------------------
newenv
mkbox
rm -f "$E/boxbin/uv" "$E/boxbin/uvx"
run "" uv
check "missing uv is reported" has "is not in the box"
check "upgrade hint for a missing package" has "ujust dev-toolbox --upgrade"
check "missing package fails" test "$rc" -ne 0
newenv
mkbox
rm -f "$E/boxbin/rustup-init"
run "" rustup
check "missing rustup-init is reported" has "is not in the box"
check "missing rustup-init fails" test "$rc" -ne 0
check "missing rustup-init points at --upgrade" has "ujust dev-toolbox --upgrade"

# rustup already set up in the home (rustup-init gone from the box): nothing to do, proxies still export
newenv
mkbox
mkdir -p "$HOME/.cargo/bin"
for t in rustup cargo rustc; do echo x >"$HOME/.cargo/bin/$t"; chmod +x "$HOME/.cargo/bin/$t"; done
rm -f "$E/boxbin/rustup-init"
run "" rustup
check "existing ~/.cargo/bin/rustup counts as installed" has "Already set up"
check "existing rustup exits 0" test "$rc" -eq 0
check "existing rustup runs no rustup-init" notlogged "rustup-init"
check "existing rustup proxies are exported" test -e "$HOME/.local/bin/cargo" -a -e "$HOME/.local/bin/rustup"
check "existing ~/.cargo is not recorded as created" bash -c "! grep -qxF 'dir $HOME/.cargo created' '$state'"
run "" --list
check "--list: rustup installed from ~/.cargo/bin/rustup alone" grep -qE '^rustup +installed' "$root/out"

# DEV_TOOLBOX_IMAGE overrides the image= line
newenv
export DEV_TOOLBOX_IMAGE=ghcr.io/redcodeworks/fedora-toolbox:testing
run "y" sdkman
check "override: assembled copy uses the override image" grep -qx 'image=ghcr.io/redcodeworks/fedora-toolbox:testing' "$FAKE_STATE/assembled.ini"
check "override: the old image line is gone" bash -c "! grep -q 'toolbox:latest' '$FAKE_STATE/assembled.ini'"
check "override: other keys kept" grep -qx 'pull=true' "$FAKE_STATE/assembled.ini"
check "override: the recipe prints the image" has "Image: ghcr.io/redcodeworks/fedora-toolbox:testing"
run "" --list
check "override: --list shows the image" has "Image:         ghcr.io/redcodeworks/fedora-toolbox:testing"
echo new2 >"$FAKE_STATE/new_id"
run "" --upgrade --check
check "override: --upgrade pulls the override image" logged "pull -q ghcr.io/redcodeworks/fedora-toolbox:testing"
unset DEV_TOOLBOX_IMAGE

# ---- sudo is blocked --------------------------------------------------------------------------------
newenv
mkbox
export FAKE_SUDO=1
run "y" nvm
check "sudo attempt fails the installer" test "$rc" -ne 0
check "stub message shown" has "sudo is not allowed here"
check "plain explanation shown" has "wanted sudo"
check "nothing installed after the sudo attempt" test ! -e "$HOME/.nvm/nvm.sh"
run "y" rustup
check "rustup-init blocked from sudo too" has "wanted sudo"
check "no toolchain after the sudo attempt" test ! -d "$HOME/.rustup/toolchains/stable-x86_64"
unset FAKE_SUDO
check "no executable sudo in either recipe" bash -c "! sed -n '/^brew:/,\$p' '$justfile' | grep -w sudo | grep -vE '^\s*(echo|printf|#)|grep -qiE|sudo-called|bin/sudo|no-sudo guard'"

# ---- failed download, declining, view --------------------------------------------------------------------
newenv
mkbox
export FAKE_CURL_FAIL=nvm
run "y" nvm
check "failed download reported" has "Download failed"
check "failed download exits non-zero" test "$rc" -ne 0
unset FAKE_CURL_FAIL
run "n" nvm
check "declining skips" has "Skipped nvm"
check "declined installer not run" notlogged "installer nvm"
export PAGER=cat
run "vy" nvm
check "v shows the installer" has "installer nvm"
check "then y runs it" test -s "$HOME/.nvm/nvm.sh"

# ---- never overwrite ------------------------------------------------------------------------------------------
newenv
mkbox
printf 'mine\n' >"$HOME/.local/bin/gcc"
printf 'mine\n' >"$HOME/.local/bin/sdk"
run "y" sdkman
check "existing gcc kept" test "$(cat "$HOME/.local/bin/gcc")" = mine
check "existing sdk kept" test "$(cat "$HOME/.local/bin/sdk")" = mine
check "skip reported" has "Skipped $HOME/.local/bin/gcc"
check "skipped files not recorded" bash -c "! grep -qxF 'export $HOME/.local/bin/gcc' '$state' && ! grep -qxF 'export $HOME/.local/bin/sdk' '$state'"

# ---- recreate ---------------------------------------------------------------------------------------------------
newenv
run "yyy" sdkman nvm
printf 'mine\n' >"$HOME/.local/bin/mytool"
: >"$LOG"
run "n" --recreate
check "declining recreate keeps the box" has "Kept the existing box"
check "declining recreate removes nothing" notlogged "rm "
check "declining recreate keeps exports" test -e "$HOME/.local/bin/gcc"
run "y" --recreate
check "recreate exits 0" test "$rc" -eq 0
check "recreate says home survives" has "Your home is shared"
check "recreate removed the container" logged "rm --force fedora-toolbox"
check "recreate removed a listed stale export" has "Removed old export $HOME/.local/bin/gcc"
check "recreate leaves unlisted files alone" test "$(cat "$HOME/.local/bin/mytool")" = mine
check "recreate assembled again" logged "assemble "
check "exports are made again" test -e "$HOME/.local/bin/gcc"
check "shared home survives a recreate" test -s "$HOME/.sdkman/bin/sdkman-init.sh"

# ---- remove ---------------------------------------------------------------------------------------------------
newenv
mkdir -p "$HOME/.cargo/bin" # exists before the recipe runs, so it must survive --remove
printf 'kept\n' >"$HOME/.cargo/bin/user-installed"
run "yyyy" sdkman nvm rustup
printf 'mine\n' >"$HOME/.local/bin/mytool"
check "setup for remove: pre-existing dir recorded as existed" instate "dir $HOME/.cargo existed"
check "setup for remove: new dirs recorded as created" bash -c "grep -qxF 'dir $HOME/.rustup created' '$state' && grep -qxF 'dir $HOME/.sdkman created' '$state'"
: >"$LOG"
run "" --remove --dry-run
check "dry run exits 0" test "$rc" -eq 0
check "dry run lists exports with sizes" has "export    $HOME/.local/bin/gcc"
check "dry run lists the container" has "container fedora-toolbox"
check "dry run lists created directories" bash -c "grep -q 'directory $HOME/.sdkman' '$root/out' && grep -q 'directory $HOME/.nvm' '$root/out' && grep -q 'directory $HOME/.rustup' '$root/out'"
check "dry run lists the setting and the state file" bash -c "grep -q 'setting   container_name_default' '$root/out' && grep -q 'state     $state' '$root/out'"
check "dry run names the skipped pre-existing dir and why" has "$HOME/.cargo (already existed before this recipe, left alone)"
check "dry run says nothing was removed" has "Dry run: nothing was removed"
check "dry run changed nothing" bash -c "test -e '$HOME/.local/bin/gcc' -a -d '$HOME/.sdkman' -a -d '$HOME/.rustup' -a -f '$state' -a -f '$conf' && grep -qx fedora-toolbox '$FAKE_STATE/boxes'"
check "dry run never called distrobox rm" notlogged "rm "
run "no
" --remove
check "declining the prompt exits 0" test "$rc" -eq 0
check "declining says nothing was removed" has "Nothing was removed"
check "warning about ~/.cargo and ~/.sdkman shown" has "cargo install binaries"
check "declining changed nothing" bash -c "test -e '$HOME/.local/bin/gcc' -a -d '$HOME/.sdkman' -a -f '$state' && grep -qx fedora-toolbox '$FAKE_STATE/boxes'"
check "declining never called distrobox rm" notlogged "rm "
# simulated failure at the container step: exports and the setting go, the rest stays, state is kept
export FAKE_RM_FAIL=1
run "yes
" --remove
check "failed step exits non-zero" test "$rc" -ne 0
check "failed step is reported" has "Could not remove the container"
check "exports were removed before the failure" test ! -e "$HOME/.local/bin/gcc"
check "the default-name setting was removed before the failure" test ! -e "$conf"
check "directories survive a failed container step" test -d "$HOME/.sdkman" -a -d "$HOME/.rustup"
check "state file survives a failed step" test -f "$state"
unset FAKE_RM_FAIL
run "yes
" --remove
check "rerun finishes the job" test "$rc" -eq 0
check "rerun removed the container" bash -c "! grep -qx fedora-toolbox '$FAKE_STATE/boxes'"
check "recorded directories removed" test ! -e "$HOME/.sdkman" -a ! -e "$HOME/.nvm" -a ! -e "$HOME/.rustup"
check "pre-existing ~/.cargo survives" test "$(cat "$HOME/.cargo/bin/user-installed")" = kept
check "files the recipe did not create survive" test "$(cat "$HOME/.local/bin/mytool")" = mine
check "~/.local/bin itself survives" test -d "$HOME/.local/bin"
check "state file removed last" test ! -e "$state"
run "" --remove
check "with no state there is nothing to remove" has "nothing to remove"

newenv
mkbox
mkdir -p "$(dirname "$conf")"
printf 'container_manager="podman"\ncontainer_name_default="other"\n' >"$conf"
run "y" nvm
check "setup for conf restore" instate "conf changed other"
run "yes
" --remove
check "remove restores the old default name" grep -qx 'container_name_default="other"' "$conf"
check "remove keeps other settings" grep -qx 'container_manager="podman"' "$conf"
newenv
mkbox
run "y" nvm
printf 'container_name_default="changed-later"\n' >"$conf"
run "yes
" --remove
check "a setting changed since is left alone and explained" bash -c "grep -qx 'container_name_default=\"changed-later\"' '$conf' && grep -q 'now .changed-later., not what this recipe wrote' '$root/out'"

# ---- IDE launchers -------------------------------------------------------------------
newenv
mkbox
run "" --ide --list
check "ide list exits 0" test "$rc" -eq 0
check "ide list detects the Toolbox scripts" bash -c "grep -qE '^pycharm +yes +not created' '$root/out' && grep -qE '^datagrip +yes' '$root/out'"
check "ide list shows undetected IDEs" bash -c "grep -qE '^idea +no' '$root/out' && grep -qE '^vscode +no' '$root/out'"
check "ide list creates nothing" test ! -e "$apps"
run "" --ide idea
check "an undetected IDE is explained" has "Generate shell scripts"
check "an undetected IDE fails" test "$rc" -ne 0
run "" --ide vscode
check "missing VS Code says what is missing" has "no VS Code tarball under your home"
check "missing VS Code does not install anything" notlogged "curl url="
run "" --ide nosuch
check "unknown IDE exits 2" test "$rc" -eq 2

run "" --ide pycharm datagrip
pc="$apps/fedora-toolbox-pycharm.desktop"
check "launcher created" test -f "$pc"
check "launcher name" grep -qx 'Name=PyCharm (toolbox)' "$pc"
check "launcher runs inside the named box" grep -qx "Exec=distrobox enter -n fedora-toolbox -- \"$E/jb/scripts/pycharm\" %F" "$pc"
check "launcher icon comes from the IDE directory, absolute" grep -qx "Icon=$E/jb/apps/PyCharm/ch-0/9.9/bin/pycharm.svg" "$pc"
check "launcher window class" grep -qx 'StartupWMClass=jetbrains-pycharm' "$pc"
check "launcher flags" grep -q '^Terminal=false' "$pc" && check "launcher startup notify" grep -q '^StartupNotify=true' "$pc"
check "second launcher created" test -f "$apps/fedora-toolbox-datagrip.desktop"
check "launchers recorded" instate "launcher $pc"
check "output explains the toolchain" has "use the box's compilers"
check "no versioned directory hardcoded in the recipe" bash -c "! grep -qE 'ch-0|Toolbox/apps/[A-Z]' '$justfile'"
run "" --ide pycharm
check "rerun says already created" has "Already created"
run "" --ide --list
check "ide list shows created" grep -qE '^pycharm +yes +created' "$root/out"

newenv
mkbox
mkdir -p "$apps"
printf 'mine\n' >"$apps/fedora-toolbox-pycharm.desktop"
printf 'theirs\n' >"$apps/jetbrains-pycharm.desktop"
run "" --ide pycharm
check "a foreign file is not overwritten" test "$(cat "$apps/fedora-toolbox-pycharm.desktop")" = mine
check "the skip is explained" has "not created by this recipe"
check "the foreign launcher is not recorded" bash -c "! grep -q 'launcher' '$state' 2>/dev/null"
run "y" --ide --remove
check "remove never deletes unrecorded files" test -e "$apps/fedora-toolbox-pycharm.desktop" -a -e "$apps/jetbrains-pycharm.desktop"

newenv
mkbox
run $'\n' --ide
check "checklist creates the detected launchers" test -f "$apps/fedora-toolbox-pycharm.desktop" -a -f "$apps/fedora-toolbox-datagrip.desktop"
check "checklist skips undetected IDEs" test ! -e "$apps/fedora-toolbox-idea.desktop"
newenv
mkbox
run "q" --ide
check "q skips the IDE checklist" test ! -e "$apps/fedora-toolbox-pycharm.desktop"

newenv
mkbox
printf '#!/bin/sh\n' >"$E/boxbin/code"
chmod +x "$E/boxbin/code"
run "" --ide vscode
check "VS Code found in the box" grep -qx "Exec=distrobox enter -n fedora-toolbox -- \"$E/boxbin/code\" %F" "$apps/fedora-toolbox-vscode.desktop"
check "VS Code window class" grep -qx 'StartupWMClass=Code' "$apps/fedora-toolbox-vscode.desktop"
newenv
mkbox
mkdir -p "$HOME/.local/opt/VSCode-linux-x64/bin" "$HOME/.local/opt/VSCode-linux-x64/resources/app/resources/linux"
printf '#!/bin/sh\n' >"$HOME/.local/opt/VSCode-linux-x64/bin/code"
chmod +x "$HOME/.local/opt/VSCode-linux-x64/bin/code"
printf 'png' >"$HOME/.local/opt/VSCode-linux-x64/resources/app/resources/linux/code.png"
run "" --ide vscode
check "VS Code tarball under the home found" grep -qx "Exec=distrobox enter -n fedora-toolbox -- \"$HOME/.local/opt/VSCode-linux-x64/bin/code\" %F" "$apps/fedora-toolbox-vscode.desktop"
check "VS Code tarball icon used" grep -qx "Icon=$HOME/.local/opt/VSCode-linux-x64/resources/app/resources/linux/code.png" "$apps/fedora-toolbox-vscode.desktop"

newenv
mkbox
mkdir -p "$HOME/bin"
printf '#!/bin/sh\n' >"$HOME/bin/myide"
chmod +x "$HOME/bin/myide"
printf 'x' >"$HOME/bin/myide.png"
run "" --ide-custom "My IDE" "$HOME/bin/myide" "$HOME/bin/myide.png"
check "custom launcher created" grep -qx "Exec=distrobox enter -n fedora-toolbox -- \"$HOME/bin/myide\" %F" "$apps/fedora-toolbox-my-ide.desktop"
check "custom launcher icon and name" bash -c "grep -qx 'Name=My IDE (toolbox)' '$apps/fedora-toolbox-my-ide.desktop' && grep -qx 'Icon=$HOME/bin/myide.png' '$apps/fedora-toolbox-my-ide.desktop'"
check "custom launcher recorded" instate "launcher $apps/fedora-toolbox-my-ide.desktop"
run "" --ide --list
check "ide list shows the custom launcher" grep -qE '^my-ide +custom' "$root/out"
run "" --ide-custom "Bad" /usr/bin/true
check "custom command outside the home is refused" has "absolute path under your home"
check "custom refusal fails" test "$rc" -ne 0
run "" --ide-custom "Only"
check "custom needs a command" test "$rc" -eq 2

newenv
run "" --ide pycharm
check "no box: refuses and does not create it" has "never creates it"
check "no box: no launcher" test ! -e "$apps/fedora-toolbox-pycharm.desktop"
check "no box: nothing assembled" notlogged "assemble "
newenv
mkbox
export FAKE_BOX_STATUS=Exited
run "y" --ide pycharm
check "stopped box: offers to start it" has "not running"
check "stopped box: starts it on y" logged "podman start fedora-toolbox"
check "stopped box: launcher still created" test -f "$apps/fedora-toolbox-pycharm.desktop"
unset FAKE_BOX_STATUS

newenv
mkbox
run "" --ide pycharm datagrip
printf 'mine\n' >"$apps/other.desktop"
run "" --ide --remove --dry-run
check "ide remove dry run lists launchers" has "fedora-toolbox-pycharm.desktop"
check "ide remove dry run removes nothing" test -f "$apps/fedora-toolbox-pycharm.desktop" -a -f "$apps/fedora-toolbox-datagrip.desktop"
run "n" --ide --remove
check "declining keeps launchers" test -f "$apps/fedora-toolbox-pycharm.desktop"
run "y" --ide --remove pycharm
check "named remove deletes only that launcher" bash -c "test ! -e '$apps/fedora-toolbox-pycharm.desktop' && test -f '$apps/fedora-toolbox-datagrip.desktop'"
run "y" --ide --remove
check "remove deletes the rest of the recorded ones" test ! -e "$apps/fedora-toolbox-datagrip.desktop"
check "remove leaves other files" test "$(cat "$apps/other.desktop")" = mine
check "removed launchers leave the state file" bash -c "! grep -q '^launcher ' '$state'"

newenv
run "yyy" sdkman nvm
run "" --ide pycharm
check "launcher exists before the main remove" test -f "$apps/fedora-toolbox-pycharm.desktop"
run "" --remove --dry-run
check "main remove lists the launcher" has "launcher  $apps/fedora-toolbox-pycharm.desktop"
run "yes
" --remove
check "main remove deletes the launcher" test ! -e "$apps/fedora-toolbox-pycharm.desktop"
check "main remove still finishes" test ! -e "$state"

# ---- brew recipe --------------------------------------------------------------------------------------------------
newenv
mkdir -p "$UPM_BREW_PREFIX"
runbrew "y"
check "brew exits 0" test "$rc" -eq 0
check "brew installed" test -x "$UPM_BREW_PREFIX/bin/brew"
check "brew ran non-interactively" logged "installer brew args= nonint=1"
check "brew installer got the sudo stub first" logged "path0=$E/tmp/brew."
check "brew hash printed" has "sha256 "
check "brew shellenv instructions printed" has "brew shellenv"
check "brew undo notes printed" has "To undo"
check "brew mentions the toolbox mount" has "ujust dev-toolbox --recreate"
check "brew leaves rc files alone" test ! -e "$HOME/.bashrc"
check "brew leaves no temp files" bash -c "! ls '$E/tmp'/brew.* >/dev/null 2>&1"
: >"$LOG"
runbrew ""
check "brew rerun is a no-op" has "already installed"
check "brew rerun downloads nothing" notlogged "curl url="

newenv
runbrew "y"
check "brew without prefix exits non-zero" test "$rc" -ne 0
check "brew without prefix downloads nothing" notlogged "curl url="
check "brew prints the one-time commands" has "sudo mkdir -p"
check "brew prints the chown" has "chown -R"

newenv
mkdir -p "$UPM_BREW_PREFIX"
export FAKE_SUDO=1
runbrew "y"
check "brew sudo attempt fails" test "$rc" -ne 0
check "brew sudo stub message" has "sudo is not allowed here"
check "brew sudo explanation" has "wanted sudo"
unset FAKE_SUDO
runbrew "n"
check "brew declining cancels" has "Cancelled"
check "brew declined installs nothing" test ! -e "$UPM_BREW_PREFIX/bin/brew"

echo
echo "$pass passed, $failn failed"
[ "$failn" -eq 0 ]
