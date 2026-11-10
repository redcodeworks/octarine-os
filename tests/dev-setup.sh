#!/usr/bin/env bash
# Tests for `ujust dev` (variants/dx/system_files/usr/share/ublue-os/just/70-octarine-dev.just), the sdk wrapper, the
# shell snippets and the dx-only wiring. Every external tool is a stub on a restricted PATH (brew, flatpak, rustup,
# fnm, uv, virsh, systemctl, sudo, id, getent, gum, the sdk wrapper); HOME is a temp dir; nothing real is touched.
# Needs: bash, just (zsh and fish are used for syntax checks when present). Run: tests/dev-setup.sh
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$here/..
dxfs="$repo/variants/dx/system_files"
justfile="$dxfs/usr/share/ublue-os/just/70-octarine-dev.just"
wrapper="$dxfs/usr/bin/sdk"
root=$(mktemp -d)
trap 'rm -rf -- "$root"' EXIT
pass=0
failn=0
bin="$root/bin"        # stubs that are always on PATH
sysbin="$root/sysbin"  # the few real commands
pbin="$root/state/pbin" # tools a stub brew "installs" (on PATH only once installed)
mkdir -p "$bin" "$sysbin"
export LOG="$root/log" HOME="$root/home" STATE="$root/state" GUMQ="$root/gumq"
export OCTARINE_MENU_LIB="$repo/system_files/usr/share/octarine-os/lib/menu.sh"
export OCTARINE_SDK_WRAPPER="$bin/sdkstub" DEV_RETRY_WAIT=0 DEV_ETC_GROUP="$root/etc-group" DEV_USR_GROUP="$root/usr-group"
export DEV_LIBVIRT_NET_XML="$root/net-default.xml"
export DEV_NVIDIA_SYSFS="$root/no-nvidia-module" DEV_CDI_DIRS="$root/cdi"
unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME XDG_STATE_HOME OCTARINE_MENU_FORCE_TTY CARGO_HOME UV_PYTHON_INSTALL_DIR DEV_PYTHONS DEV_RETRIES
REAL_JUST=$(command -v just)
for c in bash sh env cat grep awk sed cut tr date cmp diff mktemp mv rm cp mkdir head tail sort dirname basename wc chmod printf ls touch tee readlink sleep ln rmdir find uniq; do
    p=$(command -v "$c") && ln -sf "$p" "$sysbin/$c"
done

# ---- stubs. State lives in $STATE: formulae/, casks/, flatpaks/, components, fnm-list, uvlist, groups, members, sockets/, net, sdklist
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
cat >"$bin/sudo" <<'F'
#!/usr/bin/env bash
echo "sudo $*" >>"$LOG"
exit "${SUDO_RC:-0}"
F
cat >"$bin/id" <<'F'
#!/usr/bin/env bash
case "$1" in
    -u) echo "${FAKE_UID:-1000}" ;;
    -un) echo tester ;;
    -nG) cat "$STATE/groups" 2>/dev/null || echo "tester wheel" ;;
esac
F
cat >"$bin/getent" <<'F'
#!/usr/bin/env bash
[ "$1" = group ] && [ "$2" = libvirt ] && echo "libvirt:x:970:$(cat "$STATE/members" 2>/dev/null)"
exit 0
F
cat >"$bin/systemctl" <<'F'
#!/usr/bin/env bash
echo "systemctl $*" >>"$LOG"
if [ "$1" = is-enabled ]; then
    u=${@: -1}; [ -f "$STATE/sockets/${u%.socket}" ] && exit 0
    exit 1
fi
exit 0
F
cat >"$bin/virsh" <<'F'
#!/usr/bin/env bash
echo "virsh $*" >>"$LOG"
case "$3" in
    net-info)
        case "$(cat "$STATE/net" 2>/dev/null)" in
            autostart) printf 'Name: default\nActive: yes\nAutostart: yes\n' ;;
            noautostart) printf 'Name: default\nActive: yes\nAutostart: no\n' ;;
            down) echo "error: failed to connect to the hypervisor" >&2; exit 1 ;;
            *) echo "error: Network not found: no network with matching name 'default'" >&2; exit 1 ;;
        esac
        ;;
esac
exit 0
F
cat >"$bin/brew" <<'F'
#!/usr/bin/env bash
echo "brew $*" >>"$LOG"
name_of() { local n=${1##*/}; echo "$n"; }
case "$1" in
    --prefix) echo "$STATE/brewprefix" ;;
    list)
        case "$2" in
            --formula) [ -f "$STATE/formulae/$(name_of "$3")" ]; exit $? ;;
            --cask) [ -f "$STATE/casks/$(name_of "$3")" ]; exit $? ;;
            --pinned) cat "$STATE/pinned" 2>/dev/null; exit 0 ;;
        esac
        ;;
    install)
        shift; kind=formulae
        if [ "$1" = --cask ]; then kind=casks; shift; fi
        n=$(name_of "$1")
        if [ -f "$STATE/fail-$n" ]; then exit 1; fi
        if [ -f "$STATE/failn-$n" ]; then
            left=$(cat "$STATE/failn-$n"); if [ "$left" -gt 0 ]; then echo $((left - 1)) >"$STATE/failn-$n"; exit 1; fi
        fi
        mkdir -p "$STATE/$kind" "$STATE/pbin"; : >"$STATE/$kind/$n"
        [ -x "$STATE/stubs/$n" ] && cp "$STATE/stubs/$n" "$STATE/pbin/$n"
        if [ "$n" = jetbrains-toolbox ]; then
            mkdir -p "$STATE/brewprefix/Caskroom/jetbrains-toolbox/9.9/jetbrains-toolbox-9.9/bin"
            echo png >"$STATE/brewprefix/Caskroom/jetbrains-toolbox/9.9/jetbrains-toolbox-9.9/bin/toolbox.png"
        fi
        ;;
    uninstall) shift; [ "$1" = --cask ] && { shift; rm -f "$STATE/casks/$1"; } ;;
    pin) echo "${2##*/}" >>"$STATE/pinned" ;;
esac
exit 0
F
cat >"$bin/flatpak" <<'F'
#!/usr/bin/env bash
echo "flatpak $*" >>"$LOG"
case "$1" in
    info) [ -f "$STATE/flatpaks/${@: -1}" ]; exit $? ;;
    install)
        [ -f "$STATE/fail-flatpak" ] && exit 1
        if [ -f "$STATE/failn-flatpak" ]; then left=$(cat "$STATE/failn-flatpak"); if [ "$left" -gt 0 ]; then echo $((left - 1)) >"$STATE/failn-flatpak"; exit 1; fi; fi
        mkdir -p "$STATE/flatpaks"; : >"$STATE/flatpaks/${@: -1}"
        ;;
esac
exit 0
F
cat >"$bin/rustup-init" <<'F'
#!/usr/bin/env bash
echo "rustup-init $*" >>"$LOG"
[ -f "$STATE/fail-rustup-init" ] && exit 1
mkdir -p "$HOME/.cargo/bin"
cp "$STATE/stubs/rustup" "$HOME/.cargo/bin/rustup"
printf 'cargo\nclippy\nrustc\nrustfmt\nrust-std\nrust-docs\n' >"$STATE/components"
F
cat >"$bin/uv" <<'F'
#!/usr/bin/env bash
echo "uv $*" >>"$LOG"
[ "$1 $2" = "python list" ] && { cat "$STATE/uvlist" 2>/dev/null; exit 0; }
if [ "$1 $2" = "python install" ]; then
    [ -f "$STATE/fail-uv" ] && exit 1
    shift 2
    for v in "$@"; do echo "cpython-$v.1-linux-x86_64-gnu    $HOME/.local/share/uv/python/cpython-$v.1/bin/python$v" >>"$STATE/uvlist"; done
fi
exit 0
F
# nvidia-smi: a driver exists only when $STATE/nvidia does
cat >"$bin/nvidia-smi" <<'F'
#!/usr/bin/env bash
[ -f "$STATE/nvidia" ] || exit 9
echo "GPU 0: Stub (UUID: GPU-0)"
F
# distrobox: list, create, enter (the in-container scripts are recognized by their text), rm
cat >"$bin/distrobox" <<'F'
#!/usr/bin/env bash
echo "distrobox $*" >>"$LOG"
flagged() { # name: fail-<name> always, failn-<name> that many times
    [ -f "$STATE/fail-$1" ] && return 0
    if [ -f "$STATE/failn-$1" ]; then left=$(cat "$STATE/failn-$1"); if [ "$left" -gt 0 ]; then echo $((left - 1)) >"$STATE/failn-$1"; return 0; fi; fi
    return 1
}
case "$1" in
    list)
        echo "ID           | NAME                 | STATUS          | IMAGE"
        [ -f "$STATE/cuda-container" ] && echo "0123456789ab | cuda                 | Up 2 minutes    | $(cat "$STATE/cuda-container")"
        exit 0
        ;;
    create)
        flagged create && exit 1
        img=""; while [ $# -gt 0 ]; do [ "$1" = --image ] && img=$2; shift; done
        echo "$img" >"$STATE/cuda-container"
        exit 0
        ;;
    enter)
        while [ "$1" != -- ] && [ $# -gt 0 ]; do shift; done; shift
        cmd="$*"
        echo "in-container: $cmd" >>"$LOG"
        case "$cmd" in
            *"tee /etc/profile.d/cuda.sh"*) flagged profile && exit 1; : >"$STATE/cuda-profile" ;;
            *"test -f /etc/profile.d/cuda.sh"*) [ -f "$STATE/cuda-profile" ]; exit $? ;;
            *"nvcc"*) [ -f "$STATE/cuda-toolkit" ]; exit $? ;;
            *"dnf5 -y install"*) flagged install && exit 1; : >"$STATE/cuda-toolkit" ;;
            *addrepo*) flagged repo && exit 1; : >"$STATE/cuda-repo" ;;
            *"nvidia-smi"*) [ -f "$STATE/fail-smi" ] && exit 1; echo "GPU 0: Stub" ;;
        esac
        exit 0
        ;;
    rm) rm -f "$STATE/cuda-container"; exit 0 ;;
esac
exit 0
F
# the stub sdk wrapper: handles --octarine-relink, list java, install java ID, default java ID
cat >"$bin/sdkstub" <<'F'
#!/usr/bin/env bash
echo "sdk $* (stdin: $(cat 2>/dev/null | tr '\n' ' '))" >>"$LOG"
j="$HOME/.sdkman/candidates/java"
case "$1" in
    --octarine-relink) [ -f "$STATE/fail-relink" ] && { echo "sdk: cannot link" >&2; exit 1; }; echo "SDKMAN_DIR=$HOME/.sdkman"; exit 0 ;;
    list) [ -f "$STATE/fail-sdklist" ] && { echo "curl: (6) Could not resolve host" >&2; exit 1; }; cat "$STATE/sdklist"; exit 0 ;;
    install) [ -f "$STATE/fail-java-$3" ] && exit 1; mkdir -p "$j/$3"; exit 0 ;;
    default) ln -sfn "$j/$3" "$j/current"; exit 0 ;;
esac
F
# stubs that "brew install" puts on PATH
mkdir -p "$STATE/stubs"
cat >"$STATE/stubs/fnm" <<'F'
#!/usr/bin/env bash
echo "fnm $*" >>"$LOG"
case "$1" in
    list) cat "$STATE/fnm-list" 2>/dev/null ;;
    install) echo "* v24.0.0 default" >"$STATE/fnm-list" ;;
    default) ;;
    env)
        echo "fnm-env" >>"$STATE/fnm-env-count"
        mkdir -p "$STATE/multishell"
        printf 'export FNM_MULTISHELL_PATH=%s\nexport OCT_FNM_LOADED=1\n' "$STATE/multishell"
        ;;
esac
F
cat >"$STATE/stubs/rustup" <<'F'
#!/usr/bin/env bash
echo "rustup $*" >>"$LOG"
case "$1 $2" in
    "show active-toolchain") echo "stable-x86_64-unknown-linux-gnu (default)" ;;
    "component list") cat "$STATE/components" 2>/dev/null ;;
    "component add") shift 2; [ -f "$STATE/fail-component" ] && exit 1; printf '%s\n' "$@" >>"$STATE/components" ;;
esac
exit 0
F
cat >"$STATE/stubs/jetbrains-toolbox" <<'F'
#!/bin/sh
exit 0
F
chmod +x "$bin"/* "$STATE/stubs"/*

mk_sdklist() {
    cat >"$STATE/sdklist" <<'F'
================================================================================
Available Java Versions for Linux 64bit
================================================================================
 Vendor        | Use | Version      | Dist    | Status     | Identifier
--------------------------------------------------------------------------------
 Azul Zulu     |     | 25.0.4       | zulu    |            | 25.0.4-zulu
               |     | 25.0.4.fx    | zulu    |            | 25.0.4.fx-zulu
               |     | 24.0.2       | zulu    |            | 24.0.2-zulu
               |     | 21.0.12      | zulu    |            | 21.0.12-zulu
               |     | 21.0.12      | zulufx  |            | 21.0.12.fx-zulufx
               |     | 21.0.11      | zulu    |            | 21.0.11-zulu
               |     | 21.0.8.crac  | zulu    |            | 21.0.8.crac-zulu
               |     | 17.0.20      | zulu    |            | 17.0.20-zulu
               |     | 17.0.19      | zulu    |            | 17.0.19-zulu
               |     | 11.0.32      | zulu    |            | 11.0.32-zulu
               |     | 8.0.504      | zulu    |            | 8.0.504-zulu
 Temurin       |     | 21.0.12      | tem     |            | 21.0.12-tem
 Oracle        |     | 21.0.12      | oracle  |            | 21.0.12-oracle
================================================================================
F
}
mk_netxml() { echo '<network><name>default</name></network>' >"$root/net-default.xml"; }

reset() {
    rm -rf "$HOME" "$STATE/formulae" "$STATE/casks" "$STATE/flatpaks" "$STATE/pbin" "$STATE/sockets" "$STATE/brewprefix" "$root"/gumq.* "$LOG"
    rm -rf "$root/cdi"; rm -f "$STATE"/nvidia "$STATE"/cuda-container "$STATE"/cuda-toolkit "$STATE"/cuda-profile "$STATE"/cuda-repo
    rm -f "$STATE"/fail-* "$STATE"/failn-* "$STATE"/components "$STATE"/fnm-list "$STATE"/fnm-env-count "$STATE"/uvlist "$STATE"/groups "$STATE"/members "$STATE"/net "$STATE"/pinned
    unset OCTARINE_MENU_FORCE_TTY GUM_CONFIRM_RC SUDO_RC
    mkdir -p "$HOME" "$STATE/formulae" "$STATE/casks" "$STATE/flatpaks" "$STATE/pbin" "$STATE/sockets" "$STATE/brewprefix" "$STATE/multishell"
    : >"$LOG"
    mk_sdklist
    mk_netxml
    printf 'libvirt:x:970:\n' >"$root/usr-group"
    printf 'root:x:0:\n' >"$root/etc-group"
    export PATH_BIN="$pbin:$bin"
}
# the world of a machine that already has everything
installed_world() {
    local f
    for f in helix ruff ty sqlfluff prettier typescript-language-server vscode-langservers-extracted yaml-language-server marksman jdtls google-java-format lua-language-server stylua taplo sql-language-server gh fnm sdkman-cli; do : >"$STATE/formulae/$f"; done
    cp "$STATE/stubs/fnm" "$pbin/fnm"
    echo "sdkman-cli" >"$STATE/pinned"
    : >"$STATE/casks/jetbrains-toolbox"
    : >"$STATE/flatpaks/com.visualstudio.code"
    mkdir -p "$HOME/.cargo/bin" "$HOME/.sdkman/candidates/java" "$HOME/.config/libvirt" "$HOME/.local/share/applications" "$HOME/.local/share/icons/hicolor/256x256/apps"
    cp "$STATE/stubs/rustup" "$HOME/.cargo/bin/rustup"
    printf 'cargo\nrust-analyzer\nrust-src\n' >"$STATE/components"
    for v in 8.0.504 11.0.32 17.0.20 21.0.12 25.0.4; do mkdir -p "$HOME/.sdkman/candidates/java/$v-zulu"; done
    ln -sfn "$HOME/.sdkman/candidates/java/21.0.12-zulu" "$HOME/.sdkman/candidates/java/current"
    echo "* v24.0.0 default" >"$STATE/fnm-list"
    for v in 3.12 3.13 3.14; do echo "cpython-$v.1-linux-x86_64-gnu    $HOME/.local/share/uv/python/cpython-$v.1/bin/python$v" >>"$STATE/uvlist"; done
    printf '# octarineOS (ujust dev): use the system libvirt by default, so virsh and virt-manager see the same VMs.\nuri_default = "qemu:///system"\n' >"$HOME/.config/libvirt/libvirt.conf"
    printf 'tester wheel libvirt\n' >"$STATE/groups"; echo tester >"$STATE/members"
    : >"$STATE/sockets/virtqemud"; : >"$STATE/sockets/virtnetworkd"; : >"$STATE/sockets/virtstoraged"
    echo autostart >"$STATE/net"
}
run() { # stdin text, args...
    local input=$1
    shift
    printf '%b' "$input" | PATH="$PATH_BIN:$sysbin" "$REAL_JUST" --justfile "$justfile" --working-directory "$root" dev "$@" >"$root/out" 2>&1
    rc=$?
}
gumq() { printf '%b' "$2" >"$root/gumq.$1"; }
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { failn=$((failn + 1)); echo "FAIL $1"; sed 's/^/     /' "$root/out" 2>/dev/null | tail -40; }
check() { local d=$1; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
has() { grep -qF -- "$1" "$root/out"; }
hasnt() { ! grep -qF -- "$1" "$root/out"; }
logged() { grep -qF -- "$1" "$LOG"; }
notlogged() { ! grep -qF -- "$1" "$LOG"; }
row() { grep -qE "^$1 +$2" "$root/out"; }  # summary row: step, result prefix

# ---- the file, the steps and the help
check "recipe file parses and lists exactly one public recipe, dev, in group Developer" bash -c "'$REAL_JUST' --justfile '$justfile' --list | grep -q 'dev ' && [ \$('$REAL_JUST' --justfile '$justfile' --summary) = dev ] && '$REAL_JUST' --justfile '$justfile' --dump | grep -q \"group('Developer')\""
reset
run '' --help
check "--help: usage, exit 0, every step named" bash -c "[ $rc = 0 ] && for s in libvirt tools vscode jetbrains rust java node python; do grep -q \"^  *\$s \" '$root/out' || exit 1; done"
run '' -h
check "-h works too" test "$rc" = 0
run '' help
check "help works too" test "$rc" = 0
run '' --bogus
check "unknown option: exit 2" test "$rc" = 2
run '' --only nothing
check "unknown step: exit 2 and the steps listed" bash -c "[ $rc = 2 ] && grep -q 'Unknown step: nothing' '$root/out' && grep -q 'libvirt tools vscode jetbrains rust java node python' '$root/out'"
run '' --only
check "--only without a list: exit 2" test "$rc" = 2
run '' stray
check "a stray argument: exit 2" test "$rc" = 2
check "help and comment text carry no personal names" bash -c "! grep -qiE 'kevin|redcodeworks' '$justfile'"

# ---- the sudo command: the shipped recipe uses it only in the libvirt step
check "sudo is called in the libvirt step only" bash -c "
  rest=\$(sed '/^    # ---- step: libvirt/,/^    # ---- step: tools/d' '$justfile')
  body=\$(sed -n '/^    # ---- step: libvirt/,/^    # ---- step: tools/p' '$justfile')
  grep -q 'sudo sh -c' <<<\"\$body\" && ! grep -E '(^|[^[:alnum:]_])sudo (sh|usermod|systemctl|-)' <<<\"\$rest\""

# ---- menu: entries and ids (a fake terminal and a fake gum)
reset
export OCTARINE_MENU_FORCE_TTY=1
gumq 1 'Python 3.12 to 3.14 from uv\n'
run ''
unset OCTARINE_MENU_FORCE_TTY
check "bare dev on a terminal opens one checklist with the eight ids' entries" bash -c "[ \$(grep -c '^gum choose' '$LOG') = 1 ] && grep -q 'libvirt\\|System libvirt' '$LOG' && for t in 'System libvirt' 'Homebrew developer tools' 'Visual Studio Code' 'JetBrains Toolbox' 'Rust: rustup' 'Java: SDKMAN' 'Node: fnm' 'Python 3.12 to 3.14'; do grep -q \"\$t\" '$LOG' || exit 1; done"
check "menu: nothing is preselected (no --selected)" notlogged "--selected "
check "menu: the chosen step ran, the others did not" bash -c "grep -q 'uv python install' '$LOG' && ! grep -q 'brew install' '$LOG' && ! grep -q 'flatpak install' '$LOG' && ! grep -q '^sudo' '$LOG'"
check "menu: one entry per line and no heading rows (every row has a step id)" bash -c "[ \$(grep -o 'Python 3.12 to 3.14\\|Node: fnm\\|Java: SDKMAN\\|Rust: rustup\\|JetBrains Toolbox\\|Visual Studio Code\\|Homebrew developer tools\\|System libvirt' '$LOG' | sort -u | wc -l) = 8 ]"
reset
export OCTARINE_MENU_FORCE_TTY=1
run ''
unset OCTARINE_MENU_FORCE_TTY
check "empty checklist: exit 0, nothing changed" bash -c "[ $rc = 0 ] && grep -q 'Nothing selected' '$root/out' && ! grep -q 'brew install' '$LOG'"
reset
for a in "--yes" "--no" "--only python --yes" "--only python"; do
    : >"$LOG"; rm -f "$root"/gumq.*
    export OCTARINE_MENU_FORCE_TTY=1
    # shellcheck disable=SC2086
    run '' $a
    unset OCTARINE_MENU_FORCE_TTY
    check "no checklist for: $a" notlogged "gum choose"
done

# ---- fresh home, everything with --yes (libvirt is skipped: it needs sudo and --only libvirt)
reset
run '' --yes
check "fresh --yes: libvirt skipped, no sudo at all" bash -c "grep -qE '^libvirt +skipped \\(needs sudo' '$root/out' && ! grep -q '^sudo' '$LOG'"
check "fresh --yes: tools installed, one brew call per package" bash -c "for p in helix ruff ty sqlfluff prettier typescript-language-server vscode-langservers-extracted yaml-language-server marksman jdtls google-java-format lua-language-server stylua taplo sql-language-server gh; do grep -qx \"brew install \$p\" '$LOG' || exit 1; done"
check "fresh --yes: the VS Code Flatpak from Flathub, user installation, with the verification note" bash -c "grep -q 'flatpak install --user -y flathub com.visualstudio.code' '$LOG' && grep -q 'not verified on Flathub' '$root/out'"
check "fresh --yes: official JetBrains cask, launcher and icon" bash -c "grep -qx 'brew install --cask jetbrains-toolbox' '$LOG' && grep -q 'jetbrains-toolbox-linux' '$LOG' ; [ -f '$HOME/.local/share/applications/jetbrains-toolbox.desktop' ] && [ -f '$HOME/.local/share/icons/hicolor/256x256/apps/jetbrains-toolbox.png' ]"
check "fresh --yes: the launcher uses the stable Homebrew bin path, not the Caskroom" bash -c "grep -qx 'Exec=$STATE/brewprefix/bin/jetbrains-toolbox %u' '$HOME/.local/share/applications/jetbrains-toolbox.desktop' && ! grep -q Caskroom '$HOME/.local/share/applications/jetbrains-toolbox.desktop'"
check "fresh --yes: rustup-init with the default profile and no rc edits, then the two components" bash -c "grep -qx 'rustup-init -y --profile default --no-modify-path' '$LOG' && grep -qx 'rustup component add rust-analyzer rust-src' '$LOG'"
check "fresh --yes: SDKMAN through the tap, pinned, never curl" bash -c "grep -qx 'brew install sdkman/tap/sdkman-cli' '$LOG' && grep -qx 'brew pin sdkman/tap/sdkman-cli' '$LOG' && ! grep -qi 'curl\\|get.sdkman.io' '$LOG'"
check "fresh --yes: Zulu 8, 11, 17, 21, 25 at the newest listed build (no fx, crac, other vendors), default 21" bash -c "for v in 8.0.504 11.0.32 17.0.20 21.0.12 25.0.4; do grep -q \"sdk install java \$v-zulu\" '$LOG' || exit 1; done; ! grep 'sdk install' '$LOG' | grep -q '24\\|fx\\|crac\\|tem\\|oracle\\|21.0.11' && grep -q 'sdk default java 21.0.12-zulu' '$LOG'"
check "fresh --yes: the JDK installs decline the SDKMAN default question (stdin n)" bash -c "grep 'sdk install java' '$LOG' | grep -q 'stdin: n'"
check "fresh --yes: fnm from Homebrew, LTS and default" bash -c "grep -qx 'brew install fnm' '$LOG' && grep -qx 'fnm install --lts' '$LOG' && grep -qx 'fnm default lts-latest' '$LOG' && ! grep -q 'nvm' '$LOG'"
check "fresh --yes: fnm.sh and fnm.fish written" bash -c "[ -s '$HOME/.config/octarine-os/fnm.sh' ] && [ -s '$HOME/.config/octarine-os/fnm.fish' ]"
check "fresh --yes: uv installs the three Pythons" bash -c "grep -qx 'uv python install 3.12 3.13 3.14' '$LOG' && grep -q 'cpython-3.14' '$root/out'"
check "fresh --yes: every attempted step applied, exit 0" bash -c "[ $rc = 0 ] && for s in tools vscode jetbrains rust java node python; do grep -qE \"^\$s +applied\" '$root/out' || exit 1; done"
check "fresh --yes: an undo line per applied step" bash -c "for s in tools vscode jetbrains rust java node python; do grep -q \"^  \$s: \" '$root/out' || exit 1; done"
check "fresh --yes: the SDKMAN installer URL is nowhere in the recipe" bash -c "! grep -qi 'get.sdkman.io\\|curl' '$justfile'"
check "fresh --yes: no rc file was touched (none existed, none created)" bash -c "[ ! -e '$HOME/.zshrc' ] && [ ! -e '$HOME/.bashrc' ] && [ ! -e '$HOME/.config/fish/config.fish' ]"

# ---- already done: second run changes nothing
: >"$LOG"
run '' --yes
check "second run: nothing installed again" bash -c "! grep -qE '^(brew install|flatpak install|rustup-init|uv python install|fnm install|sdk install)' '$LOG'"
check "second run: every attempted step already done, exit 0" bash -c "[ $rc = 0 ] && for s in tools vscode jetbrains rust java node python; do grep -qE \"^\$s +already done\" '$root/out' || exit 1; done"
check "second run: no undo section" hasnt "To undo"
reset; installed_world
run '' --yes --only libvirt
check "libvirt already set up: no sudo, already done" bash -c "[ $rc = 0 ] && grep -qE '^libvirt +already done' '$root/out' && ! grep -q '^sudo' '$LOG'"

# ---- libvirt
reset
echo autostart >"$STATE/net"
run '' --yes --only libvirt
check "libvirt fresh with --only: ONE sudo call with group, usermod and sockets" bash -c "[ \$(grep -c '^sudo' '$LOG') = 1 ] && grep '^sudo' '$LOG' | grep -q \"usermod -aG libvirt tester\" && grep '^sudo' '$LOG' | grep -q 'systemctl enable --now virtqemud.socket virtnetworkd.socket virtstoraged.socket' && grep '^sudo' '$LOG' | grep -q \"grep '^libvirt:' $root/usr-group >> $root/etc-group\""
check "libvirt fresh: libvirt.conf written with the default URI" bash -c "grep -qx 'uri_default = \"qemu:///system\"' '$HOME/.config/libvirt/libvirt.conf'"
check "libvirt fresh: tells to log in again and does not touch the network yet" bash -c "grep -q 'Log out and back in' '$root/out' && grep -q \"run 'ujust dev --only libvirt' again\" '$root/out' && ! grep -q 'virsh' '$LOG'"
check "libvirt fresh: undo line and exit 0" bash -c "[ $rc = 0 ] && grep -q '^  libvirt: sudo gpasswd -d tester libvirt' '$root/out'"
reset
printf 'root:x:0:\nlibvirt:x:970:\n' >"$root/etc-group"
run '' --only libvirt --yes
check "libvirt: the group line is not copied again when /etc/group has it" bash -c "grep '^sudo' '$LOG' | grep -qv 'usr-group'"
reset
SUDO_RC=1 run '' --only libvirt --yes
check "libvirt: a failed sudo is reported once with the exact command, not retried" bash -c "[ $rc = 1 ] && [ \$(grep -c '^sudo' '$LOG') = 1 ] && grep -q \"Run it yourself:  sudo sh -c 'grep\" '$root/out' && grep -qE '^libvirt +FAILED' '$root/out'"
reset
installed_world
rm -f "$STATE/sockets/virtstoraged"; echo noautostart >"$STATE/net"
run '' --only libvirt --yes
check "libvirt: only the missing socket is enabled; the network gets autostart" bash -c "grep '^sudo' '$LOG' | grep -qx 'sudo sh -c systemctl enable --now virtstoraged.socket' && grep -q 'virsh -c qemu:///system net-autostart default' '$LOG' && ! grep -q usermod '$LOG'"
reset
installed_world
echo missing >"$STATE/net"
run '' --only libvirt --yes
check "libvirt: a missing default network is defined from the shipped XML, autostarted, started" bash -c "grep -q 'net-define $root/net-default.xml' '$LOG' && grep -q 'net-autostart default' '$LOG' && grep -q 'net-start default' '$LOG'"
reset
installed_world
echo down >"$STATE/net"
run '' --only libvirt --yes
check "libvirt: an unreachable daemon is a note, not a failure" bash -c "[ $rc = 0 ] && grep -q 'could not be checked' '$root/out' && grep -qE '^libvirt +already done' '$root/out'"
reset
installed_world
printf 'uri_default = "qemu:///session"\n' >"$HOME/.config/libvirt/libvirt.conf"
run '' --only libvirt --yes
check "libvirt: a different libvirt.conf is shown as a diff and kept under --yes" bash -c "grep -q 'differs' '$root/out' && grep -q 'qemu:///session' '$HOME/.config/libvirt/libvirt.conf' && ls '$HOME/.config/libvirt/' | grep -qv bak && [ -z \"\$(ls '$HOME'/.config/libvirt/*.bak-* 2>/dev/null)\" ]"
run 'y\ny\n' --only libvirt
check "libvirt: answering y replaces it after a timestamped backup" bash -c "grep -qx 'uri_default = \"qemu:///system\"' '$HOME/.config/libvirt/libvirt.conf' && grep -q 'qemu:///session' \$(ls '$HOME'/.config/libvirt/libvirt.conf.bak-*)"
reset
run '' --only libvirt --no
check "libvirt --no: prints the command, runs no sudo, writes nothing" bash -c "[ $rc = 0 ] && grep -q 'sudo sh -c' '$root/out' && ! grep -q '^sudo' '$LOG' && [ ! -e '$HOME/.config/libvirt' ] && grep -qE '^libvirt +planned' '$root/out'"

# ---- tools
reset
: >"$STATE/formulae/helix"; : >"$STATE/formulae/gh"
run '' --yes --only tools
check "tools partial: installed ones are skipped" bash -c "! grep -qx 'brew install helix' '$LOG' && ! grep -qx 'brew install gh' '$LOG' && grep -qx 'brew install ruff' '$LOG' && grep -q 'helix: already installed' '$root/out'"
reset
: >"$STATE/fail-stylua"
run '' --yes --only tools
check "tools: one failing package does not stop the others; reported with the re-run command; exit 1" bash -c "[ $rc = 1 ] && grep -qx 'brew install taplo' '$LOG' && grep -qx 'brew install gh' '$LOG' && grep -q 'Not installed: stylua' '$root/out' && grep -q 'ujust dev --only tools' '$root/out' && grep -qE '^tools +FAILED for stylua' '$root/out'"
check "tools: a failing install is tried three times" bash -c "[ \$(grep -cx 'brew install stylua' '$LOG') = 3 ]"
reset
echo 2 >"$STATE/failn-taplo"
run '' --yes --only tools
check "tools: a transient failure is retried and then succeeds" bash -c "[ $rc = 0 ] && [ \$(grep -cx 'brew install taplo' '$LOG') = 3 ] && grep -qE '^tools +applied' '$root/out' && grep -q 'retrying' '$root/out'"
reset
gumq 1 'Python (ruff ty sqlfluff)\nTOML (taplo)\n'
export OCTARINE_MENU_FORCE_TTY=1
run '' --only tools
unset OCTARINE_MENU_FORCE_TTY
check "tools on a terminal: a second checklist of the eight groups; only the ticked groups install" bash -c "grep -q 'Editor (helix)' '$LOG' && grep -q 'GitHub (gh)' '$LOG' && grep -qx 'brew install ruff' '$LOG' && grep -qx 'brew install taplo' '$LOG' && ! grep -qx 'brew install helix' '$LOG' && ! grep -qx 'brew install marksman' '$LOG'"
check "tools menu: every group is preselected" logged "--selected "
reset
run 'n\nn\nn\nn\ny\nn\nn\nn\n' --only tools
check "tools without gum: one y/n per group (default yes), only the yes group installs" bash -c "grep -qx 'brew install lua-language-server' '$LOG' && grep -qx 'brew install stylua' '$LOG' && ! grep -qx 'brew install helix' '$LOG' && ! grep -qx 'brew install gh' '$LOG'"
reset
run '' --no --only tools
check "tools --no: nothing installed, plan printed" bash -c "[ $rc = 0 ] && ! grep -q '^brew install' '$LOG' && grep -q 'To install: helix' '$root/out' && grep -qE '^tools +planned' '$root/out'"
check "tools: the list has exactly the briefed formulae and no gh login" bash -c "for p in helix ruff ty sqlfluff prettier typescript-language-server vscode-langservers-extracted yaml-language-server marksman jdtls google-java-format lua-language-server stylua taplo sql-language-server gh; do grep -q \"\$p\" '$justfile' || exit 1; done; ! grep -q 'gh auth' '$justfile'"
reset
PATH_BIN="$sysbin" run '' --yes --only tools
check "missing brew: the step fails with a clear message, exit 1" bash -c "[ $rc = 1 ] && grep -q 'Homebrew (brew) is not on PATH' '$root/out' && grep -qE '^tools +FAILED' '$root/out'"
for s in jetbrains java node; do
    PATH_BIN="$sysbin" run '' --yes --only $s
    check "missing brew: $s fails with a clear message" bash -c "[ $rc = 1 ] && grep -q 'not on PATH' '$root/out'"
done

# ---- vscode
reset
: >"$STATE/fail-flatpak"
run '' --yes --only vscode
check "vscode: a failing install is retried, reported, exit 1, re-run command" bash -c "[ $rc = 1 ] && [ \$(grep -c 'flatpak install' '$LOG') = 3 ] && grep -q 'ujust dev --only vscode' '$root/out'"
reset
installed_world
run '' --yes --only vscode
check "vscode already installed: nothing runs" bash -c "grep -qE '^vscode +already done' '$root/out' && ! grep -q 'flatpak install' '$LOG'"
reset
run '' --no --only vscode
check "vscode --no: plan only" bash -c "! grep -q 'flatpak install' '$LOG' && grep -qE '^vscode +planned' '$root/out'"

# ---- jetbrains
reset
: >"$STATE/casks/jetbrains-toolbox-linux"
run '' --yes --only jetbrains
check "jetbrains: the old ublue cask is replaced, state in HOME kept (said so)" bash -c "grep -qx 'brew uninstall --cask jetbrains-toolbox-linux' '$LOG' && grep -qx 'brew install --cask jetbrains-toolbox' '$LOG' && grep -q 'state in your home' '$root/out'"
check "jetbrains: the uninstall comes before the install" bash -c "[ \$(grep -n 'brew uninstall --cask' '$LOG' | head -1 | cut -d: -f1) -lt \$(grep -n 'brew install --cask' '$LOG' | head -1 | cut -d: -f1) ]"
check "jetbrains: launcher valid, marked, and the icon copied from the cask" bash -c "d='$HOME/.local/share/applications/jetbrains-toolbox.desktop'; grep -qx '\\[Desktop Entry\\]' \$d && grep -qx 'X-Octarine-Generated=ujust dev' \$d && grep -qx 'Icon=jetbrains-toolbox' \$d && cmp -s '$STATE/brewprefix/Caskroom/jetbrains-toolbox/9.9/jetbrains-toolbox-9.9/bin/toolbox.png' '$HOME/.local/share/icons/hicolor/256x256/apps/jetbrains-toolbox.png'"
if command -v desktop-file-validate >/dev/null 2>&1; then
    check "jetbrains: the launcher passes desktop-file-validate" desktop-file-validate "$HOME/.local/share/applications/jetbrains-toolbox.desktop"
fi
check "jetbrains: the Toolbox self-update note" has "updates itself"
run '' --yes --only jetbrains
check "jetbrains again: already done" row jetbrains "already done"
reset
installed_world
rm -f "$HOME/.local/share/applications/jetbrains-toolbox.desktop"
echo 'Name=Mine' >"$HOME/.local/share/applications/jetbrains-toolbox.desktop"
run '' --yes --only jetbrains
check "jetbrains: a launcher you wrote yourself is shown as a diff and kept" bash -c "grep -q 'differs' '$root/out' && grep -qx 'Name=Mine' '$HOME/.local/share/applications/jetbrains-toolbox.desktop' && ! grep -q 'brew install' '$LOG'"
reset
: >"$STATE/fail-jetbrains-toolbox"
run '' --yes --only jetbrains
check "jetbrains: a failed cask install is reported, no launcher written, exit 1" bash -c "[ $rc = 1 ] && [ ! -e '$HOME/.local/share/applications/jetbrains-toolbox.desktop' ] && grep -q 'ujust dev --only jetbrains' '$root/out'"

# ---- rust
reset
run '' --yes --only rust
check "rust fresh: init then components, undo shown" bash -c "[ $rc = 0 ] && grep -q 'rustup component add rust-analyzer rust-src' '$LOG' && grep -q '^  rust: ' '$root/out'"
reset
mkdir -p "$HOME/.cargo/bin"; cp "$STATE/stubs/rustup" "$HOME/.cargo/bin/rustup"; printf 'cargo\nrustc\n' >"$STATE/components"
run '' --yes --only rust
check "rust partial (rustup exists): no rustup-init, shows the active toolchain, adds only the components" bash -c "! grep -q 'rustup-init' '$LOG' && grep -q 'Active toolchain: stable-x86_64' '$root/out' && grep -qx 'rustup component add rust-analyzer rust-src' '$LOG'"
reset; installed_world
run '' --yes --only rust
check "rust already set up: nothing runs besides reads" bash -c "grep -qE '^rust +already done' '$root/out' && ! grep -q 'component add' '$LOG' && grep -q 'already set up' '$root/out'"
reset
: >"$STATE/fail-rustup-init"
run '' --yes --only rust
check "rust: failing rustup-init is retried, reported, exit 1" bash -c "[ $rc = 1 ] && [ \$(grep -c '^rustup-init' '$LOG') = 3 ] && grep -q 'ujust dev --only rust' '$root/out'"
reset
run '' --no --only rust
check "rust --no: plan only" bash -c "! grep -q '^rustup-init' '$LOG' && grep -qE '^rust +planned' '$root/out'"

# ---- java
reset
run '' --yes --only java
check "java fresh: summary applied, undo mentions unpin" bash -c "[ $rc = 0 ] && grep -qE '^java +applied' '$root/out' && grep -q 'brew unpin sdkman/tap/sdkman-cli' '$root/out'"
check "java: only the sdk wrapper runs SDKMAN (never a curl, never ~/.local/bin/sdk)" bash -c "! grep -q '.local/bin/sdk' '$LOG'"
reset
mkdir -p "$HOME/.sdkman/bin" "$HOME/.sdkman/candidates/java"
echo '# script install' >"$HOME/.sdkman/bin/sdkman-init.sh"
run '' --yes --only java
check "java with a script install in ~/.sdkman: used as is, tap NOT installed, not migrated" bash -c "grep -q 'script install in ~/.sdkman' '$root/out' && ! grep -q 'brew install sdkman' '$LOG' && ! grep -q 'brew pin' '$LOG' && grep -qx '# script install' '$HOME/.sdkman/bin/sdkman-init.sh' && grep -q 'sdk install java 21.0.12-zulu' '$LOG'"
reset; installed_world
rm -rf "$HOME/.sdkman/candidates/java/11.0.32-zulu" "$HOME/.sdkman/candidates/java/17.0.20-zulu"
run '' --yes --only java
check "java partial: installed majors are skipped, only 11 and 17 installed, default already 21" bash -c "grep -q 'sdk install java 11.0.32-zulu' '$LOG' && grep -q 'sdk install java 17.0.20-zulu' '$LOG' && ! grep -q 'sdk install java 8\\|sdk install java 21\\|sdk install java 25' '$LOG' && ! grep -q 'sdk default' '$LOG' && grep -q 'Default java is already' '$root/out'"
reset; installed_world
run '' --yes --only java
check "java already done: no network, no list, no brew install" bash -c "grep -qE '^java +already done' '$root/out' && ! grep -q 'sdk list' '$LOG' && ! grep -q 'brew install' '$LOG'"
reset; installed_world
rm -f "$HOME/.sdkman/candidates/java/current"
run '' --yes --only java
check "java: sets the default 21 when none is set" bash -c "grep -q 'sdk default java 21.0.12-zulu' '$LOG' && ! grep -q 'sdk install' '$LOG'"
reset
: >"$STATE/fail-sdklist"
run '' --yes --only java
check "java: a network failure reading the list is reported with the re-run command, exit 1" bash -c "[ $rc = 1 ] && grep -q 'could not read the Java list' '$root/out' && grep -q 'ujust dev --only java' '$root/out' && [ \$(grep -c 'sdk list java' '$LOG') = 3 ]"
reset
: >"$STATE/fail-brew-unused"; : >"$STATE/fail-sdkman-cli"
run '' --yes --only java
check "java: a failing tap install is reported, nothing else runs" bash -c "[ $rc = 1 ] && grep -q 'brew install sdkman/tap/sdkman-cli (network?)' '$root/out' && ! grep -q 'sdk install' '$LOG'"
reset
: >"$STATE/fail-java-17.0.20-zulu"
run '' --yes --only java
check "java: one failing JDK does not stop the others; exit 1" bash -c "[ $rc = 1 ] && grep -q 'sdk install java 25.0.4-zulu' '$LOG' && grep -q 'FAILED: sdk install java 17.0.20-zulu' '$root/out' && grep -qE '^java +FAILED for 17.0.20-zulu \\(others done\\)' '$root/out'"
reset
run '' --no --only java
check "java --no: plan only" bash -c "! grep -q 'brew install' '$LOG' && ! grep -q 'sdk install' '$LOG' && grep -q 'Plan: brew install sdkman/tap/sdkman-cli' '$root/out'"
reset
rm -f "$OCTARINE_SDK_WRAPPER.gone"
OCTARINE_SDK_WRAPPER="$root/none" run '' --yes --only java
check "java: a missing sdk wrapper is reported" bash -c "[ $rc = 1 ] && grep -q 'sdk wrapper' '$root/out'"

# ---- the sdk wrapper itself (a real run in a fake home and a fake Homebrew prefix)
wr="$root/wr"
mkwr() {
    rm -rf "$wr"; mkdir -p "$wr/home" "$wr/prefix/opt/sdkman-cli/libexec/bin"
    cat >"$wr/prefix/opt/sdkman-cli/libexec/bin/sdkman-init.sh" <<'F'
sdk() { echo "sdk-called:$*:dir=$SDKMAN_DIR:cand=$SDKMAN_CANDIDATES_DIR"; }
F
}
wrun() { HOME="$wr/home" SDK_HOME_DIR="$wr/home/.sdkman" OCTARINE_BREW_PREFIX="$wr/prefix" PATH="$sysbin" "$wrapper" "$@" >"$root/out" 2>&1; rc=$?; }
mkwr
rm "$wr/prefix/opt/sdkman-cli/libexec/bin/sdkman-init.sh"
wrun list java
check "wrapper: no SDKMAN at all: exit 1 and the ujust dev hint" bash -c "[ $rc = 1 ] && grep -q 'ujust dev --only java' '$root/out'"
wrun --octarine-relink
check "wrapper: --octarine-relink with nothing installed also fails" test "$rc" = 1
mkwr
wrun list java
check "wrapper: the tap's libexec is used and the call reaches the sdk function" bash -c "[ $rc = 0 ] && grep -q 'sdk-called:list java:dir=$wr/prefix/opt/sdkman-cli/libexec' '$root/out'"
check "wrapper: tap mode creates ~/.sdkman/candidates and links the keg's candidates to it" bash -c "[ -d '$wr/home/.sdkman/candidates' ] && [ \"\$(readlink '$wr/prefix/opt/sdkman-cli/libexec/candidates')\" = '$wr/home/.sdkman/candidates' ]"
# simulate a brew upgrade: the keg gets a real directory again, holding a candidate
rm "$wr/prefix/opt/sdkman-cli/libexec/candidates"
mkdir -p "$wr/prefix/opt/sdkman-cli/libexec/candidates/java/21.0.99-zulu" "$wr/prefix/opt/sdkman-cli/libexec/candidates/spark/4.2.0"
mkdir -p "$wr/home/.sdkman/candidates/java/21.0.12-zulu"
echo keep >"$wr/home/.sdkman/candidates/java/21.0.12-zulu/marker"
wrun list java
check "wrapper: after an upgrade the symlink is re-created" bash -c "[ -L '$wr/prefix/opt/sdkman-cli/libexec/candidates' ] && [ \"\$(readlink '$wr/prefix/opt/sdkman-cli/libexec/candidates')\" = '$wr/home/.sdkman/candidates' ]"
check "wrapper: candidates found in the new directory are moved (merged), nothing deleted" bash -c "[ -d '$wr/home/.sdkman/candidates/java/21.0.99-zulu' ] && [ -d '$wr/home/.sdkman/candidates/spark/4.2.0' ] && [ -f '$wr/home/.sdkman/candidates/java/21.0.12-zulu/marker' ]"
# a conflict leaves both sides alone and warns
rm "$wr/prefix/opt/sdkman-cli/libexec/candidates"
mkdir -p "$wr/prefix/opt/sdkman-cli/libexec/candidates/java/21.0.12-zulu"
wrun list java
check "wrapper: a name that exists on both sides is left alone with a warning (no deletion)" bash -c "grep -q 'both exist; left both in place' '$root/out' && [ -d '$wr/prefix/opt/sdkman-cli/libexec/candidates/java/21.0.12-zulu' ] && [ -f '$wr/home/.sdkman/candidates/java/21.0.12-zulu/marker' ]"
mkwr
mkdir -p "$wr/home/.sdkman/bin"
echo 'sdk() { echo "script-sdk:$SDKMAN_DIR"; }' >"$wr/home/.sdkman/bin/sdkman-init.sh"
wrun version
check "wrapper: an init script in ~/.sdkman wins over the tap, and the keg is not touched" bash -c "grep -q \"script-sdk:$wr/home/.sdkman\" '$root/out' && [ ! -e '$wr/prefix/opt/sdkman-cli/libexec/candidates' ]"
check "wrapper: bash syntax and no curl or installer" bash -c "bash -n '$wrapper' && ! grep -qi 'curl\\|get.sdkman' '$wrapper' && [ -x '$wrapper' ]"

# ---- node (fnm)
reset
run '' --yes --only node
check "node fresh --yes: summary applied, the rc line is printed, no rc file edited" bash -c "[ $rc = 0 ] && grep -qE '^node +applied' '$root/out' && grep -q 'Add ONE line to your rc file' '$root/out' && [ ! -e '$HOME/.zshrc' ]"
check "node: the notes name nvm separation, ~/.local/share/fnm and .nvmrc" bash -c "grep -q 'an existing ~/.nvm is left alone' '$root/out' && grep -q '.nvmrc files work with fnm' '$root/out' && grep -q '~/.local/share/fnm' '$root/out'"
check "node: no nvm anywhere in the recipe except the notes" bash -c "[ \$(grep -ci 'nvm' '$justfile') -le 3 ]"
mkdir -p "$HOME/.nvm"; echo v24 >"$HOME/.nvm/marker"
run '' --yes --only node
check "node: an existing ~/.nvm is left untouched" bash -c "[ -f '$HOME/.nvm/marker' ] && [ \"\$(ls '$HOME/.nvm')\" = marker ]"
check "node again: already done, and no brew or fnm install" bash -c "grep -qE '^node +already done' '$root/out'"
reset
mkdir -p "$HOME/.config/fish"
printf 'export A=1\n' >"$HOME/.zshrc"; printf 'export B=1' >"$HOME/.bashrc"; printf 'set -x C 1\n' >"$HOME/.config/fish/config.fish"
run 'y\ny\ny\ny\n' --only node
check "node: with rc files and yes answers: one guarded line appended to each, backups made, a diff shown" bash -c "grep -qF 'octarine-os/fnm.sh' '$HOME/.zshrc' && grep -qF 'octarine-os/fnm.sh' '$HOME/.bashrc' && grep -qF 'octarine-os/fnm.fish' '$HOME/.config/fish/config.fish' && [ -n \"\$(ls '$HOME'/.zshrc.bak-*)\" ] && [ -n \"\$(ls '$HOME'/.bashrc.bak-*)\" ] && grep -q '^    +' '$root/out'"
check "node: a file without a final newline gets the line on its own line" bash -c "[ \$(wc -l <'$HOME/.bashrc') = 2 ] && head -1 '$HOME/.bashrc' | grep -qx 'export B=1'"
check "node: the original rc content is preserved in the backup" bash -c "grep -qx 'export A=1' \$(ls '$HOME'/.zshrc.bak-*)"
reset
printf 'export A=1\n' >"$HOME/.zshrc"
run '' --yes --only node
check "node --yes: rc files are kept (default keep), the line is only printed" bash -c "[ \"\$(cat '$HOME/.zshrc')\" = 'export A=1' ] && [ -z \"\$(ls '$HOME'/.zshrc.bak-* 2>/dev/null)\" ] && grep -q 'Kept' '$root/out'"
reset
printf 'export A=1\n' >"$HOME/.zshrc"
run 'n\n' --only node
check "node: answering n keeps the rc file" bash -c "[ \"\$(cat '$HOME/.zshrc')\" = 'export A=1' ]"
reset
printf 'export A=1\n' >"$HOME/.zshrc"
run '' --no --only node
check "node --no: nothing installed or written" bash -c "! grep -q 'brew install' '$LOG' && [ ! -e '$HOME/.config/octarine-os' ] && grep -qE '^node +planned' '$root/out'"
reset
: >"$STATE/fail-fnm"
run '' --yes --only node
check "node: a failed formula install is reported with the re-run command, exit 1" bash -c "[ $rc = 1 ] && grep -q 'ujust dev --only node' '$root/out' && [ ! -e '$HOME/.config/octarine-os/fnm.sh' ]"
reset
mkdir -p "$HOME/.config/octarine-os"; echo '# mine' >"$HOME/.config/octarine-os/fnm.sh"
run '' --yes --only node
check "node: a different fnm.sh of yours is kept under --yes (diff shown)" bash -c "grep -q 'differs' '$root/out' && grep -qx '# mine' '$HOME/.config/octarine-os/fnm.sh' && grep -qE '^node +(skipped|applied)' '$root/out'"

# ---- the fnm shell files: syntax, cache creation and reuse
reset
run '' --yes --only node
snip="$HOME/.config/octarine-os"
check "fnm.sh passes sh -n" sh -n "$snip/fnm.sh"
check "fnm.sh passes bash -n" bash -n "$snip/fnm.sh"
if command -v zsh >/dev/null 2>&1; then check "fnm.sh passes zsh -n" zsh -n "$snip/fnm.sh"; fi
if command -v fish >/dev/null 2>&1; then check "fnm.fish passes fish --no-execute" fish --no-execute "$snip/fnm.fish"; fi
snip_env() { env -i HOME="$HOME" PATH="$pbin:$sysbin" STATE="$STATE" LOG="$LOG" "$@"; }
rm -rf "$STATE/fnm-env-count" "$HOME/.cache"
out1=$(snip_env bash -c ". '$snip/fnm.sh'; echo \"loaded=\${OCT_FNM_LOADED:-no}\"")
check "bash: the first shell start generates the cache with fnm env --use-on-cd --shell bash and loads it" bash -c "[ '$out1' = loaded=1 ] && [ -s '$HOME/.cache/octarine-os/shell/fnm.bash' ] && grep -q 'fnm env --use-on-cd --shell bash' '$LOG' && [ \$(wc -l <'$STATE/fnm-env-count') = 1 ]"
out2=$(snip_env bash -c ". '$snip/fnm.sh'; echo \"loaded=\${OCT_FNM_LOADED:-no}\"")
check "bash: a second shell start does NOT run fnm env (cache reused) and still loads" bash -c "[ '$out2' = loaded=1 ] && [ \$(wc -l <'$STATE/fnm-env-count') = 1 ]"
touch -d '+1 hour' "$pbin/fnm"
snip_env bash -c ". '$snip/fnm.sh'" >/dev/null 2>&1
check "bash: a newer fnm binary regenerates the cache once" bash -c "[ \$(wc -l <'$STATE/fnm-env-count') = 2 ]"
rm -rf "$STATE/multishell"
snip_env bash -c ". '$snip/fnm.sh'" >/dev/null 2>&1
check "bash: a vanished multishell directory is refreshed (tmpfs cleaned at reboot)" bash -c "[ \$(wc -l <'$STATE/fnm-env-count') = 3 ] && [ -d '$STATE/multishell' ]"
check "bash: the snippet is silent and leaves no helper function behind" bash -c "[ -z \"\$(env -i HOME='$HOME' PATH='$pbin:$sysbin' STATE='$STATE' LOG='$LOG' bash -c \". '$snip/fnm.sh'; declare -F _oct_fnm_refresh\" 2>&1)\" ]"
check "bash: without fnm on PATH the snippet does nothing and exits clean" bash -c "env -i HOME='$HOME' PATH='$sysbin' bash -c \". '$snip/fnm.sh'; echo done\" | grep -qx done"
check "bash: the cache sits under XDG_CACHE_HOME when set" bash -c "rm -rf '$root/xdgc'; env -i HOME='$HOME' XDG_CACHE_HOME='$root/xdgc' PATH='$pbin:$sysbin' STATE='$STATE' LOG='$LOG' bash -c \". '$snip/fnm.sh'\" ; [ -s '$root/xdgc/octarine-os/shell/fnm.bash' ]"
if command -v zsh >/dev/null 2>&1; then
    touch -d '-1 hour' "$pbin/fnm"
    rm -rf "$HOME/.cache" "$STATE/fnm-env-count"
    zsh_bin=$(command -v zsh)
    zout=$(snip_env "$zsh_bin" -c ". '$snip/fnm.sh'; echo \"loaded=\${OCT_FNM_LOADED:-no}\"")
    zout2=$(snip_env "$zsh_bin" -c ". '$snip/fnm.sh'; echo \"loaded=\${OCT_FNM_LOADED:-no}\"")
    check "zsh: cache fnm.zsh generated once with --shell zsh, reused by the second start" bash -c "[ '$zout' = loaded=1 ] && [ '$zout2' = loaded=1 ] && [ -s '$HOME/.cache/octarine-os/shell/fnm.zsh' ] && grep -q 'fnm env --use-on-cd --shell zsh' '$LOG' && [ \$(wc -l <'$STATE/fnm-env-count') = 1 ]"
fi
if command -v fish >/dev/null 2>&1; then
    rm -rf "$HOME/.cache" "$STATE/fnm-env-count"
    # fnm's fish output: the stub prints sh syntax, so use a fish-syntax stub for this check
    cat >"$STATE/fishfnm" <<'F'
#!/usr/bin/env bash
case "$1" in env) echo x >>"$STATE/fnm-env-count"; echo "set -gx OCT_FNM_LOADED 1" ;; esac
F
    chmod +x "$STATE/fishfnm"; mkdir -p "$root/fpbin"; cp "$STATE/fishfnm" "$root/fpbin/fnm"
    f1=$(env -i HOME="$HOME" PATH="$root/fpbin:$sysbin:$(dirname "$(command -v fish)")" STATE="$STATE" fish --no-config -c "source '$snip/fnm.fish'; echo loaded=\$OCT_FNM_LOADED")
    f2=$(env -i HOME="$HOME" PATH="$root/fpbin:$sysbin:$(dirname "$(command -v fish)")" STATE="$STATE" fish --no-config -c "source '$snip/fnm.fish'; echo loaded=\$OCT_FNM_LOADED")
    check "fish: cache created once, loaded by both starts, fnm env run once" bash -c "[ '$f1' = loaded=1 ] && [ '$f2' = loaded=1 ] && [ -s '$HOME/.cache/octarine-os/shell/fnm.fish' ] && [ \$(wc -l <'$STATE/fnm-env-count') = 1 ]"
    check "fish: without fnm the snippet is silent" bash -c "[ -z \"\$(env -i HOME='$HOME' PATH='$sysbin:$(dirname "$(command -v fish)")' fish --no-config -c \"source '$snip/fnm.fish'\" 2>&1)\" ]"
fi

# ---- python
reset
run '' --yes --only python
check "python fresh: one uv call for the three versions, then the installed list" bash -c "[ $rc = 0 ] && grep -qx 'uv python install 3.12 3.13 3.14' '$LOG' && grep -q 'uv python list --only-installed' '$LOG' && grep -qE '^python +applied' '$root/out'"
reset
echo "cpython-3.13.1-linux-x86_64-gnu    $HOME/.local/share/uv/python/cpython-3.13.1/bin/python3.13" >"$STATE/uvlist"
echo "cpython-3.12.5-linux-x86_64-gnu    /usr/bin/python3.12" >>"$STATE/uvlist"
run '' --yes --only python
check "python partial: 3.13 skipped, the SYSTEM 3.12 does not count as installed" bash -c "grep -qx 'uv python install 3.12 3.14' '$LOG' && grep -q 'Python 3.13: already installed' '$root/out'"
reset; installed_world
run '' --yes --only python
check "python already done: no install" bash -c "grep -qE '^python +already done' '$root/out' && ! grep -q 'uv python install' '$LOG'"
reset
: >"$STATE/fail-uv"
run '' --yes --only python
check "python: failing uv is retried, reported, exit 1" bash -c "[ $rc = 1 ] && [ \$(grep -c 'uv python install' '$LOG') = 3 ] && grep -q 'ujust dev --only python' '$root/out'"
reset
run '' --no --only python
check "python --no: plan only" bash -c "! grep -q 'uv python install' '$LOG' && grep -q 'Plan: uv python install 3.12 3.13 3.14' '$root/out'"

# ---- --only with several steps, order, and --yes without sudo
reset
run '' --yes --only python,vscode
check "--only STEP,STEP runs just those, in recipe order" bash -c "[ $rc = 0 ] && ! grep -q 'brew install' '$LOG' && grep -q 'flatpak install' '$LOG' && grep -q 'uv python install' '$LOG' && [ \$(grep -n '== vscode' '$root/out' | cut -d: -f1) -lt \$(grep -n '== python' '$root/out' | cut -d: -f1) ]"
reset
run '' --yes
check "--yes never calls sudo (the libvirt step is skipped with the exact command to run)" bash -c "notlogged() { ! grep -q '^sudo' '$LOG'; }; notlogged && grep -q 'ujust dev --only libvirt --yes' '$root/out'"
reset
run '' --no
check "--no on everything: nothing changes (no brew install, flatpak install, sudo, rustup-init, uv install, sdk install, writes)" bash -c "[ $rc = 0 ] && ! grep -qE '^(brew install|brew pin|brew uninstall|flatpak install|sudo|rustup-init|uv python install|sdk install|fnm install)' '$LOG' && [ -z \"\$(find '$HOME' -type f 2>/dev/null)\" ]"
run '' --no
check "--no: every step shows planned or already done" bash -c "for s in libvirt tools vscode jetbrains rust java node python; do grep -qE \"^\$s +(planned|already done)\" '$root/out' || exit 1; done"
reset
FAKE_UID=0 run '' --yes --only python
check "root is refused" bash -c "[ $rc = 1 ] && grep -q 'not as root' '$root/out' && ! grep -q 'uv python' '$LOG'"

# ---- the dx-only wiring and the shipped files
check "the recipe file exists only in the dx variant, nowhere in the default image's files" bash -c "[ -f '$justfile' ] && [ -z \"\$(find '$repo/system_files' -name '70-octarine-dev*' -o -name 'octarine-dx-cargo*' | head -1)\" ] && ! grep -rq 'octarine-os-dx\\b.*ujust dev\\|^dev ' '$repo/system_files/usr/share/ublue-os/just/60-custom.just' && ! grep -q '^dev\\b' '$repo/system_files/usr/share/ublue-os/just/60-custom.just'"
check "the default image has no sdk wrapper and no cargo profile snippet" bash -c "[ ! -e '$repo/system_files/usr/bin/sdk' ] && [ ! -e '$repo/system_files/etc/profile.d/octarine-dx-cargo.sh' ]"
check "Containerfile and build.sh of the default image never mention the dev recipe" bash -c "! grep -q '70-octarine-dev' '$repo/Containerfile' '$repo/build_files/build.sh'"
check "dx.sh appends the import line to ublue's main justfile, idempotently, and asserts it" bash -c "grep -q 'import? \"/usr/share/ublue-os/just/70-octarine-dev.just\"' '$repo/variants/dx/dx.sh' && grep -q 'grep -qxF \"\${dev_import}\" \"\${ujust_main}\"' '$repo/variants/dx/dx.sh'"
# ---- cuda (only where an NVIDIA driver exists)
cuda_world() { reset; : >"$STATE/nvidia"; mkdir -p "$root/cdi"; echo 'cdiVersion: 0.5.0' >"$root/cdi/nvidia.yaml"; }
reset
run '' --yes --only cuda
check "cuda without a driver: says so, creates nothing, exit 0" bash -c "[ $rc = 0 ] && grep -q 'No NVIDIA driver on this machine' '$root/out' && grep -qE '^cuda +skipped \(no NVIDIA driver' '$root/out' && ! grep -q 'distrobox' '$LOG'"
cuda_world
run '' --yes --only cuda
check "cuda fresh: container created with the CDI device and the Fedora 44 toolbox image, not --nvidia" bash -c "[ $rc = 0 ] && grep -qx 'distrobox create --yes --name cuda --image registry.fedoraproject.org/fedora-toolbox:44 --additional-flags --device nvidia.com/gpu=all' '$LOG' && ! grep -q -- '--nvidia' '$LOG'"
check "cuda fresh: fedora44 repo added, cuda-toolkit and gcc15-c++ installed, profile.d written, in that order" bash -c "a=\$(grep -n 'addrepo' '$LOG' | head -1 | cut -d: -f1); b=\$(grep -n 'dnf5 -y install cuda-toolkit gcc15-c++' '$LOG' | head -1 | cut -d: -f1); c=\$(grep -n 'tee /etc/profile.d/cuda.sh' '$LOG' | head -1 | cut -d: -f1); [ -n \"\$a\" ] && [ \"\$a\" -lt \"\$b\" ] && [ \"\$b\" -lt \"\$c\" ] && grep -q 'fedora44/x86_64' '$LOG' && grep -q 'NVCC_CCBIN=g++-15' '$LOG'"
check "cuda fresh: applied, undo line, check commands, never touches the host (no sudo, no brew, no rpm-ostree)" bash -c "grep -qE '^cuda +applied' '$root/out' && grep -q 'distrobox rm --force cuda' '$root/out' && grep -q 'nvcc --version' '$root/out' && grep -q 'distrobox enter cuda -- nvidia-smi' '$root/out' && ! grep -qE '^(sudo|brew|rpm-ostree)' '$LOG'"
: >"$LOG"
run '' --yes --only cuda
check "cuda second run: already done, nothing created or installed again" bash -c "[ $rc = 0 ] && grep -qE '^cuda +already done' '$root/out' && [ \$(grep -c '^distrobox create' '$LOG') = 0 ] && ! grep -q 'dnf5' '$LOG'"
cuda_world; : >"$STATE/cuda-container"; echo registry.fedoraproject.org/fedora-toolbox:44 >"$STATE/cuda-container"
run '' --yes --only cuda
check "cuda: an existing container without the toolkit is not recreated, the toolkit is installed in it" bash -c "[ $rc = 0 ] && ! grep -q '^distrobox create' '$LOG' && grep -q 'dnf5 -y install cuda-toolkit' '$LOG' && grep -qE '^cuda +applied' '$root/out'"
cuda_world
run '' --no --only cuda
check "cuda --no: plan only, nothing created, installed or written" bash -c "[ $rc = 0 ] && grep -q 'Plan: distrobox create' '$root/out' && grep -qE '^cuda +planned' '$root/out' && ! grep -qE '^distrobox (create|enter)' '$LOG'"
cuda_world; echo 2 >"$STATE/failn-install"
run '' --yes --only cuda
check "cuda: a failing install is retried and then succeeds" bash -c "[ $rc = 0 ] && [ \$(grep -c '^in-container:.*dnf5 -y install cuda-toolkit' '$LOG') = 3 ] && grep -qE '^cuda +applied' '$root/out'"
cuda_world; : >"$STATE/fail-install"
run '' --yes --only cuda
check "cuda: an install that always fails: three tries, FAILED, exit 1, re-run line, undo line, container kept" bash -c "[ $rc = 1 ] && [ \$(grep -c '^in-container:.*dnf5 -y install cuda-toolkit' '$LOG') = 3 ] && grep -qE '^cuda +FAILED' '$root/out' && grep -q 'ujust dev --only cuda' '$root/out' && grep -q 'distrobox rm --force cuda' '$root/out' && [ -f '$STATE/cuda-container' ]"
cuda_world; : >"$STATE/fail-create"
run '' --yes --only cuda
check "cuda: a container that cannot be created: three tries, FAILED, exit 1, nothing installed" bash -c "[ $rc = 1 ] && [ \$(grep -c '^distrobox create' '$LOG') = 3 ] && ! grep -q 'dnf5' '$LOG' && grep -qE '^cuda +FAILED' '$root/out'"
cuda_world; rm -rf "$root/cdi"
run '' --yes --only cuda
check "cuda: no host CDI spec: stops with the exact root command (not run), exit 1, no container" bash -c "[ $rc = 1 ] && grep -q 'sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml' '$root/out' && ! grep -qE '^(sudo|distrobox create)' '$LOG' && grep -qE '^cuda +FAILED' '$root/out'"
cuda_world
run '' --yes --only cuda --image docker.io/nvidia/cuda:13.0.0-devel-ubuntu24.04
check "cuda --image: that image is used and nothing is installed in it" bash -c "grep -q 'distrobox create --yes --name cuda --image docker.io/nvidia/cuda:13.0.0-devel-ubuntu24.04 ' '$LOG' && ! grep -q 'dnf5' '$LOG' && ! grep -q 'tee /etc/profile.d' '$LOG'"
check "cuda --image: a note when the image has no nvcc, still applied" bash -c "[ $rc = 0 ] && grep -q 'no nvcc found in docker.io/nvidia/cuda' '$root/out' && grep -qE '^cuda +applied' '$root/out'"
cuda_world; echo registry.example/x:1 >"$STATE/cuda-container"; : >"$STATE/cuda-toolkit"
run '' --yes --only cuda --image docker.io/nvidia/cuda:13.0.0-devel-ubuntu24.04
check "cuda --image with an existing toolkit container: already done, a note that --image applies at creation" bash -c "grep -qE '^cuda +already done' '$root/out' && grep -q 'only applies when the container is created' '$root/out'"
run '' --only cuda --image
check "--image without a value: exit 2" bash -c "[ $rc = 2 ] && grep -q -- '--image needs an image name' '$root/out'"
run '' --only cuda --image 'bad name;x'
check "--image with a bad name: exit 2" bash -c "[ $rc = 2 ] && grep -q 'Not an image name' '$root/out'"
cuda_world; : >"$STATE/fail-smi"
run '' --yes --only cuda
check "cuda: nvidia-smi failing inside the container is a note (unverified GPU path), not a failure" bash -c "[ $rc = 0 ] && grep -q 'GPU path is unverified' '$root/out' && grep -qE '^cuda +applied' '$root/out'"
reset
run '' --help
check "--help names the cuda step, --image and the CDI route" bash -c "grep -q '^  *cuda ' '$root/out' && grep -q -- '--image IMAGE' '$root/out' && grep -q 'nvidia.com/gpu=all' '$root/out'"
cuda_world
OCTARINE_MENU_FORCE_TTY=1 run '' 
check "menu: with a driver the cuda row is offered" bash -c "grep -q 'cuda^\\|CUDA toolkit in a rootless distrobox' '$LOG' || grep -q 'CUDA toolkit' '$LOG'"
reset
OCTARINE_MENU_FORCE_TTY=1 run ''
check "menu: without a driver there is no cuda row" bash -c "! grep -q 'CUDA toolkit' '$LOG'"
check "no recipe or script puts the CUDA toolkit or NVIDIA's CUDA repository on the host image" bash -c "! grep -rqiE 'cuda-toolkit|developer\.download\.nvidia\.com|cuda-nvcc' '$repo/build_files' '$repo/variants/nvidia' '$repo/variants/dx/dx.sh' '$repo/variants/dx/packages' '$repo/Containerfile'"

# run the import block of dx.sh against a fake main justfile, twice
blk="$root/importblock.sh"
{
    echo 'set -euo pipefail'
    sed -n '/^ujust_main=/,/^chmod 0755/p' "$repo/variants/dx/dx.sh" | sed '/^chmod/d' \
        | sed -e "s#/usr/share/ublue-os/justfile#$root/main.just#" -e "s#^test -s /usr/share/ublue-os/just/70-octarine-dev.just#test -s $root/70.just#"
} >"$blk"
printf 'import "/usr/share/ublue-os/just/00-default.just"\nimport? "/usr/share/ublue-os/just/60-custom.just"' >"$root/main.just"; echo x >"$root/70.just"
bash "$blk" >/dev/null 2>&1; r1=$?
bash "$blk" >/dev/null 2>&1; r2=$?
check "dx.sh import block: appended once (newline-safe), second run changes nothing" bash -c "[ $r1 = 0 ] && [ $r2 = 0 ] && [ \$(grep -c 70-octarine-dev '$root/main.just') = 1 ] && [ \$(wc -l <'$root/main.just') = 3 ]"
check "the dx justfile import works end to end with a real just (recipe listed through the main file)" bash -c "
  mkdir -p '$root/imp'; cp '$justfile' '$root/imp/70.just'
  printf 'import? \"%s/imp/70.just\"\n' '$root' >'$root/imp/main.just'
  [ \"\$('$REAL_JUST' --justfile '$root/imp/main.just' --summary)\" = dev ]"
prof="$dxfs/etc/profile.d/octarine-dx-cargo.sh"
mkdir -p "$root/h1/.cargo/bin" "$root/h2"
pathof() { HOME=$1 PATH=/usr/bin:/bin "$2" -c ". '$prof'; . '$prof'; echo \$PATH"; }
check "profile snippet: sh -n" sh -n "$prof"
check "profile snippet: adds ~/.cargo/bin at the END when the directory exists, once (sh)" test "$(pathof "$root/h1" sh)" = "/usr/bin:/bin:$root/h1/.cargo/bin"
check "profile snippet: bash behaves the same" test "$(pathof "$root/h1" bash)" = "/usr/bin:/bin:$root/h1/.cargo/bin"
if command -v zsh >/dev/null 2>&1; then
    check "profile snippet: zsh behaves the same" test "$(pathof "$root/h1" "$(command -v zsh)")" = "/usr/bin:/bin:$root/h1/.cargo/bin"
fi
check "profile snippet: guarded (no directory: PATH unchanged)" test "$(pathof "$root/h2" sh)" = "/usr/bin:/bin"
if command -v fish >/dev/null 2>&1; then
    ff="$repo/system_files/usr/share/fish/vendor_conf.d/octarine-os-30-rustup.fish"
    check "fish rustup snippet: --no-execute" fish --no-execute "$ff"
    fishbin=$(command -v fish)
    check "fish rustup snippet: appends ~/.cargo/bin when env.fish is absent and the directory exists" test "$(HOME="$root/h1" PATH=/usr/bin "$fishbin" --no-config -c "source $ff; contains $root/h1/.cargo/bin \$fish_user_paths; and echo yes")" = yes
    check "fish rustup snippet: silent and a no-op without ~/.cargo" test -z "$(HOME="$root/h2" PATH=/usr/bin "$fishbin" --no-config -c "source $ff" 2>&1)"
fi
check "the sdk wrapper is executable and shell-valid in the repo" bash -c "[ -x '$wrapper' ] && bash -n '$wrapper'"

# ---- the dx smoke script knows the dev files
check "the dx smoke test checks the dev recipe, its import, the sdk wrapper and the cargo snippet" bash -c "grep -q 'lists_dev' '$repo/.github/scripts/dx-smoke.sh' && grep -q '70-octarine-dev.just' '$repo/.github/scripts/dx-smoke.sh' && grep -q 'octarine-dx-cargo.sh' '$repo/.github/scripts/dx-smoke.sh' && grep -q 'bin_dir}/sdk' '$repo/.github/scripts/dx-smoke.sh'"

echo
echo "passed: $pass, failed: $failn"
[ "$failn" -eq 0 ]
