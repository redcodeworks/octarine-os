# vim: set ft=make :

# Add a user (default: you) to the gamemode, input and libvirt groups
add-user-groups $user=`id -un`:
    #!/usr/bin/env bash
    set -euo pipefail
    if ! [[ "$user" =~ ^[a-z_][a-z0-9_-]*$ ]] || ! id "$user" >/dev/null 2>&1; then
        echo "'$user' is not an existing user name"
        exit 1
    fi
    # gamemode and input only exist in /usr/lib/group, so copy their lines into
    # /etc/group first or usermod -aG would not see them.
    for g in gamemode input libvirt; do
        if ! getent group "$g" >/dev/null; then
            echo "Skipping $g: no such group on this system"
            continue
        fi
        sudo sh -c "grep -q '^$g:' /etc/group || grep '^$g:' /usr/lib/group >> /etc/group"
        if id -nG "$user" | tr ' ' '\n' | grep -qx "$g"; then
            echo "$user is already in $g"
        else
            sudo usermod -aG "$g" "$user"
            echo "Added $user to $g"
        fi
    done
    echo "Log out and back in for the new groups to apply."

# Make Flatpak Steam and the Flatpak gamescope layer work together
steam-gamescope-setup:
    #!/usr/bin/env bash
    set -euo pipefail
    app=com.valvesoftware.Steam
    ext=org.freedesktop.Platform.VulkanLayer.gamescope
    install=$(flatpak list --app --columns=application,installation | awk -v a="$app" '$1 == a {print $2; exit}')
    if [ -z "$install" ]; then
        echo "$app is not installed. Install it first: flatpak install flathub $app"
        exit 1
    fi
    # The layer's branch has to match the runtime branch Steam uses
    branch=$(flatpak info --show-runtime "$app" | cut -d/ -f3)
    echo "Steam runtime branch: $branch ($install install)"
    if ! flatpak info "$ext//$branch" >/dev/null 2>&1; then
        flatpak install --"$install" -y flathub "$ext//$branch"
    fi
    # Put the extension's bin directory on Steam's PATH so `gamescope` resolves inside the sandbox
    flatpak override --user \
        --env=PATH=/app/bin:/app/utils/bin:/usr/bin:/usr/lib/extensions/vulkan/gamescope/bin "$app"
    echo
    echo "Done. In Steam, set a game's launch options to, for example:"
    echo "  gamescope -f -W 2560 -H 1440 -r 144 --adaptive-sync -- %command%"
    echo "The Flatpak copy has no cap_sys_nice and no --backend drm; undo with: ujust steam-gamescope-reset"

# Undo steam-gamescope-setup (removes the PATH override; leaves the layer installed)
steam-gamescope-reset:
    #!/usr/bin/env bash
    set -euo pipefail
    # `flatpak override --unset-env=PATH` would not remove the override: it writes PATH= and
    # unsets PATH inside the sandbox. `--reset` would drop every other override too (filesystem
    # access, for one). So delete only the line steam-gamescope-setup added.
    file="${XDG_DATA_HOME:-$HOME/.local/share}/flatpak/overrides/com.valvesoftware.Steam"
    line='PATH=/app/bin:/app/utils/bin:/usr/bin:/usr/lib/extensions/vulkan/gamescope/bin'
    if [ -f "$file" ] && grep -qxF "$line" "$file"; then
        tmp=$(mktemp "$file.XXXXXX")
        grep -vxF "$line" "$file" > "$tmp" || true
        mv -- "$tmp" "$file"
        echo "Removed the PATH override from $file"
    else
        echo "No gamescope PATH override found in $file; nothing to do"
    fi

# EXPERIMENTAL: build extest (X11 XTEST to uinput shim for Steam Input on Wayland)
extest-build $src=`echo "$HOME/Repos/extest"` $dest=`echo "$HOME/.local/lib/extest"` $commit="cb77cd4f80f83393a24bae17dd975e14fa6eb1b2":
    #!/usr/bin/env bash
    set -euo pipefail
    # Lets Steam Input work on Wayland without the "Allow Remote Interaction" prompt.
    # Needs cargo and a C linker. Reuses an existing checkout in src, or clones upstream there,
    # pinned to the commit this setup was tested with.
    command -v cargo >/dev/null || { echo "cargo not found. Install Rust first (for example with rustup)."; exit 1; }
    [[ "$commit" =~ ^[0-9a-f]{40}$ ]] || { echo "commit must be a full 40-character SHA"; exit 1; }
    if [ ! -d "$src/.git" ]; then
        git clone https://github.com/Supreeeme/extest "$src"
    fi
    cd "$src"
    if [ "$(git rev-parse HEAD)" != "$commit" ]; then
        git fetch --quiet origin
        git checkout --quiet --detach "$commit"
    fi
    # The repo's .cargo/config.toml defaults to i686; Steam's client is 64-bit now, so build x86_64
    cargo build --release --locked --target x86_64-unknown-linux-gnu
    install -Dm755 target/x86_64-unknown-linux-gnu/release/libextest.so "$dest/lib64/libextest.so"
    echo "Installed $dest/lib64/libextest.so"
    echo "Next: ujust extest-steam-setup"

# EXPERIMENTAL: preload the built extest library into Flatpak Steam
extest-steam-setup $lib=`echo "$HOME/.local/lib/extest"`:
    #!/usr/bin/env bash
    set -euo pipefail
    # Not verified end to end inside the Flatpak client yet. Check that it loaded with:
    #   grep libextest /proc/$(pgrep -x steam | head -1)/maps
    lib=$(readlink -f -- "$lib")
    so="$lib/lib64/libextest.so"
    [ -f "$so" ] || { echo "$so not found. Run: ujust extest-build"; exit 1; }
    # Explicit 64-bit path: $LIB does not resolve inside the Flatpak runtime, and a 32-bit
    # library only logs "wrong ELF class" for every process it is preloaded into.
    flatpak override --user --filesystem="$lib:ro" --env=LD_PRELOAD="$so" com.valvesoftware.Steam
    echo "Steam will preload $so. Quit and relaunch Steam for it to take effect."
    echo "Undo with: ujust extest-steam-reset"

# Undo extest-steam-setup by deleting only its two entries from Steam's override file
extest-steam-reset $lib=`echo "$HOME/.local/lib/extest"`:
    #!/usr/bin/env bash
    set -euo pipefail
    lib=$(readlink -f -- "$lib")
    file="${XDG_DATA_HOME:-$HOME/.local/share}/flatpak/overrides/com.valvesoftware.Steam"
    [ -f "$file" ] || { echo "No override file at $file; nothing to do"; exit 0; }
    tmp=$(mktemp "$file.XXXXXX")
    grep -vxF "LD_PRELOAD=$lib/lib64/libextest.so" "$file" > "$tmp" || true
    # Literal (not regex) removal of the filesystem entry
    content=$(<"$tmp")
    content=${content//"$lib:ro;"/}
    printf '%s\n' "$content" > "$tmp"
    mv -- "$tmp" "$file"
    echo "Removed the extest entries from $file"

# Give the Flatpak game launchers (Steam, Bottles, Lutris) access to a games directory
flatpak-games-access $path=`echo "$HOME/Games"`:
    #!/usr/bin/env bash
    set -euo pipefail
    resolved=$(realpath -m -- "$path")
    home=$(realpath -m -- "$HOME")
    case "$resolved" in
        / | "$home" | /home | /var | /var/home | /usr | /etc | /boot | /root | /mnt | /media | /run | /tmp)
            echo "Refusing to expose $resolved to every game launcher. Pick a dedicated games directory."
            exit 1
            ;;
    esac
    mkdir -p -- "$resolved"
    for app in com.valvesoftware.Steam com.usebottles.bottles net.lutris.Lutris; do
        flatpak override --user --filesystem="$resolved" "$app"
    done
    echo "Steam, Bottles and Lutris can now use $resolved"

# Let Flatpak Steam see USB and input devices (controllers)
steam-flatpak-devices:
    #!/usr/bin/env bash
    set -euo pipefail
    # These widen the sandbox. Skip it if you do not need controller support beyond what Steam Input does
    flatpak override --user --device=usb --device=input com.valvesoftware.Steam
    echo "Flatpak Steam can now access USB and input devices"

# Let Flatpak VS Code use Wayland and the rootless Podman socket (for dev containers)
vscode-flatpak-podman:
    #!/usr/bin/env bash
    set -euo pipefail
    flatpak override --user --socket=wayland --filesystem=xdg-run/podman com.visualstudio.code
    echo "VS Code can reach \$XDG_RUNTIME_DIR/podman. Enable it with: systemctl --user enable --now podman.socket"

# Stop Podman Desktop from reaching a Docker socket (it should only talk to Podman)
podman-desktop-deny-docker-socket:
    #!/usr/bin/env bash
    set -euo pipefail
    flatpak override --user --nofilesystem=/run/docker.sock io.podman_desktop.PodmanDesktop
    echo "Podman Desktop can no longer access /run/docker.sock"

# Let Flatpak Chrome install web apps as launchers (writes desktop entries and icons)
chrome-flatpak-webapps:
    #!/usr/bin/env bash
    set -euo pipefail
    flatpak override --user \
        --filesystem=~/.local/share/applications \
        --filesystem=~/.local/share/icons \
        com.google.Chrome
    echo "Chrome can now write web app launchers to ~/.local/share/applications"

# Let Gear Lever manage AppImages in ~/Applications
gearlever-applications:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p "$HOME/Applications"
    flatpak override --user --filesystem=~/Applications it.mijorus.gearlever
    echo "Gear Lever can now use ~/Applications"

# Run a recipe of github.com/redcodeworks/gnome-themes from a fresh checkout, e.g. `ujust gnome-themes install-themes` or `ujust gnome-themes switch-icons Papirus-Dark` (no arguments lists them). Themes and icons are not part of the image. Needs network, git and just. GNOME_THEMES_REF picks a branch, tag or commit (default main)
[positional-arguments]
gnome-themes *args:
    #!/usr/bin/env bash
    set -euo pipefail
    url="${GNOME_THEMES_URL:-https://github.com/redcodeworks/gnome-themes.git}"
    ref="${GNOME_THEMES_REF:-main}"
    dir="${XDG_CACHE_HOME:-$HOME/.cache}/gnome-themes/repo"
    if [ -d "$dir/.git" ]; then
        git -C "$dir" remote set-url origin "$url"
        git -C "$dir" fetch --quiet --tags origin
    else
        mkdir -p "$(dirname "$dir")"
        git clone --quiet "$url" "$dir"
    fi
    git -C "$dir" checkout --quiet --detach "$(git -C "$dir" rev-parse --verify --quiet "origin/$ref" || echo "$ref")"
    exec just --justfile "$dir/justfile" --working-directory "$dir" "$@"

# Install user-level package managers (uv, brew, SDKMAN, nvm, rustup, pixi) from a checklist: `ujust user-package-managers` (SPACE toggles, ENTER confirms, q cancels), or name them: `ujust user-package-managers brew rustup`. `--list` shows what is installed and exported, `--force` installs even if present. SDKMAN, nvm, uv and rustup install inside the fedora-toolbox distrobox and rustup and sdk are exported to ~/.local/bin. Each installer is downloaded to a file, hashed, shown on request and run only after you answer y, with sudo blocked. Nothing here edits your shell rc files or runs as root
[positional-arguments]
user-package-managers *args:
    #!/usr/bin/env bash
    set -euo pipefail

    box="${UPM_BOX:-fedora-toolbox}"
    brew_prefix="${UPM_BREW_PREFIX:-/home/linuxbrew/.linuxbrew}"
    tty_in="${UPM_TTY:-/dev/tty}"
    export_dir="${UPM_EXPORT_DIR:-$HOME/.local/bin}"
    state_file="${XDG_STATE_HOME:-$HOME/.local/state}/ublue-os/user-package-managers"

    # One row per tool, fields separated by ^ :
    #   id ^ label ^ installer URL (https) ^ target (host or toolbox) ^ installed test
    #   ^ environment for the installer ^ installer arguments ^ preselected (1/0)
    #   ^ exports to the host ^ note
    # Exports (toolbox tools only), space separated: bin:PATH exports one binary, dir:PATH every executable
    # in a directory (listed after the install), wrapper:sdk writes the sdk wrapper script.
    # The installed test runs in a subshell on the host (the toolbox shares your home).
    # __PREFIX__ in a note is the brew prefix.
    rows=(
        'uv^uv (Python)^https://astral.sh/uv/install.sh^toolbox^[ -x "$HOME/.local/bin/uv" ]^UV_NO_MODIFY_PATH=1^^1^bin:$HOME/.local/bin/uv bin:$HOME/.local/bin/uvx^uv and uvx are installed straight into ~/.local/bin, which the host already uses (shared home).'
        'brew^Homebrew^https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh^host^[ -x "$brew_prefix/bin/brew" ]^NONINTERACTIVE=1^^1^^Put brew on PATH yourself.\n  bash: add to ~/.bashrc:  eval "$(__PREFIX__/bin/brew shellenv)"\n  fish: add to ~/.config/fish/config.fish:  eval (__PREFIX__/bin/brew shellenv)\nKeep system binaries ahead of brew on PATH (shellenv puts brew first; append it instead if that matters).'
        'sdkman^SDKMAN^https://get.sdkman.io?rcupdate=false^toolbox^[ -s "$HOME/.sdkman/bin/sdkman-init.sh" ]^^^1^wrapper:sdk^sdk is a shell function, so the host gets a small wrapper script that runs it in the box.\nInside the box, add to its shell rc:  source "$HOME/.sdkman/bin/sdkman-init.sh"'
        'nvm^nvm^https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh^toolbox^[ -s "${NVM_DIR:-$HOME/.nvm}/nvm.sh" ]^PROFILE=/dev/null^^1^^Nothing is exported: host node and npm stay brew'"'"'s.\nInside the box, add to its shell rc:\n  export NVM_DIR="$HOME/.nvm"\n  [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"'
        'rustup^rustup (Rust)^https://sh.rustup.rs^toolbox^[ -x "$HOME/.cargo/bin/rustup" ]^^-y --no-modify-path^1^dir:$HOME/.cargo/bin^The rustup proxies in ~/.cargo/bin are exported to the host.\nInside the box, add to its shell rc:  . "$HOME/.cargo/env"'
        'pixi^pixi (optional)^https://pixi.sh/install.sh^host^[ -x "$HOME/.pixi/bin/pixi" ]^PIXI_NO_PATH_UPDATE=1^^0^^Put pixi on PATH yourself.\n  bash: add to ~/.bashrc:  export PATH="$HOME/.pixi/bin:$PATH"\n  fish: fish_add_path $HOME/.pixi/bin'
    )

    ids=()
    for r in "${rows[@]}"; do ids+=("${r%%^*}"); done

    load() {
        local r
        for r in "${rows[@]}"; do
            IFS='^' read -r id label url target check envs iargs def exports note <<<"$r"
            [ "$id" = "$1" ] && return 0
        done
        return 1
    }

    state() {
        load "$1"
        if (eval "$check") >/dev/null 2>&1; then
            echo installed
        else
            echo missing
        fi
    }

    # Source paths this tool exports (one per line, wrapper entries as wrapper:NAME). Needs the tool installed
    export_sources() {
        local item d f
        load "$1"
        for item in $exports; do
            case "$item" in
                bin:*) eval "printf '%s\n' \"${item#bin:}\"" ;;
                wrapper:*) printf '%s\n' "$item" ;;
                dir:*)
                    eval "d=\"${item#dir:}\""
                    for f in "$d"/*; do
                        if [ -f "$f" ] && [ -x "$f" ]; then printf '%s\n' "$f"; fi
                    done
                    ;;
            esac
        done
    }

    export_name() {
        case "$1" in
            wrapper:*) echo "${1#wrapper:}" ;;
            *) basename -- "$1" ;;
        esac
    }

    # yes, partial, no or - (nothing to export)
    export_state() {
        local s n=0 ok=0 dest
        [ -n "$(
            load "$1"
            echo "$exports"
        )" ] || {
            echo "-"
            return 0
        }
        while IFS= read -r s; do
            [ -n "$s" ] || continue
            n=$((n + 1))
            dest="$export_dir/$(export_name "$s")"
            if [ "$s" = "$dest" ]; then
                ok=$((ok + 1))
            elif [ -e "$dest" ] && grep -qxF -- "$dest" "$state_file" 2>/dev/null; then
                ok=$((ok + 1))
            fi
        done < <(export_sources "$1")
        if [ "$n" -eq 0 ] || [ "$ok" -eq 0 ]; then
            echo no
        elif [ "$ok" -eq "$n" ]; then
            echo yes
        else
            echo partial
        fi
    }

    usage() {
        echo "Usage: ujust user-package-managers [--list] [--force] [tool ...]"
        echo "Tools: ${ids[*]}"
        echo "With no tools it shows a checklist (SPACE toggles, ENTER confirms, q cancels)."
    }

    list_tools() {
        local t st ex
        printf '%-8s %-10s %-9s %-8s %s\n' TOOL STATE EXPORTED TARGET LABEL
        for t in "${ids[@]}"; do
            load "$t"
            st=$(state "$t")
            if [ "$st" = installed ]; then ex=$(export_state "$t"); else ex=-; fi
            printf '%-8s %-10s %-9s %-8s %s\n' "$id" "$st" "$ex" "$target" "$label"
        done
    }

    force=0
    want=()
    for a in "$@"; do
        case "$a" in
            --list)
                list_tools
                exit 0
                ;;
            -h | --help)
                usage
                exit 0
                ;;
            --force) force=1 ;;
            -*)
                echo "Unknown option $a" >&2
                usage >&2
                exit 2
                ;;
            *)
                if [[ " ${ids[*]} " != *" $a "* ]]; then
                    echo "Unknown tool '$a'" >&2
                    usage >&2
                    exit 2
                fi
                want+=("$a")
                ;;
        esac
    done

    if [ "$(id -u)" -eq 0 ]; then
        echo "Do not run this as root: these tools install into your home directory." >&2
        exit 1
    fi

    # Keys and answers come from the terminal (or UPM_TTY in tests), not from stdin
    if ! (: <"$tty_in") 2>/dev/null; then
        echo "No terminal to read answers from; run this in an interactive shell." >&2
        exit 1
    fi
    exec 3<"$tty_in"

    work=$(mktemp -d "${TMPDIR:-/tmp}/upm.XXXXXX")
    chmod 700 "$work"
    cleanup() {
        rm -rf -- "$work"
        if [ -t 1 ]; then printf '\033[?25h'; fi
    }
    trap cleanup EXIT
    trap 'exit 130' INT TERM

    states=()
    sel=()
    cur=-1

    draw() {
        local i m p s
        for i in "${!ids[@]}"; do
            load "${ids[i]}"
            s=""
            case "${states[i]}" in
                installed)
                    m='[-]'
                    s="  (installed)"
                    ;;
                *) if [ "${sel[i]}" = 1 ]; then m='[x]'; else m='[ ]'; fi ;;
            esac
            if [ "$i" -eq "$cur" ]; then p='>'; else p=' '; fi
            printf '\033[2K%s %s %s [%s]%s\n' "$p" "$m" "$label" "$target" "$s"
        done
        printf '\033[2K  SPACE toggles, ENTER installs the ticked ones, q cancels\n'
    }

    move() {
        local d=$1 i=$cur n=${#ids[@]}
        while :; do
            i=$(((i + d + n) % n))
            if [ "${states[i]}" = missing ]; then
                cur=$i
                return 0
            fi
            if [ "$i" -eq "$cur" ]; then return 0; fi
        done
    }

    checklist() {
        local i key rest any=0
        for i in "${!ids[@]}"; do
            states[i]=$(state "${ids[i]}")
            load "${ids[i]}"
            sel[i]=0
            if [ "${states[i]}" = missing ]; then
                any=1
                if [ "$def" = 1 ]; then sel[i]=1; fi
                if [ "$cur" -lt 0 ]; then cur=$i; fi
            fi
        done
        if [ "$any" = 0 ]; then
            echo "Everything on the list is already installed."
            return 1
        fi
        echo "User-level package managers"
        if [ -t 1 ]; then
            printf '\033[?25l'
            draw
        fi
        while :; do
            key=""
            IFS= read -rsn1 -u 3 key || key=EOF
            case "$key" in
                EOF | q | Q)
                    if [ -t 1 ]; then printf '\033[?25h'; fi
                    echo "Cancelled."
                    return 1
                    ;;
                '') break ;;
                ' ')
                    if [ "${states[cur]}" = missing ]; then sel[cur]=$((1 - sel[cur])); fi
                    ;;
                j | J) move 1 ;;
                k | K) move -1 ;;
                $'\x1b')
                    rest=""
                    IFS= read -rsn2 -t 0.05 -u 3 rest || true
                    case "$rest" in
                        '[A') move -1 ;;
                        '[B') move 1 ;;
                    esac
                    ;;
            esac
            if [ -t 1 ]; then
                printf '\033[%dA' $((${#ids[@]} + 1))
                draw
            fi
        done
        if [ -t 1 ]; then printf '\033[?25h'; fi
        for i in "${!ids[@]}"; do
            if [ "${sel[i]}" = 1 ]; then want+=("${ids[i]}"); fi
        done
        if [ "${#want[@]}" -eq 0 ]; then
            echo "Nothing ticked."
            return 1
        fi
        return 0
    }

    ans=""
    ask() {
        while :; do
            printf '%s' "$1"
            IFS= read -rsn1 -u 3 ans || ans=n
            printf '%s\n' "$ans"
            case "$ans" in
                v | V)
                    read -ra pg <<<"${PAGER:-less}"
                    command -v "${pg[0]}" >/dev/null 2>&1 || pg=(cat)
                    "${pg[@]}" "$2" || true
                    ;;
                y | Y)
                    ans=y
                    return 0
                    ;;
                *) return 1 ;;
            esac
        done
    }

    box_exists() {
        command -v distrobox >/dev/null 2>&1 &&
            distrobox list 2>/dev/null | awk -F'|' 'NR > 1 { gsub(/ /, "", $2); print $2 }' | grep -qx -- "$box"
    }

    show_brew_setup() {
        local home_real
        home_real=$(readlink -f /home)
        echo "   Homebrew's prefix ($brew_prefix) must exist and belong to you, because this recipe never uses sudo."
        echo "   Run this once yourself, then run this recipe again:"
        echo "     sudo mkdir -p $home_real/linuxbrew/.linuxbrew && sudo chown -R $(id -un): $home_real/linuxbrew"
        if [ "$home_real" != /home ]; then
            echo "   (/home is a symlink to $home_real here, so the path above is the real one.)"
        fi
    }

    failed=0

    # Record a file this recipe created, so that undoing is exact
    record() {
        mkdir -p -- "$(dirname -- "$state_file")"
        printf '%s\n' "$1" >>"$state_file"
    }

    # Export what the tool provides to the host. Never overwrites anything that exists.
    do_exports() {
        local t=$1 s name dest created=0 bn
        load "$t"
        [ -n "$exports" ] || return 0
        mkdir -p -- "$export_dir"
        while IFS= read -r s; do
            [ -n "$s" ] || continue
            name=$(export_name "$s")
            dest="$export_dir/$name"
            if [ "$s" = "$dest" ]; then
                echo "   $name is already in $export_dir, nothing to export."
                continue
            fi
            if [ -e "$dest" ] || [ -L "$dest" ]; then
                if grep -qxF -- "$dest" "$state_file" 2>/dev/null; then
                    echo "   $dest is already exported."
                else
                    echo "   Skipped $dest: a file or link is already there (not overwritten)."
                fi
                continue
            fi
            case "$s" in
                wrapper:sdk)
                    {
                        printf '#!/bin/bash\n'
                        printf 'exec distrobox enter %q -- bash -c %q _ "$@"\n' "$box" 'source ~/.sdkman/bin/sdkman-init.sh && sdk "$@"'
                    } >"$dest"
                    chmod 755 "$dest"
                    ;;
                *)
                    bn=$(basename -- "$s")
                    if ! distrobox enter "$box" -- distrobox-export --bin "$s" --export-path "$export_dir" </dev/null >/dev/null 2>&1 || [ ! -e "$export_dir/$bn" ]; then
                        echo "   Could not export $s with distrobox-export."
                        failed=1
                        continue
                    fi
                    ;;
            esac
            record "$dest"
            created=$((created + 1))
            echo "   Exported $dest"
        done < <(export_sources "$t")
        if [ "$created" -gt 0 ]; then
            echo "   To undo: delete the exported files, which are listed in $state_file"
        fi
    }

    install_one() {
        local t=$1 st file sum size envarr=() argarr=() e a rc log runner
        load "$t"
        st=$(state "$t")
        if [ "$st" != missing ] && [ "$force" = 0 ]; then
            echo "== $label: already installed, skipping"
            if [ "$target" = toolbox ] && box_exists; then do_exports "$t"; fi
            return 0
        fi
        echo "== $label"
        if [ "$target" = toolbox ] && ! box_exists; then
            echo "   The distrobox '$box' does not exist (or distrobox is missing). Create it first; skipping $label."
            failed=1
            return 0
        fi
        if [ "$t" = brew ] && ! { [ -d "$brew_prefix" ] && [ -w "$brew_prefix" ] && [ -O "$brew_prefix" ]; }; then
            show_brew_setup
            failed=1
            return 0
        fi
        case "$url" in
            https://*) ;;
            *)
                echo "   Refusing a non-https installer URL: $url"
                failed=1
                return 0
                ;;
        esac
        file="$work/$t-installer.sh"
        echo "   Downloading $url"
        if ! curl -fsSL --proto '=https' --tlsv1.2 -o "$file" "$url"; then
            echo "   Download failed; skipping $label."
            failed=1
            return 0
        fi
        sum=$(sha256sum "$file" | cut -d' ' -f1)
        size=$(stat -c %s "$file")
        echo "   sha256 $sum"
        echo "   size   $size bytes"
        echo "   This is vendor code, not ours: running it means you trust $url."
        if ! ask "   [v] view it, [y] run it, anything else skips: " "$file"; then
            echo "   Skipped $label."
            return 0
        fi

        # The installer gets a sudo stub first on PATH, and runs with no_new_privs so that
        # even an absolute /usr/bin/sudo (Homebrew's installer uses one) cannot gain privileges.
        mkdir -p "$work/bin"
        {
            printf '#!/bin/sh\n'
            printf 'echo "sudo is not allowed here" >&2\n'
            printf ': > %q\n' "$work/sudo-called"
            printf 'exit 1\n'
        } >"$work/bin/sudo"
        chmod 700 "$work/bin/sudo"
        rm -f "$work/sudo-called"
        read -ra envarr <<<"$envs"
        read -ra argarr <<<"$iargs"
        runner="$work/run-$t.sh"
        {
            printf '#!/bin/bash\nset -eu\n'
            printf 'command -v setpriv >/dev/null 2>&1 || { echo "setpriv is missing, refusing to run an installer without the no-sudo guard" >&2; exit 97; }\n'
            printf 'export PATH=%q:"$PATH"\n' "$work/bin"
            for e in "${envarr[@]}"; do printf 'export %s=%q\n' "${e%%=*}" "${e#*=}"; done
            printf 'exec setpriv --no-new-privs bash %q' "$file"
            for a in "${argarr[@]}"; do printf ' %q' "$a"; done
            printf '\n'
        } >"$runner"
        log="$work/$t.log"
        rc=0
        if [ "$target" = toolbox ]; then
            distrobox enter "$box" -- bash "$runner" </dev/null 2>&1 | tee "$log" || rc=${PIPESTATUS[0]}
        else
            bash "$runner" </dev/null 2>&1 | tee "$log" || rc=${PIPESTATUS[0]}
        fi
        if [ "$rc" -ne 0 ]; then
            if [ "$rc" -eq 97 ]; then
                echo "   $label was not run: setpriv is missing, so the no-sudo guard could not be applied."
            elif [ -e "$work/sudo-called" ] || grep -qiE 'sudo|no new privileges|no_new_privs' "$log"; then
                echo "   $label failed because the installer wanted sudo, which this recipe blocks on purpose."
                echo "   Do the root-only step yourself (see the installer's message above), then run this again."
            else
                echo "   $label failed (exit $rc)."
            fi
            failed=1
            return 0
        fi
        if [ "$(state "$t")" = missing ]; then
            echo "   The installer finished but $label is still not detected; check its output above."
            failed=1
            return 0
        fi
        echo "   Installed $label."
        if [ "$target" = toolbox ]; then do_exports "$t"; fi
        if [ -n "$note" ]; then
            printf '%b\n' "${note//__PREFIX__/$brew_prefix}" | sed 's/^/   /'
        fi
    }

    if [ "${#want[@]}" -eq 0 ]; then
        checklist || exit 0
    fi
    echo "Installers are vendor scripts. Each one is downloaded to a file, hashed and shown to you before it runs."
    for t in "${want[@]}"; do
        install_one "$t"
    done
    exit "$failed"
