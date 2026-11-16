#!/usr/bin/env bash
# Thin test for `ujust dev`: only the root refusal, the plan mode and the libvirt delegation (no sudo of its own), plus one smoke. The tool installs show when the recipe is run.
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
export DEV_EXPORT_DIR="$root/exportbin" OCTARINE_BOX_EXPORT_LIB="$repo/system_files/usr/share/octarine-os/lib/box-export.sh"
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
            "bash -lc command -v nvcc") [ -f "$STATE/cuda-toolkit" ] && echo /usr/local/cuda/bin/nvcc; exit 0 ;;
            "distrobox-export --bin "*)
                set -- $cmd; path=$3; dir=$5; act=${6:-}
                if [ "$act" = --unexport ]; then rm -f "$dir/$(basename "$path")"; else mkdir -p "$dir"; printf '#!/bin/sh\n# distrobox_binary\n# name: cuda\n' >"$dir/$(basename "$path")"; fi
                exit 0
                ;;
            *"tee /etc/profile.d/cuda.sh"*) flagged profile && exit 1; : >"$STATE/cuda-profile" ;;
            *"test -f /etc/profile.d/cuda.sh"*) [ -f "$STATE/cuda-profile" ]; exit $? ;;
            *"nvcc"*) [ -f "$STATE/cuda-toolkit" ]; exit $? ;;
            *"dnf5 -y install"*) flagged install && exit 1; : >"$STATE/cuda-toolkit" ;;
            *cuda-fedora44.repo*) flagged repo && exit 1; : >"$STATE/cuda-repo" ;;
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
    rm -rf "$root/cdi" "$root/exportbin"; rm -f "$STATE"/nvidia "$STATE"/cuda-container "$STATE"/cuda-toolkit "$STATE"/cuda-profile "$STATE"/cuda-repo
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
mkdir -p "$root/ujbin"; printf '#!/bin/bash\necho "ujust $*" >>"$LOG"\n[ "${FAKE_VIRTHOST_FAIL:-}" = 1 ] && exit 1\nexit 0\n' >"$root/ujbin/ujust"; chmod +x "$root/ujbin/ujust"; export OCTARINE_UJUST="$root/ujbin/ujust"
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { failn=$((failn + 1)); echo "FAIL $1"; sed 's/^/     /' "$root/out" 2>/dev/null | tail -40; }
check() { local d=$1; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
has() { grep -qF -- "$1" "$root/out"; }
hasnt() { ! grep -qF -- "$1" "$root/out"; }
logged() { grep -qF -- "$1" "$LOG"; }
notlogged() { ! grep -qF -- "$1" "$LOG"; }
row() { grep -qE "^$1 +$2" "$root/out"; }  # summary row: step, result prefix

reset
run '' --bogus
check "unknown option: exit 2" test "$rc" = 2
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
check "fresh --yes: every attempted step applied, exit 0" bash -c "[ $rc = 0 ] && for s in tools vscode jetbrains rust java node python; do grep -qE \"^\$s +applied\" '$root/out' || exit 1; done"

# ---- libvirt: delegated to ujust virthost-setup (the implementation and its tests live in tests/virthost-setup.sh)
mkdir -p "$root/ujbin"
printf '#!/bin/bash\necho "ujust $*" >>"$LOG"\n[ "${FAKE_VIRTHOST_FAIL:-}" = 1 ] && exit 1\nexit 0\n' >"$root/ujbin/ujust"; chmod +x "$root/ujbin/ujust"
: >"$LOG"; OCTARINE_UJUST="$root/ujbin/ujust" run '' --only libvirt
check "libvirt step delegates to ujust virthost-setup --only daemons,connection and runs no sudo itself" bash -c "grep -qx 'ujust virthost-setup --only daemons,connection' '$LOG' && ! grep -q '^sudo' '$LOG' && grep -q 'delegated' '$root/out'"
: >"$LOG"; OCTARINE_UJUST="$root/ujbin/ujust" run '' --only libvirt --no
check "libvirt --no passes --no on (a plan only)" grep -qx 'ujust virthost-setup --only daemons,connection --no' "$LOG"
: >"$LOG"; OCTARINE_UJUST="$root/ujbin/ujust" run '' --yes
check "--yes alone skips the libvirt step (it needs sudo) and says how to run it" bash -c "! grep -q virthost-setup '$LOG' && grep -q 'ujust dev --only libvirt --yes' '$root/out'"
reset
run '' --no --only tools
check "tools --no: nothing installed, plan printed" bash -c "[ $rc = 0 ] && ! grep -q '^brew install' '$LOG' && grep -q 'To install: helix' '$root/out' && grep -qE '^tools +planned' '$root/out'"
reset
run '' --no --only vscode
check "vscode --no: plan only" bash -c "! grep -q 'flatpak install' '$LOG' && grep -qE '^vscode +planned' '$root/out'"
run '' --no
check "--no: every step shows planned or already done" bash -c "for s in libvirt tools vscode jetbrains rust java node python; do grep -qE \"^\$s +(planned|already done)\" '$root/out' || exit 1; done"
reset
FAKE_UID=0 run '' --yes --only python
check "root is refused" bash -c "[ $rc = 1 ] && grep -q 'not as root' '$root/out' && ! grep -q 'uv python' '$LOG'"
echo
echo "passed: $pass, failed: $failn"
[ "$failn" -eq 0 ]
