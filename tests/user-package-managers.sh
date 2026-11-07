#!/usr/bin/env bash
# Tests for `ujust user-package-managers` (system_files/usr/share/ublue-os/just/60-custom.just).
# No network and nothing real is installed: curl, distrobox and distrobox-export are fakes on PATH,
# keystrokes come from a file through UPM_TTY, and everything runs in a temp dir.
# Needs: bash, just, setpriv (util-linux). Run: tests/user-package-managers.sh
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
justfile="$here/../system_files/usr/share/ublue-os/just/60-custom.just"
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

mkdir -p "$root/fakebin"
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
    *astral*) id=uv ;;
    *Homebrew*) id=brew ;;
    *sdkman*) id=sdkman ;;
    *nvm*) id=nvm ;;
    *rustup*) id=rustup ;;
    *pixi*) id=pixi ;;
    *) exit 1 ;;
esac
case " ${FAKE_CURL_FAIL:-} " in *" $id "*) exit 22 ;; esac
cat >"$out" <<EOS
#!/bin/bash
echo "installer $id args=\$* nonint=\${NONINTERACTIVE:-} path0=\${PATH%%:*}" >>"$LOG"
if [ -n "\${FAKE_SUDO:-}" ]; then sudo true || exit 1; fi
mk() { mkdir -p "\$(dirname "\$1")"; echo x >"\$1"; chmod +x "\$1"; }
case "$id" in
    uv) mk "\$HOME/.local/bin/uv"; mk "\$HOME/.local/bin/uvx" ;;
    brew) mk "\$UPM_BREW_PREFIX/bin/brew" ;;
    sdkman) mk "\$HOME/.sdkman/bin/sdkman-init.sh" ;;
    nvm) mk "\$HOME/.nvm/nvm.sh" ;;
    rustup) mk "\$HOME/.cargo/bin/rustup"; mk "\$HOME/.cargo/bin/cargo"; mk "\$HOME/.cargo/bin/rustc" ;;
    pixi) mk "\$HOME/.pixi/bin/pixi" ;;
esac
EOS
EOF
cat >"$root/fakebin/distrobox" <<'EOF'
#!/bin/bash
case "$1" in
    list) printf 'ID | NAME | STATUS | IMAGE\nabc123 | %s | Up | fedora\n' "${FAKE_BOX:-fedora-toolbox}" ;;
    enter)
        shift 2
        [ "$1" = -- ] && shift
        exec "$@"
        ;;
esac
EOF
cat >"$root/fakebin/distrobox-export" <<'EOF'
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
chmod +x "$root/fakebin"/*

n=0
newenv() { # fresh HOME, temp dir, brew prefix and log
    n=$((n + 1))
    E="$root/e$n"
    mkdir -p "$E/home/.local/bin" "$E/tmp" "$E/brew" "$E/run"
    export HOME="$E/home" TMPDIR="$E/tmp" UPM_BREW_PREFIX="$E/brew" XDG_RUNTIME_DIR="$E/run"
    export LOG="$E/log"
    : >"$LOG"
    unset FAKE_SUDO FAKE_BOX FAKE_CURL_FAIL XDG_STATE_HOME
    export PATH="$root/fakebin:$ORIG_PATH"
    state="$HOME/.local/state/ublue-os/user-package-managers"
}
ORIG_PATH=$PATH
rc=0
run() { # keys, args...
    printf '%s' "$1" >"$root/keys"
    shift
    UPM_TTY="$root/keys" just --justfile "$justfile" user-package-managers "$@" >"$root/out" 2>&1 </dev/null
    rc=$?
}

command -v just >/dev/null || {
    echo "just is required"
    exit 2
}
command -v setpriv >/dev/null || {
    echo "setpriv is required"
    exit 2
}

# 1. --list
newenv
run "" --list
check "--list exits 0" test "$rc" -eq 0
check "--list shows every tool" bash -c "for t in uv brew sdkman nvm rustup pixi; do grep -q \"^\$t \" '$root/out' || exit 1; done"
check "--list shows missing before install" grep -qE '^uv +missing' "$root/out"
mkdir -p "$E/brew/bin" && : >"$E/brew/bin/brew" && chmod +x "$E/brew/bin/brew"
run "" --list
check "--list shows installed brew" grep -qE '^brew +installed' "$root/out"

# 2. unknown tool
run "" nosuchtool
check "unknown tool exits 2" test "$rc" -eq 2

# 3. named install, host and toolbox, exports, flags, sudo stub on PATH
newenv
run "yy" brew rustup
check "install exits 0" test "$rc" -eq 0
check "brew installed" test -x "$E/brew/bin/brew"
check "rustup installed" test -x "$HOME/.cargo/bin/rustup"
check "curl got -fsSL and https only" logged "curl url=https://sh.rustup.rs"
check "installer ran with NONINTERACTIVE=1 for brew" logged "installer brew args= nonint=1"
check "rustup args passed" logged "installer rustup args=-y --no-modify-path"
check "sudo stub is first on PATH" logged "path0=$E/tmp/upm."
check "hash and size printed" has "sha256 "
check "vendor code warning printed" has "vendor code"
check "rustup proxies exported" test -e "$HOME/.local/bin/cargo" -a -e "$HOME/.local/bin/rustc" -a -e "$HOME/.local/bin/rustup"
check "exports recorded in the state file" grep -qxF "$HOME/.local/bin/cargo" "$state"
check "undo note printed" has "To undo"
check "brew shellenv instructions printed" has "brew shellenv"
check "rc files untouched" test ! -e "$HOME/.bashrc"
check "no temp files left" bash -c "! ls '$E/tmp'/upm.* >/dev/null 2>&1"

# 4. rerun is a no-op
: >"$LOG"
run "" rustup brew
check "rerun skips installed tools" has "already installed"
check "rerun runs no installer" notlogged "installer "
check "rerun does not download" notlogged "curl url="
check "rerun reports exports as already there" has "already exported"
run "" --list
check "--list shows rustup exported" grep -qE '^rustup +installed +yes' "$root/out"

# 5. never overwrite an existing file, and the sdk wrapper
newenv
printf 'mine\n' >"$HOME/.local/bin/sdk"
run "y" sdkman
check "existing sdk file is kept" test "$(cat "$HOME/.local/bin/sdk")" = mine
check "skip is reported" has "Skipped $HOME/.local/bin/sdk"
check "skipped file not recorded" bash -c "! grep -qxF '$HOME/.local/bin/sdk' '$state' 2>/dev/null"
newenv
run "y" sdkman
check "sdk wrapper written" test -x "$HOME/.local/bin/sdk"
check "sdk wrapper enters the box" grep -q "distrobox enter fedora-toolbox" "$HOME/.local/bin/sdk"
check "sdk wrapper sources sdkman" grep -q "sdkman-init.sh" "$HOME/.local/bin/sdk"
check "sdk wrapper recorded" grep -qxF "$HOME/.local/bin/sdk" "$state"

# 6. uv installs into ~/.local/bin itself; nothing to export, nothing recorded
newenv
run "y" uv
check "uv installed" test -x "$HOME/.local/bin/uv"
check "uv says nothing to export" has "nothing to export"
check "uv not recorded as an export" bash -c "! grep -q 'uv' '$state' 2>/dev/null"
check "uv installer ran with UV_NO_MODIFY_PATH set (see recipe row)" logged "installer uv"

# 7. nvm exports nothing
newenv
run "y" nvm
check "nvm installed" test -e "$HOME/.nvm/nvm.sh"
check "nvm exported nothing" test ! -e "$state"
check "nvm output says brew's node stays" has "brew's"

# 8. sudo is blocked
newenv
export FAKE_SUDO=1
run "y" rustup
check "sudo attempt fails the install" test "$rc" -ne 0
check "stub message shown" has "sudo is not allowed here"
check "plain explanation shown" has "wanted sudo"
check "nothing installed after sudo attempt" test ! -e "$HOME/.cargo/bin/rustup"
check "no executable sudo in the recipe" bash -c "! sed -n '/^user-package-managers/,\$p' '$justfile' | grep -w sudo | grep -vE '^\s*(echo|printf|#)|grep -qiE|sudo-called|bin/sudo'"

# 9. brew prefix missing: no download, one-time commands printed
newenv
export UPM_BREW_PREFIX="$E/nope/.linuxbrew"
run "y" brew
check "brew without prefix fails" test "$rc" -ne 0
check "no download without prefix" notlogged "curl url="
check "mkdir/chown commands printed" has "sudo mkdir -p"
check "chown printed" has "chown -R"
unset FAKE_SUDO

# 10. toolbox missing
newenv
export FAKE_BOX=other
run "y" nvm
check "missing box is reported" has "does not exist"
check "missing box downloads nothing" notlogged "curl url="
check "missing box fails" test "$rc" -ne 0

# 11. declining, and a failed download
newenv
run "n" pixi
check "declining skips" has "Skipped"
check "declined installer not run" notlogged "installer pixi"
export FAKE_CURL_FAIL=pixi
run "y" pixi
check "failed download reported" has "Download failed"
check "failed download exits non-zero" test "$rc" -ne 0
unset FAKE_CURL_FAIL

# 12. view then run
newenv
export PAGER=cat
run "vy" pixi
check "v shows the installer" has "installer pixi"
check "then y runs it" test -x "$HOME/.pixi/bin/pixi"

# 13. checklist: q cancels
newenv
run "q"
check "q cancels" has "Cancelled"
check "q exits 0" test "$rc" -eq 0
check "q installs nothing" notlogged "installer "

# 14. checklist: defaults on, SPACE toggles the first row (uv) off, ENTER confirms
newenv
run "$(printf ' \nyyyy')"
check "checklist install exits 0" test "$rc" -eq 0
check "uv toggled off" test ! -e "$HOME/.local/bin/uv"
check "pixi is off by default" test ! -e "$HOME/.pixi/bin/pixi"
check "defaults installed" test -x "$E/brew/bin/brew" -a -e "$HOME/.sdkman/bin/sdkman-init.sh" -a -e "$HOME/.nvm/nvm.sh" -a -x "$HOME/.cargo/bin/rustup"

# 15. checklist: move down to pixi and tick it
newenv
run "$(printf 'jjjjj \nyyyyyy')"
check "moving and ticking pixi installs it" test -x "$HOME/.pixi/bin/pixi"
check "all six installed" test -x "$HOME/.local/bin/uv" -a -x "$E/brew/bin/brew" -a -x "$HOME/.cargo/bin/rustup"

# 16. everything installed: checklist says so
run ""
check "nothing to do when all installed" has "already installed"

echo
echo "$pass passed, $failn failed"
[ "$failn" -eq 0 ]
