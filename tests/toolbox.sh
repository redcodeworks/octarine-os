#!/usr/bin/env bash
# Tests for `ujust toolbox <name>` and `ujust brew` (system_files/usr/share/ublue-os/just/60-custom.just).
# No network and nothing real is installed or created: curl, distrobox and distrobox-export are fakes,
# keystrokes come from a file through UPM_TTY, and everything runs in a temp dir with its own HOME.
# Needs: bash, just, setpriv (util-linux). Run: tests/toolbox.sh
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
justfile="$here/../system_files/usr/share/ublue-os/just/60-custom.just"
shipped_dir="$here/../system_files/usr/share/ublue-os/distrobox"
shipped_def="$shipped_dir/dev.ini"
shipped_conf="$shipped_dir/dev.conf"
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
    unset FAKE_SUDO FAKE_CURL_FAIL FAKE_ASSEMBLE_FAIL FAKE_RM_FAIL FAKE_BOX_STATUS TOOLBOX_IMAGE XDG_STATE_HOME XDG_CONFIG_HOME XDG_DATA_HOME
    apps="$HOME/.local/share/applications"
    export UPM_JB_SCRIPTS="$E/jb/scripts"
    mkdir -p "$E/jb/scripts" "$E/jb/apps/PyCharm/ch-0/9.9/bin" "$E/jb/apps/DataGrip/ch-0/9.9/bin"
    for t in pycharm datagrip; do
        case "$t" in pycharm) D=PyCharm ;; *) D=DataGrip ;; esac
        printf '#!/bin/sh\nexec "%s/jb/apps/%s/ch-0/9.9/bin/%s.sh" "$@"\n' "$E" "$D" "$t" >"$E/jb/scripts/$t"
        chmod +x "$E/jb/scripts/$t"
        printf '<svg/>' >"$E/jb/apps/$D/ch-0/9.9/bin/$t.svg"
    done
    mkdir -p "$E/defs"
    cp "$shipped_dir/dev.ini" "$shipped_dir/dev.conf" "$E/defs/"
    printf '[plain]\nimage=example.invalid/plain:latest\nvolume="/home/linuxbrew:/home/linuxbrew:ro"\n' >"$E/defs/plain.ini"
    export TOOLBOX_DEFINITIONS="$E/defs"
    name=dev
    echo old1 >"$FAKE_STATE/cur_id"
    echo old1 >"$FAKE_STATE/new_id"
    echo 44 >"$FAKE_STATE/ver-old1"
    echo 44 >"$FAKE_STATE/ver-new2"
    export PATH="$root/fakebin:$ORIG_PATH"
    state="$HOME/.local/state/ublue-os/toolbox/dev"
    conf="$HOME/.config/distrobox/distrobox.conf"
}
mkbox() { echo dev >"$FAKE_STATE/boxes"; }
rc=0
run() { # keys, args...
    printf '%s' "$1" >"$root/keys"
    shift
    UPM_TTY="$root/keys" just --justfile "$justfile" toolbox "$name" "$@" >"$root/out" 2>&1 </dev/null
    rc=$?
}
runbrew() { # keys
    printf '%s' "$1" >"$root/keys"
    UPM_TTY="$root/keys" just --justfile "$justfile" brew >"$root/out" 2>&1 </dev/null
    rc=$?
}

# ---- the shipped definition ---------------------------------------------------
check "definition has the dev section" grep -qx '\[dev\]' "$shipped_def"
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
check "--list shows the box missing" has "dev (missing)"
check "--list shows the default name unset" has "not set in"
check "--list shows every row" bash -c "for t in uv rustup sdkman nvm bins; do grep -q \"^\$t \" '$root/out' || exit 1; done"
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
check "recreate hint printed" has "ujust toolbox dev --recreate"
check "box recorded" instate "box dev"
check "no-brew-mount recorded" instate "box-no-brew-mount"
check "default name written" grep -qx 'container_name_default="dev"' "$conf"
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
check "sdk wrapper enters the box" grep -q "distrobox enter dev" "$HOME/.local/bin/sdk"
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
check "rerun leaves the default alone" has "already dev"
run "" --list
check "--list shows the box present" has "dev (present)"
check "--list shows the default name" has "Default name:  dev"
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

# ---- definitions directory override ---------------------------------------------------
newenv
mkdir -p "$E/custom"
printf '# custom definition\n[dev]\nimage=example\nvolume="/home/linuxbrew:/home/linuxbrew:ro"\n' >"$E/custom/dev.ini"
export TOOLBOX_DEFINITIONS="$E/custom"
run "yq"
check "TOOLBOX_DEFINITIONS overrides the definitions directory" grep -q 'custom definition' "$FAKE_STATE/assembled.ini"
check "a toolbox without a sidecar gets no checklist" hasnt "Tools in the box"

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
check "declining leaves the box" bash -c "! grep -q '^rm ' '$LOG' && grep -qx dev '$FAKE_STATE/boxes'"


newenv
run "yyy" sdkman nvm
echo new2 >"$FAKE_STATE/new_id"
: >"$LOG"
run "yes
" --upgrade
check "newer base: exit 0" test "$rc" -eq 0
check "newer base: container replaced" bash -c "grep -q '^rm --force dev' '$LOG' && grep -q '^assemble' '$LOG'"
check "newer base: no second confirmation" hasnt "remove and recreate the box"
check "newer base: no tool checklist" hasnt "Tools in the box"
check "newer base: exports made again" test -e "$HOME/.local/bin/gcc"
check "newer base: installs in the shared home survive" test -s "$HOME/.sdkman/bin/sdkman-init.sh" -a -s "$HOME/.nvm/nvm.sh"
check "newer base: no installer re-run" notlogged "installer "

newenv
mkbox
run "" --update
check "update runs distrobox upgrade on the box" logged "upgrade dev"
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
check "accepting changes only that key" bash -c "grep -qx 'container_name_default=\"dev\"' '$conf' && grep -qx 'container_manager=\"podman\"' '$conf'"
check "change recorded with the old value" instate "conf changed other"
newenv
mkbox
mkdir -p "$(dirname "$conf")"
printf 'container_manager="podman"' >"$conf"
run ""
check "missing key is appended on its own line" bash -c "grep -qx 'container_manager=\"podman\"' '$conf' && grep -qx 'container_name_default=\"dev\"' '$conf'"
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
check "upgrade hint for a missing package" has "ujust toolbox dev --upgrade"
check "missing package fails" test "$rc" -ne 0
newenv
mkbox
rm -f "$E/boxbin/rustup-init"
run "" rustup
check "missing rustup-init is reported" has "is not in the box"
check "missing rustup-init fails" test "$rc" -ne 0
check "missing rustup-init points at --upgrade" has "ujust toolbox dev --upgrade"

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

# TOOLBOX_IMAGE overrides the image= line
newenv
export TOOLBOX_IMAGE=ghcr.io/redcodeworks/fedora-toolbox:testing
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
unset TOOLBOX_IMAGE

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
check "recreate removed the container" logged "rm --force dev"
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
check "dry run lists the container" has "container dev"
check "dry run lists created directories" bash -c "grep -q 'directory $HOME/.sdkman' '$root/out' && grep -q 'directory $HOME/.nvm' '$root/out' && grep -q 'directory $HOME/.rustup' '$root/out'"
check "dry run lists the setting and the state file" bash -c "grep -q 'setting   container_name_default' '$root/out' && grep -q 'state     $state' '$root/out'"
check "dry run names the skipped pre-existing dir and why" has "$HOME/.cargo (already existed before this recipe, left alone)"
check "dry run says nothing was removed" has "Dry run: nothing was removed"
check "dry run changed nothing" bash -c "test -e '$HOME/.local/bin/gcc' -a -d '$HOME/.sdkman' -a -d '$HOME/.rustup' -a -f '$state' -a -f '$conf' && grep -qx dev '$FAKE_STATE/boxes'"
check "dry run never called distrobox rm" notlogged "rm "
run "no
" --remove
check "declining the prompt exits 0" test "$rc" -eq 0
check "declining says nothing was removed" has "Nothing was removed"
check "warning about ~/.cargo and ~/.sdkman shown" has "cargo install binaries"
check "declining changed nothing" bash -c "test -e '$HOME/.local/bin/gcc' -a -d '$HOME/.sdkman' -a -f '$state' && grep -qx dev '$FAKE_STATE/boxes'"
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
check "rerun removed the container" bash -c "! grep -qx dev '$FAKE_STATE/boxes'"
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
pc="$apps/dev-pycharm.desktop"
check "launcher created" test -f "$pc"
check "launcher name" grep -qx 'Name=PyCharm (toolbox)' "$pc"
check "launcher runs inside the named box" grep -qx "Exec=distrobox enter -n dev -- \"$E/jb/scripts/pycharm\" %F" "$pc"
check "launcher icon comes from the IDE directory, absolute" grep -qx "Icon=$E/jb/apps/PyCharm/ch-0/9.9/bin/pycharm.svg" "$pc"
check "launcher window class" grep -qx 'StartupWMClass=jetbrains-pycharm' "$pc"
check "launcher flags" grep -q '^Terminal=false' "$pc" && check "launcher startup notify" grep -q '^StartupNotify=true' "$pc"
check "second launcher created" test -f "$apps/dev-datagrip.desktop"
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
printf 'mine\n' >"$apps/dev-pycharm.desktop"
printf 'theirs\n' >"$apps/jetbrains-pycharm.desktop"
run "" --ide pycharm
check "a foreign file is not overwritten" test "$(cat "$apps/dev-pycharm.desktop")" = mine
check "the skip is explained" has "not created by this recipe"
check "the foreign launcher is not recorded" bash -c "! grep -q 'launcher' '$state' 2>/dev/null"
run "y" --ide --remove
check "remove never deletes unrecorded files" test -e "$apps/dev-pycharm.desktop" -a -e "$apps/jetbrains-pycharm.desktop"

newenv
mkbox
run $'\n' --ide
check "checklist creates the detected launchers" test -f "$apps/dev-pycharm.desktop" -a -f "$apps/dev-datagrip.desktop"
check "checklist skips undetected IDEs" test ! -e "$apps/dev-idea.desktop"
newenv
mkbox
run "q" --ide
check "q skips the IDE checklist" test ! -e "$apps/dev-pycharm.desktop"

newenv
mkbox
printf '#!/bin/sh\n' >"$E/boxbin/code"
chmod +x "$E/boxbin/code"
run "" --ide vscode
check "VS Code found in the box" grep -qx "Exec=distrobox enter -n dev -- \"$E/boxbin/code\" %F" "$apps/dev-vscode.desktop"
check "VS Code window class" grep -qx 'StartupWMClass=Code' "$apps/dev-vscode.desktop"
newenv
mkbox
mkdir -p "$HOME/.local/opt/VSCode-linux-x64/bin" "$HOME/.local/opt/VSCode-linux-x64/resources/app/resources/linux"
printf '#!/bin/sh\n' >"$HOME/.local/opt/VSCode-linux-x64/bin/code"
chmod +x "$HOME/.local/opt/VSCode-linux-x64/bin/code"
printf 'png' >"$HOME/.local/opt/VSCode-linux-x64/resources/app/resources/linux/code.png"
run "" --ide vscode
check "VS Code tarball under the home found" grep -qx "Exec=distrobox enter -n dev -- \"$HOME/.local/opt/VSCode-linux-x64/bin/code\" %F" "$apps/dev-vscode.desktop"
check "VS Code tarball icon used" grep -qx "Icon=$HOME/.local/opt/VSCode-linux-x64/resources/app/resources/linux/code.png" "$apps/dev-vscode.desktop"

newenv
mkbox
mkdir -p "$HOME/bin"
printf '#!/bin/sh\n' >"$HOME/bin/myide"
chmod +x "$HOME/bin/myide"
printf 'x' >"$HOME/bin/myide.png"
run "" --ide-custom "My IDE" "$HOME/bin/myide" "$HOME/bin/myide.png"
check "custom launcher created" grep -qx "Exec=distrobox enter -n dev -- \"$HOME/bin/myide\" %F" "$apps/dev-my-ide.desktop"
check "custom launcher icon and name" bash -c "grep -qx 'Name=My IDE (toolbox)' '$apps/dev-my-ide.desktop' && grep -qx 'Icon=$HOME/bin/myide.png' '$apps/dev-my-ide.desktop'"
check "custom launcher recorded" instate "launcher $apps/dev-my-ide.desktop"
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
check "no box: no launcher" test ! -e "$apps/dev-pycharm.desktop"
check "no box: nothing assembled" notlogged "assemble "
newenv
mkbox
export FAKE_BOX_STATUS=Exited
run "y" --ide pycharm
check "stopped box: offers to start it" has "not running"
check "stopped box: starts it on y" logged "podman start dev"
check "stopped box: launcher still created" test -f "$apps/dev-pycharm.desktop"
unset FAKE_BOX_STATUS

newenv
mkbox
run "" --ide pycharm datagrip
printf 'mine\n' >"$apps/other.desktop"
run "" --ide --remove --dry-run
check "ide remove dry run lists launchers" has "dev-pycharm.desktop"
check "ide remove dry run removes nothing" test -f "$apps/dev-pycharm.desktop" -a -f "$apps/dev-datagrip.desktop"
run "n" --ide --remove
check "declining keeps launchers" test -f "$apps/dev-pycharm.desktop"
run "y" --ide --remove pycharm
check "named remove deletes only that launcher" bash -c "test ! -e '$apps/dev-pycharm.desktop' && test -f '$apps/dev-datagrip.desktop'"
run "y" --ide --remove
check "remove deletes the rest of the recorded ones" test ! -e "$apps/dev-datagrip.desktop"
check "remove leaves other files" test "$(cat "$apps/other.desktop")" = mine
check "removed launchers leave the state file" bash -c "! grep -q '^launcher ' '$state'"

newenv
run "yyy" sdkman nvm
run "" --ide pycharm
check "launcher exists before the main remove" test -f "$apps/dev-pycharm.desktop"
run "" --remove --dry-run
check "main remove lists the launcher" has "launcher  $apps/dev-pycharm.desktop"
run "yes
" --remove
check "main remove deletes the launcher" test ! -e "$apps/dev-pycharm.desktop"
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
check "brew mentions the toolbox mount" has "ujust toolbox dev --recreate"
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

# ---- the toolbox scope: list, unknown names, a toolbox without a sidecar --------------------------
rawrun() { # args (no name, no keys)
    just --justfile "$justfile" toolbox "$@" >"$root/out" 2>&1 </dev/null
    rc=$?
}
newenv
rawrun
check "no name lists the toolboxes" test "$rc" -eq 0
check "list shows dev and plain" bash -c "grep -qE '^dev +missing' '$root/out' && grep -qE '^plain +missing' '$root/out'"
check "list shows the image references" bash -c "grep -q 'ghcr.io/redcodeworks/fedora-toolbox:latest' '$root/out' && grep -q 'example.invalid/plain:latest' '$root/out'"
check "list says how to run each" has "ujust toolbox <name>"
mkbox
rawrun
check "list shows a running box" grep -qE '^dev +running' "$root/out"
FAKE_BOX_STATUS="Exited (0) 2 hours ago" rawrun
check "list shows a stopped box" grep -qE '^dev +stopped' "$root/out"
mkdir -p "$(dirname "$conf")"
printf 'container_name_default="dev"\n' >"$conf"
rawrun
check "list marks the default" grep -qE '^dev +running +yes' "$root/out"
check "list: only the default is marked" grep -qE '^plain +missing +-' "$root/out"
rawrun --list
check "--list without a name is the list too" has "Toolboxes defined in"
rawrun --remove
check "an option without a name exits 2" test "$rc" -eq 2
rawrun nosuch
check "unknown name exits 2" test "$rc" -eq 2
check "unknown name lists the known ones" has "Known toolboxes: dev plain"
rawrun ../dev
check "a name with a path is refused" test "$rc" -eq 2
rawrun nosuch --remove
check "unknown name with an option exits 2" test "$rc" -eq 2
rawrun dev --help
check "--help lists the IDEs of the toolbox" has "IDEs offered by dev: pycharm idea datagrip rustrover clion goland webstorm vscode"
check "--help lists the tools of the toolbox" has "Tools offered by dev: uv rustup sdkman nvm"
check "the old dev-toolbox recipe is gone" bash -c "! just --justfile '$justfile' --summary | tr ' ' '\\n' | grep -qx dev-toolbox"

newenv
name=plain
run "y"
check "plain toolbox is created" test "$rc" -eq 0
check "plain box assembled as [plain]" grep -qx '\[plain\]' "$FAKE_STATE/assembled.ini"
check "plain gets no tool checklist" hasnt "Tools in the box"
check "plain gets no vendor installer banner" hasnt "vendor scripts"
check "plain exports nothing" bash -c "! grep -q '^export ' '$HOME/.local/state/ublue-os/toolbox/plain'"
check "plain exports no gcc" test ! -e "$HOME/.local/bin/gcc"
check "plain state is its own file" test -f "$HOME/.local/state/ublue-os/toolbox/plain"
check "plain became the default (key was unset)" grep -qx 'container_name_default="plain"' "$conf"
run "" sdkman
check "a tool the sidecar does not offer is unknown" test "$rc" -eq 2
run "" --ide
check "plain offers no IDE launchers" test "$rc" -eq 1
check "plain says why" has "offers no IDE launchers"
run "" --list
check "--list of plain shows its image" has "Image:         example.invalid/plain:latest"

# ---- the sidecar is data, not code --------------------------------------------------------------
newenv
printf '[evil]\nimage=example.invalid/evil:latest\n' >"$E/defs/evil.ini"
printf 'TOOLS="uv; touch %s/pwned1"\nEXPORT_BINS=$(touch %s/pwned2)\nIDES="pycharm nosuchide"\n' "$E" "$E" >"$E/defs/evil.conf"
name=evil
run "" --list
check "unsafe TOOLS is ignored with a warning" has "Ignoring TOOLS"
check "unsafe EXPORT_BINS is ignored with a warning" has "Ignoring EXPORT_BINS"
check "the sidecar was not executed" test ! -e "$E/pwned1" -a ! -e "$E/pwned2"
check "unknown IDE in the sidecar is reported" has "Ignoring unknown IDE 'nosuchide'"
printf 'TOOLS="uv bogus"\n' >"$E/defs/evil.conf"
run "" --list
check "unknown tool in the sidecar is reported" has "Ignoring unknown tool 'bogus'"
check "known tools of the sidecar still show" grep -qE '^uv ' "$root/out"
check "tools not in the sidecar do not show" bash -c "! grep -qE '^(sdkman|nvm) ' '$root/out'"
name=dev

# ---- state per toolbox and --remove isolation -----------------------------------------------------
newenv
run "yyy" sdkman nvm
check "dev state is dev's own file" test -f "$HOME/.local/state/ublue-os/toolbox/dev"
name=plain
run "yn"
check "another default value asks first" has "currently set to 'dev'"
check "declining keeps the other default" grep -qx 'container_name_default="dev"' "$conf"
check "plain state exists next to dev's" test -f "$HOME/.local/state/ublue-os/toolbox/plain"
check "plain state records no dev exports" bash -c "! grep -q '^export ' '$HOME/.local/state/ublue-os/toolbox/plain'"
check "both boxes exist" bash -c "grep -qx dev '$FAKE_STATE/boxes' && grep -qx plain '$FAKE_STATE/boxes'"
before=$(cat "$HOME/.local/state/ublue-os/toolbox/dev")
run "yes
" --remove
check "removing plain succeeds" test "$rc" -eq 0
check "plain box removed" bash -c "grep -qx dev '$FAKE_STATE/boxes' && ! grep -qx plain '$FAKE_STATE/boxes'"
check "plain removal logs only plain" bash -c "grep -q '^rm --force plain' '$LOG' && ! grep -q '^rm --force dev' '$LOG'"
check "plain state file removed" test ! -e "$HOME/.local/state/ublue-os/toolbox/plain"
check "dev state untouched by plain's removal" test "$(cat "$HOME/.local/state/ublue-os/toolbox/dev")" = "$before"
check "dev exports survive plain's removal" test -e "$HOME/.local/bin/gcc" -a -e "$HOME/.local/bin/sdk"
check "dev's directories survive" test -d "$HOME/.sdkman" -a -d "$HOME/.nvm"
check "the default pointing at dev is left alone" grep -qx 'container_name_default="dev"' "$conf"
name=dev

# ---- shared directories across toolboxes ------------------------------------------------------------
newenv
printf '[second]\nimage=example.invalid/second:latest\n' >"$E/defs/second.ini"
printf 'TOOLS="sdkman"\n' >"$E/defs/second.conf"
run "yyy" sdkman
check "dev created ~/.sdkman" instate "dir $HOME/.sdkman created"
name=second
run "yn" sdkman
check "second finds sdkman installed" has "Already installed"
check "second records the shared directory as existing" grep -qxF "dir $HOME/.sdkman existed" "$HOME/.local/state/ublue-os/toolbox/second"
name=dev
run "" --remove --dry-run
check "dry run says second also uses ~/.sdkman" has "second also uses it"
check "dry run does not offer to delete ~/.sdkman" bash -c "! grep -q 'directory $HOME/.sdkman' '$root/out'"
run "yes
" --remove
check "removing dev keeps the shared directory" test -d "$HOME/.sdkman"
check "ownership passed to second" grep -qxF "dir $HOME/.sdkman created" "$HOME/.local/state/ublue-os/toolbox/second"
check "dev's state is gone" test ! -e "$state"
name=second
run "yes
" --remove
check "removing the last user deletes the shared directory" test ! -e "$HOME/.sdkman"
name=dev
# the other order: the borrower goes first, the creator keeps ownership
newenv
printf '[second]\nimage=example.invalid/second:latest\n' >"$E/defs/second.ini"
printf 'TOOLS="sdkman"\n' >"$E/defs/second.conf"
run "yyy" sdkman
name=second
run "yn" sdkman
run "yes
" --remove
check "removing the borrower keeps the directory" test -d "$HOME/.sdkman"
name=dev
run "yes
" --remove
check "removing the creator then deletes it" test ! -e "$HOME/.sdkman"

# ---- --set-default ------------------------------------------------------------------------------------
newenv
mkbox
run "" --set-default
check "--set-default with no key sets it" grep -qx 'container_name_default="dev"' "$conf"
check "--set-default records the creation" instate "conf created"
run "" --set-default
check "--set-default when already set says so" has "already dev"
printf 'container_name_default="other"\n' >"$conf"
rm -f "$state"
run "n" --set-default
check "--set-default shows the current value" has "currently set to 'other'"
check "--set-default declined changes nothing" grep -qx 'container_name_default="other"' "$conf"
run "y" --set-default
check "--set-default changes it after y" grep -qx 'container_name_default="dev"' "$conf"
check "--set-default records the old value" instate "conf changed other"
check "--set-default needs no recreate" bash -c "! grep -q '^rm ' '$LOG' && ! grep -q '^assemble' '$LOG'"
run "" --set-default --remove
check "--set-default does not combine with --remove" test "$rc" -eq 2
run "" --set-default uv
check "--set-default does not combine with tool names" test "$rc" -eq 2
run "yes
" --remove
check "removing restores the old default" grep -qx 'container_name_default="other"' "$conf"

# ---- environment overrides ------------------------------------------------------------------------------
newenv
export TOOLBOX_IMAGE=example.invalid/other:tag
rawrun
check "list shows definition images, not the override" has "ghcr.io/redcodeworks/fedora-toolbox:latest"
run "y" sdkman
check "TOOLBOX_IMAGE applies to the named toolbox" grep -qx 'image=example.invalid/other:tag' "$FAKE_STATE/assembled.ini"
unset TOOLBOX_IMAGE

echo
echo "$pass passed, $failn failed"
[ "$failn" -eq 0 ]
