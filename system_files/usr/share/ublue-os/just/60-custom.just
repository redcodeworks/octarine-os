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

# Install Homebrew on the host (never baked into the image: its prefix must belong to the user who runs it). The prefix /home/linuxbrew/.linuxbrew has to exist and be yours first; if not, the one-time sudo commands are printed for you to run. The installer is downloaded to a file, hashed, shown on request and run only after you answer y, with sudo blocked. Nothing here edits your shell rc files
brew:
    #!/usr/bin/env bash
    set -euo pipefail

    brew_prefix="${UPM_BREW_PREFIX:-/home/linuxbrew/.linuxbrew}"
    tty_in="${UPM_TTY:-/dev/tty}"
    url="https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh"

    shellenv_note() {
        echo "Put brew on PATH yourself (this recipe does not edit rc files):"
        echo "  bash: add to ~/.bashrc:  eval \"\$($brew_prefix/bin/brew shellenv)\""
        echo "  fish: add to ~/.config/fish/config.fish:  eval ($brew_prefix/bin/brew shellenv)"
        echo "shellenv puts brew first on PATH; append it instead if system binaries must win."
    }

    if [ "$(id -u)" -eq 0 ]; then
        echo "Do not run this as root: Homebrew belongs to your user." >&2
        exit 1
    fi
    if [ -x "$brew_prefix/bin/brew" ]; then
        echo "Homebrew is already installed in $brew_prefix."
        shellenv_note
        exit 0
    fi
    if ! { [ -d "$brew_prefix" ] && [ -w "$brew_prefix" ] && [ -O "$brew_prefix" ]; }; then
        home_real=$(readlink -f /home)
        echo "Homebrew's prefix ($brew_prefix) must exist and belong to you, because this recipe never uses sudo."
        echo "Run this once yourself, then run this recipe again:"
        echo "  sudo mkdir -p $home_real/linuxbrew/.linuxbrew && sudo chown -R $(id -un): $home_real/linuxbrew"
        if [ "$home_real" != /home ]; then
            echo "(/home is a symlink to $home_real here, so the path above is the real one.)"
        fi
        exit 1
    fi
    if ! (: <"$tty_in") 2>/dev/null; then
        echo "No terminal to read answers from; run this in an interactive shell." >&2
        exit 1
    fi
    exec 3<"$tty_in"

    work=$(mktemp -d "${TMPDIR:-/tmp}/brew.XXXXXX")
    chmod 700 "$work"
    trap 'rm -rf -- "$work"' EXIT
    trap 'exit 130' INT TERM

    file="$work/install.sh"
    echo "Downloading $url"
    curl -fsSL --proto '=https' --tlsv1.2 -o "$file" "$url" || { echo "Download failed."; exit 1; }
    echo "sha256 $(sha256sum "$file" | cut -d' ' -f1)"
    echo "size   $(stat -c %s "$file") bytes"
    echo "This is vendor code, not ours: running it means you trust $url."
    while :; do
        printf '[v] view it, [y] run it, anything else cancels: '
        IFS= read -rsn1 -u 3 ans || ans=n
        printf '%s\n' "$ans"
        case "$ans" in
            v | V)
                read -ra pg <<<"${PAGER:-less}"
                command -v "${pg[0]}" >/dev/null 2>&1 || pg=(cat)
                "${pg[@]}" "$file" || true
                ;;
            y | Y) break ;;
            *)
                echo "Cancelled."
                exit 0
                ;;
        esac
    done

    # sudo stub first on PATH, and no_new_privs so even /usr/bin/sudo (which Homebrew's
    # installer calls by absolute path) cannot gain privileges
    command -v setpriv >/dev/null 2>&1 || { echo "setpriv is missing, refusing to run an installer without the no-sudo guard." >&2; exit 1; }
    mkdir -p "$work/bin"
    {
        printf '#!/bin/sh\n'
        printf 'echo "sudo is not allowed here" >&2\n'
        printf ': > %q\n' "$work/sudo-called"
        printf 'exit 1\n'
    } >"$work/bin/sudo"
    chmod 700 "$work/bin/sudo"
    rc=0
    PATH="$work/bin:$PATH" NONINTERACTIVE=1 setpriv --no-new-privs bash "$file" </dev/null 2>&1 | tee "$work/log" || rc=${PIPESTATUS[0]}
    if [ "$rc" -ne 0 ]; then
        if [ -e "$work/sudo-called" ] || grep -qiE 'sudo|no new privileges|no_new_privs' "$work/log"; then
            echo "Homebrew failed because the installer wanted sudo, which this recipe blocks on purpose."
            echo "Do the root-only step yourself (see the message above), then run this again."
        else
            echo "Homebrew failed (exit $rc)."
        fi
        exit 1
    fi
    if [ ! -x "$brew_prefix/bin/brew" ]; then
        echo "The installer finished but $brew_prefix/bin/brew is missing; check its output above."
        exit 1
    fi
    echo "Installed Homebrew in $brew_prefix."
    shellenv_note
    echo "If you use the dev toolbox, run: ujust dev-toolbox --recreate (adds the read-only brew mount)."
    echo "To undo: run Homebrew's uninstall script (https://raw.githubusercontent.com/Homebrew/install/HEAD/uninstall.sh),"
    echo "delete the shellenv lines you added to your rc files, and remove the prefix directory if you want it gone."

# Build the development toolbox (fedora-toolbox distrobox) from the definition the image ships, make it the default for distrobox enter, set up uv, rustup, SDKMAN and nvm in it from a checklist (SPACE toggles, ENTER confirms, q skips; or name them: `ujust dev-toolbox sdkman nvm`) and export the build chain and CLI tools to ~/.local/bin. `--list` shows state, `--recreate` replaces the box (home is shared and survives), `--force` re-runs installers, `--upgrade` pulls the latest toolbox image and replaces the box if it is newer (`--upgrade --check` only reports), `--update` runs the package updates inside the existing box, `--ide [names]` (or `--ide-custom NAME COMMAND [ICON]`) creates launchers that start JetBrains IDEs or VS Code inside the box, `--remove` (with `--dry-run` to preview) destroys the box and removes only what the recipe recorded as created, after you type yes. The box is created from the image ghcr.io/redcodeworks/fedora-toolbox (its packages, including uv and rustup-init, are baked in and rebuilt weekly); rustup itself is set up in your home by running rustup-init after you confirm (a normal download from static.rust-lang.org); only SDKMAN and nvm use vendor installer scripts, each downloaded, hashed, shown on request and run only after y, with sudo blocked. Nothing here edits your shell rc files or runs as root. DEV_TOOLBOX_IMAGE overrides the image reference (for example ghcr.io/redcodeworks/fedora-toolbox:testing); the recipe prints the image it uses. To try it from a checkout before the image ships it, run `just --justfile system_files/usr/share/ublue-os/just/60-custom.just dev-toolbox` with DEV_TOOLBOX_DEFINITION pointing at system_files/usr/share/ublue-os/distrobox/fedora-toolbox.ini (default is the installed /usr/share/ublue-os/distrobox/fedora-toolbox.ini). To start clean, `distrobox rm --force fedora-toolbox` first (or use --recreate): the shared home survives, the container's own filesystem does not
[positional-arguments]
dev-toolbox *args:
    #!/usr/bin/env bash
    set -euo pipefail

    box="${UPM_BOX:-fedora-toolbox}"
    def_file="${DEV_TOOLBOX_DEFINITION:-/usr/share/ublue-os/distrobox/fedora-toolbox.ini}"
    image_override="${DEV_TOOLBOX_IMAGE:-}"
    conf_file="${UPM_CONF:-${XDG_CONFIG_HOME:-$HOME/.config}/distrobox/distrobox.conf}"
    brew_dir="${UPM_BREW_DIR:-/home/linuxbrew}"
    tty_in="${UPM_TTY:-/dev/tty}"
    export_dir="${UPM_EXPORT_DIR:-$HOME/.local/bin}"
    state_file="${XDG_STATE_HOME:-$HOME/.local/state}/ublue-os/dev-toolbox"

    # One row per tool or group, fields separated by ^ :
    #   id ^ label ^ source (image, installer or group) ^ tool name or installer URL ^ installed test
    #   ^ environment for the installer ^ installer arguments ^ preselected (1/0) ^ exports ^ note
    # image rows are baked into the toolbox image (packages/dev.txt in the fedora-toolbox repo); the recipe
    # cannot install packages (that would need sudo), it only sets them up and exports them. Group rows are exported without a checklist.
    # Exports, space separated: cmd:NAME exports the binary command -v finds in the box (skipped when absent),
    # dir:PATH every executable in a directory, wrapper:sdk writes the sdk wrapper script.
    # The installed test runs on the host (the box shares your home); where[NAME] holds what command -v found in the box.
    # __PREFIX__ in a note is the brew prefix.
    rows=(
        'uv^uv (Python)^image^uv^[ -n "${where[uv]:-}" ]^^^1^cmd:uv cmd:uvx^uv comes with the toolbox image; uv and uvx are exported to the host.'
        'rustup^rustup (Rust)^image^rustup-init^[ -x "$HOME/.cargo/bin/rustup" ]^^^1^dir:$HOME/.cargo/bin^Fedora ships only rustup-init (in the toolbox image); /usr/bin/rustup does not exist. The recipe runs rustup-init in your home (stable toolchain, no shell rc edits) and exports the proxies in ~/.cargo/bin (rustup, cargo, rustc and so on; rustup-init itself is not exported).\nInside the box, add to its shell rc:  . "$HOME/.cargo/env"'
        'sdkman^SDKMAN^installer^https://get.sdkman.io?rcupdate=false^[ -s "$HOME/.sdkman/bin/sdkman-init.sh" ]^^^1^wrapper:sdk^No Fedora package exists, so this is a vendor installer script. sdk is a shell function, so the host gets a small wrapper script that runs it in the box.\nInside the box, add to its shell rc:  source "$HOME/.sdkman/bin/sdkman-init.sh"'
        'nvm^nvm^installer^https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh^[ -s "${NVM_DIR:-$HOME/.nvm}/nvm.sh" ]^PROFILE=/dev/null^^1^^No Fedora package exists, so this is a vendor installer script. Nothing is exported: host node and npm stay the ones from brew.\nInside the box, add to its shell rc:\n  export NVM_DIR="$HOME/.nvm"\n  [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"'
        'buildchain^Build chain^group^^[ -n "${where[gcc]:-}${where[make]:-}${where[cc]:-}" ]^^^1^cmd:cc cmd:gcc cmd:g++ cmd:c++ cmd:make cmd:cmake cmd:ninja cmd:meson cmd:ld cmd:as cmd:ar cmd:nm cmd:objdump cmd:strip cmd:ranlib cmd:pkg-config^'
        'clitools^CLI tools^group^^[ -n "${where[lsscsi]:-}${where[waypipe]:-}${where[evtest]:-}${where[guestfish]:-}${where[flatpak-builder]:-}" ]^^^1^cmd:lsscsi cmd:nicstat cmd:waypipe cmd:evtest cmd:guestfish cmd:virt-v2v cmd:flatpak-builder^'
    )

    tool_ids=()
    group_ids=()
    for r in "${rows[@]}"; do
        IFS='^' read -r id _ src _ <<<"$r"
        if [ "$src" = group ]; then group_ids+=("$id"); else tool_ids+=("$id"); fi
    done

    load() {
        local r
        for r in "${rows[@]}"; do
            IFS='^' read -r id label src ref check envs iargs def exports note <<<"$r"
            [ "$id" = "$1" ] && return 0
        done
        return 1
    }

    declare -A where=()

    box_exists() {
        command -v distrobox >/dev/null 2>&1 &&
            distrobox list 2>/dev/null | awk -F'|' 'NR > 1 { gsub(/ /, "", $2); print $2 }' | grep -qx -- "$box"
    }

    # One trip into the box to find every command the table cares about
    resolve_all() {
        local t item n p names=(uv uvx rustup-init code)
        where=()
        box_exists || return 0
        for t in "${tool_ids[@]}" "${group_ids[@]}"; do
            load "$t"
            for item in $exports; do
                case "$item" in cmd:*) names+=("${item#cmd:}") ;; esac
            done
        done
        while read -r n p; do
            if [ -n "$p" ]; then where[$n]=$p; fi
        done < <(distrobox enter "$box" -- bash -c 'for c in "$@"; do p=$(command -v "$c") && echo "$c $p"; done' _ "${names[@]}" </dev/null 2>/dev/null)
    }

    state() {
        load "$1"
        if (eval "$check") >/dev/null 2>&1; then echo installed; else echo missing; fi
    }

    recorded() { grep -qxF -- "export $1" "$state_file" 2>/dev/null; }

    record() {
        mkdir -p -- "$(dirname -- "$state_file")"
        printf '%s\n' "$1" >>"$state_file"
    }

    # Source paths this row exports, one per line (wrapper entries as wrapper:NAME)
    export_sources() {
        local item d f
        load "$1"
        for item in $exports; do
            case "$item" in
                cmd:*) if [ -n "${where[${item#cmd:}]:-}" ]; then printf '%s\n' "${where[${item#cmd:}]}"; fi ;;
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

    # yes, partial, no, or - when the row exports nothing
    export_state() {
        local s n=0 ok=0 dest ex
        ex=$(
            load "$1"
            echo "$exports"
        )
        if [ -z "$ex" ]; then
            echo "-"
            return 0
        fi
        while IFS= read -r s; do
            [ -n "$s" ] || continue
            n=$((n + 1))
            dest="$export_dir/$(export_name "$s")"
            if [ "$s" = "$dest" ] || { [ -e "$dest" ] && recorded "$dest"; }; then ok=$((ok + 1)); fi
        done < <(export_sources "$1")
        if [ "$n" -eq 0 ] || [ "$ok" -eq 0 ]; then
            echo no
        elif [ "$ok" -eq "$n" ]; then
            echo yes
        else
            echo partial
        fi
    }

    # The image the box is made from: DEV_TOOLBOX_IMAGE, else the image= line of the definition
    def_image() {
        if [ -n "$image_override" ]; then
            printf '%s\n' "$image_override"
        else
            sed -n 's/^image=//p' "$def_file" 2>/dev/null | head -1 | tr -d "\"'"
        fi
    }

    conf_value() {
        [ -f "$conf_file" ] || return 0
        { grep -E '^[[:space:]]*container_name_default=' "$conf_file" || true; } | tail -1 | sed -E 's/^[^=]*=//' | tr -d "\"'"
    }

    undo_note() {
        [ -f "$state_file" ] || return 0
        echo
        echo "To undo: what this recipe created is listed in $state_file."
        echo "  - delete each 'export' path listed there (the files in $export_dir);"
        echo "  - 'conf' lines say how container_name_default in $conf_file was set (created, appended, or changed from an older value);"
        echo "  - remove the box with: distrobox rm $box  (your home is shared, so your files stay)."
    }

    list_all() {
        local t st ex cv bs=missing
        box_exists && bs=present
        resolve_all
        cv=$(conf_value)
        echo "Box:           $box ($bs)"
        echo "Image:         $(def_image)"
        if [ -z "$cv" ]; then
            echo "Default name:  not set in $conf_file"
        elif [ "$cv" = "$box" ]; then
            echo "Default name:  $box (container_name_default)"
        else
            echo "Default name:  $cv (not $box)"
        fi
        if grep -qx 'box-no-brew-mount' "$state_file" 2>/dev/null; then
            echo "Brew mount:    missing (box made before brew existed; run --recreate after ujust brew)"
        fi
        echo
        printf '%-10s %-10s %-18s %-9s %s\n' TOOL STATE SOURCE EXPORTED LABEL
        for t in "${tool_ids[@]}" "${group_ids[@]}"; do
            load "$t"
            st=$(state "$t")
            if [ "$st" = installed ]; then ex=$(export_state "$t"); else ex=-; fi
            case "$src" in
                image) sdesc="image:$ref" ;;
                installer) sdesc=installer ;;
                *) sdesc=image ;;
            esac
            printf '%-10s %-10s %-18s %-9s %s\n' "$id" "$st" "$sdesc" "$ex" "$label"
        done
        undo_note
    }

    usage() {
        echo "Usage: ujust dev-toolbox [--list] [--recreate] [--force] [tool ...]"
        echo "       ujust dev-toolbox --remove [--dry-run]   (destroys the box and what this recipe created)"
        echo "       ujust dev-toolbox --upgrade [--check]    (pull the latest toolbox image and replace the box if it is newer)"
        echo "       ujust dev-toolbox --update               (package updates inside the existing box: distrobox upgrade)"
        echo "       ujust dev-toolbox --ide [--list|--remove [--dry-run]] [ide ...]   (launchers that start an IDE inside the box)"
        echo "       ujust dev-toolbox --ide-custom NAME COMMAND [ICON]"
        echo "IDEs: ${ide_ids[*]}"
        echo "Tools: ${tool_ids[*]}"
        echo "With no tools it shows a checklist (SPACE toggles, ENTER confirms, q skips)."
    }

    # IDE launchers (--ide): .desktop files that start an IDE inside the box. Detection only, nothing is installed.
    # One row per IDE, fields separated by ^ : id ^ name ^ kind (jetbrains or vscode) ^ launcher name ^ StartupWMClass ^ categories
    # jetbrains: the stable shell script JetBrains Toolbox generates (needs "Generate shell scripts" in the Toolbox settings,
    # default folder below); the icon is taken from the IDE directory that script launches, so no versioned path is hardcoded.
    # vscode: a code found inside the box, or a tarball install under the home. The window classes are from memory, unverified.
    app_dir="${UPM_APPS_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/applications}"
    jb_scripts="${UPM_JB_SCRIPTS:-$HOME/.local/share/JetBrains/Toolbox/scripts}"
    ide_rows=(
        'pycharm^PyCharm^jetbrains^pycharm^jetbrains-pycharm^Development;IDE;'
        'idea^IntelliJ IDEA^jetbrains^idea^jetbrains-idea^Development;IDE;'
        'datagrip^DataGrip^jetbrains^datagrip^jetbrains-datagrip^Development;IDE;'
        'rustrover^RustRover^jetbrains^rustrover^jetbrains-rustrover^Development;IDE;'
        'clion^CLion^jetbrains^clion^jetbrains-clion^Development;IDE;'
        'goland^GoLand^jetbrains^goland^jetbrains-goland^Development;IDE;'
        'webstorm^WebStorm^jetbrains^webstorm^jetbrains-webstorm^Development;IDE;'
        'vscode^Visual Studio Code^vscode^code^Code^Development;IDE;TextEditor;'
    )
    ide_ids=()
    for r in "${ide_rows[@]}"; do ide_ids+=("${r%%^*}"); done

    ide_load() {
        local r
        for r in "${ide_rows[@]}"; do
            IFS='^' read -r iid iname ikind icmd iwm icat <<<"$r"
            [ "$iid" = "$1" ] && return 0
        done
        return 1
    }

    idcmd=""
    idicon=""
    idmsg=""
    ide_detect() { # sets idcmd, idicon, idmsg
        local s l d c f
        idcmd=""
        idicon=""
        idmsg=""
        ide_load "$1"
        case "$ikind" in
            jetbrains)
                s="$jb_scripts/$icmd"
                if [ ! -x "$s" ]; then
                    idmsg="No launcher script $s. Turn on 'Generate shell scripts' in JetBrains Toolbox (its settings, Tools) and set the folder to $jb_scripts, then run this again."
                    return 1
                fi
                idcmd=$s
                l=$(grep -oE '/[^" ]+/bin/[^" /]+\.sh' "$s" 2>/dev/null | head -1 || true)
                if [ -n "$l" ]; then
                    d=$(dirname -- "$l")
                    for f in "$d"/*.svg "$d"/*.png; do
                        if [ -f "$f" ]; then
                            idicon=$f
                            break
                        fi
                    done
                fi
                ;;
            vscode)
                if [ -n "${where[code]:-}" ]; then
                    idcmd=${where[code]}
                    idicon=vscode
                else
                    for c in "$HOME"/.local/opt/*/bin/code "$HOME"/opt/*/bin/code "$HOME"/Applications/*/bin/code; do
                        if [ -x "$c" ]; then
                            idcmd=$c
                            f="$(dirname -- "$(dirname -- "$c")")/resources/app/resources/linux/code.png"
                            if [ -f "$f" ]; then idicon=$f; fi
                            break
                        fi
                    done
                fi
                if [ -z "$idcmd" ]; then
                    idmsg="No 'code' inside the box and no VS Code tarball under your home (~/.local/opt, ~/opt, ~/Applications). Nothing is installed for you: extract the tarball from code.visualstudio.com there, or install code in the box yourself. The Flatpak cannot be used from the box, and Microsoft's repo is not added."
                    return 1
                fi
                ;;
        esac
    }

    ide_file() { echo "$app_dir/fedora-toolbox-$1.desktop"; }

    ide_write() { # file, name, command, icon, wm class, categories
        mkdir -p -- "$(dirname -- "$1")"
        {
            printf '[Desktop Entry]\nType=Application\n'
            printf 'Name=%s (toolbox)\n' "$2"
            printf 'Comment=%s, started inside the %s distrobox\n' "$2" "$box"
            printf 'Exec=distrobox enter -n %s -- "%s" %%F\n' "$box" "$3"
            printf 'Icon=%s\n' "${4:-applications-development}"
            printf 'Terminal=false\nStartupNotify=true\n'
            if [ -n "$5" ]; then printf 'StartupWMClass=%s\n' "$5"; fi
            printf 'Categories=%s\nX-Created-By=ujust dev-toolbox\n' "${6:-Development;}"
        } >"$1"
        chmod 644 "$1"
    }

    refresh_apps() {
        if command -v update-desktop-database >/dev/null 2>&1; then update-desktop-database "$app_dir" >/dev/null 2>&1 || true; fi
    }

    list_ide() {
        local t f st det c p
        resolve_all
        printf '%-10s %-9s %-13s %s\n' IDE DETECTED LAUNCHER COMMAND
        for t in "${ide_ids[@]}"; do
            f=$(ide_file "$t")
            if ide_detect "$t"; then
                det=yes
                c=$idcmd
            else
                det=no
                c="-"
            fi
            if [ -e "$f" ]; then
                if grep -qxF -- "launcher $f" "$state_file" 2>/dev/null; then st=created; else st="foreign file"; fi
            else
                st="not created"
            fi
            printf '%-10s %-9s %-13s %s\n' "$t" "$det" "$st" "$c"
        done
        while IFS= read -r p; do
            case "$p" in
                "$app_dir"/fedora-toolbox-*.desktop) ;;
                *) continue ;;
            esac
            c=${p##*/fedora-toolbox-}
            c=${c%.desktop}
            if [[ " ${ide_ids[*]} " != *" $c "* ]]; then printf '%-10s %-9s %-13s %s\n' "$c" "custom" "created" "$p"; fi
        done < <(sed -n 's/^launcher //p' "$state_file" 2>/dev/null)
        echo
        echo "Launchers run the IDE inside the box (distrobox enter -n $box -- ...). Remove them with: ujust dev-toolbox --ide --remove"
        echo "StartupWMClass values are from memory and not verified against the real windows."
    }

    force=0
    recreate=0
    remove=0
    dry=0
    upgrade=0
    check_only=0
    update=0
    assume=0
    no_checklist=0
    ide=0
    list=0
    custom=()
    want=()
    argv=("$@")
    ai=0
    while [ "$ai" -lt "${#argv[@]}" ]; do
        a=${argv[ai]}
        ai=$((ai + 1))
        case "$a" in
            --list) list=1 ;;
            --ide) ide=1 ;;
            --ide-custom)
                ide=1
                custom=("${argv[@]:ai}")
                break
                ;;
            -h | --help)
                usage
                exit 0
                ;;
            --force) force=1 ;;
            --recreate) recreate=1 ;;
            --remove) remove=1 ;;
            --dry-run) dry=1 ;;
            --upgrade) upgrade=1 ;;
            --check) check_only=1 ;;
            --update) update=1 ;;
            -*)
                echo "Unknown option $a" >&2
                usage >&2
                exit 2
                ;;
            *) want+=("$a") ;;
        esac
    done

    if [ "$ide" = 1 ]; then valid=("${ide_ids[@]}"); else valid=("${tool_ids[@]}"); fi
    for a in "${want[@]}"; do
        if [[ " ${valid[*]} " != *" $a "* ]]; then
            echo "Unknown name '$a'" >&2
            usage >&2
            exit 2
        fi
    done
    if [ "$ide" = 1 ] && [ "${#custom[@]}" -gt 0 ] && { [ "${#custom[@]}" -lt 2 ] || [ "${#custom[@]}" -gt 3 ]; }; then
        echo "Usage: --ide-custom NAME COMMAND [ICON]" >&2
        exit 2
    fi
    if [ "$list" = 1 ]; then
        if [ "$ide" = 1 ]; then list_ide; else list_all; fi
        exit 0
    fi

    if [ "$dry" = 1 ] && [ "$remove" = 0 ]; then
        echo "--dry-run only goes with --remove" >&2
        exit 2
    fi
    if [ "$check_only" = 1 ] && [ "$upgrade" = 0 ]; then
        echo "--check only goes with --upgrade" >&2
        exit 2
    fi
    if [ "$ide" = 1 ]; then
        if [ $((upgrade + update + recreate + check_only + force)) -gt 0 ] || { [ "$remove" = 1 ] && [ "${#custom[@]}" -gt 0 ]; }; then
            echo "--ide only combines with --list, --remove, --dry-run and IDE names" >&2
            exit 2
        fi
    elif [ $((remove + upgrade + update + recreate)) -gt 1 ] || { [ $((remove + upgrade + update)) -gt 0 ] && [ "${#want[@]}" -gt 0 ]; }; then
        echo "--remove, --upgrade, --update and --recreate cannot be combined with each other or with tool names" >&2
        exit 2
    fi
    if [ "$(id -u)" -eq 0 ]; then
        echo "Do not run this as root: the box and its tools belong to your user." >&2
        exit 1
    fi
    command -v distrobox >/dev/null 2>&1 || {
        echo "distrobox is not installed." >&2
        exit 1
    }

    # --update: package updates inside the existing box, nothing else
    if [ "$update" = 1 ]; then
        if ! distrobox list 2>/dev/null | awk -F'|' 'NR > 1 { gsub(/ /, "", $2); print $2 }' | grep -qx -- "$box"; then
            echo "The box $box does not exist; create it first with: ujust dev-toolbox" >&2
            exit 1
        fi
        exec distrobox upgrade "$box"
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

    failed=0
    ans=""
    ask() { # prompt, optional file the v key shows
        while :; do
            printf '%s' "$1"
            IFS= read -rsn1 -u 3 ans || ans=n
            printf '%s\n' "$ans"
            case "$ans" in
                v | V)
                    if [ -n "${2:-}" ]; then
                        read -ra pg <<<"${PAGER:-less}"
                        command -v "${pg[0]}" >/dev/null 2>&1 || pg=(cat)
                        "${pg[@]}" "$2" || true
                    fi
                    ;;
                y | Y)
                    ans=y
                    return 0
                    ;;
                *) return 1 ;;
            esac
        done
    }

    # Step 1: the box
    step_box() {
        local tmpdef nobrew=0
        if box_exists; then
            if [ "$recreate" = 0 ]; then
                echo "== Box $box exists"
                if [ -d "$brew_dir" ] && grep -qx 'box-no-brew-mount' "$state_file" 2>/dev/null; then
                    echo "   It was made before Homebrew existed, so it lacks the read-only $brew_dir mount."
                    echo "   Run: ujust dev-toolbox --recreate"
                fi
                return 0
            fi
            echo "== Recreating $box"
            echo "   Your home is shared, so your files, ~/.cargo and caches survive; only the container's own"
            echo "   filesystem (packages installed inside it, anything outside your home) is replaced."
            if [ "$assume" = 0 ] && ! ask "   [y] remove and recreate the box, anything else keeps it: "; then
                echo "   Kept the existing box."
                return 0
            fi
            distrobox rm --force "$box" </dev/null || {
                echo "   Could not remove $box."
                failed=1
                return 1
            }
            # Exports made by this recipe point at the old container: remove exactly those, nothing else
            if [ -f "$state_file" ]; then
                while IFS= read -r p; do
                    if [ -e "$p" ] || [ -L "$p" ]; then
                        rm -f -- "$p"
                        echo "   Removed old export $p"
                    fi
                done < <(sed -n 's/^export //p' "$state_file")
                sed -i '/^export /d' "$state_file"
            fi
        else
            echo "== Box $box does not exist"
            if ! ask "   [y] create it from $def_file (pulls the image, takes a while), anything else stops: "; then
                echo "   Not created."
                return 1
            fi
        fi
        if [ ! -r "$def_file" ]; then
            echo "   Definition not found: $def_file"
            failed=1
            return 1
        fi
        tmpdef="$work/$box.ini"
        echo "   Image: $(def_image)"
        if [ -n "$image_override" ]; then
            awk -v img="$image_override" '/^image=/ { print "image=" img; next } { print }' "$def_file" >"$work/def.ini"
        else
            cp -- "$def_file" "$work/def.ini"
        fi
        if [ -d "$brew_dir" ]; then
            cp -- "$work/def.ini" "$tmpdef"
        else
            # The mount's source must exist or container creation fails; the recipe cannot create it (needs root)
            grep -v '^volume=.*linuxbrew' "$work/def.ini" >"$tmpdef" || true
            nobrew=1
            echo "   $brew_dir does not exist yet, so the box is created without the read-only brew mount."
            echo "   After 'ujust brew', run 'ujust dev-toolbox --recreate' to add it."
        fi
        if ! distrobox assemble create --file "$tmpdef" </dev/null; then
            echo "   distrobox assemble failed."
            failed=1
            return 1
        fi
        grep -qx "box $box" "$state_file" 2>/dev/null || record "box $box"
        if [ -f "$state_file" ]; then
            sed -i '/^box-no-brew-mount$/d' "$state_file"
        fi
        if [ "$nobrew" = 1 ]; then record "box-no-brew-mount"; fi
        echo "   Created $box."
    }

    # Step 2: make it the default for distrobox enter
    step_default() {
        local cur tmp
        cur=$(conf_value)
        if [ "$cur" = "$box" ]; then
            echo "== container_name_default is already $box"
            return 0
        fi
        echo "== Setting container_name_default=$box in $conf_file"
        mkdir -p -- "$(dirname -- "$conf_file")"
        if [ ! -f "$conf_file" ]; then
            printf 'container_name_default="%s"\n' "$box" >"$conf_file"
            record "conf created"
        elif ! grep -qE '^[[:space:]]*container_name_default=' "$conf_file"; then
            if [ -s "$conf_file" ] && [ -n "$(tail -c1 "$conf_file")" ]; then printf '\n' >>"$conf_file"; fi
            printf 'container_name_default="%s"\n' "$box" >>"$conf_file"
            record "conf appended"
        else
            echo "   It is currently set to '$cur'."
            if ! ask "   [y] change it to $box, anything else leaves it: "; then
                echo "   Left as it was."
                return 0
            fi
            tmp="$work/distrobox.conf"
            awk -v v="container_name_default=\"$box\"" '/^[[:space:]]*container_name_default=/ { print v; next } { print }' "$conf_file" >"$tmp"
            cat "$tmp" >"$conf_file"
            record "conf changed $cur"
        fi
        echo "   distrobox enter now opens $box."
    }

    # Run a command in the box with a sudo stub first on PATH and no_new_privs, so even an
    # absolute /usr/bin/sudo cannot gain privileges. Output is kept in $log.
    log=""
    run_guarded() { # tag, environment words, command...
        local tag=$1 envs_s=$2 e a rc=0 runner envarr=()
        shift 2
        runner="$work/run-$tag.sh"
        log="$work/$tag.log"
        mkdir -p "$work/bin"
        {
            printf '#!/bin/sh\n'
            printf 'echo "sudo is not allowed here" >&2\n'
            printf ': > %q\n' "$work/sudo-called"
            printf 'exit 1\n'
        } >"$work/bin/sudo"
        chmod 700 "$work/bin/sudo"
        rm -f "$work/sudo-called"
        read -ra envarr <<<"$envs_s"
        {
            printf '#!/bin/bash\nset -eu\n'
            printf 'command -v setpriv >/dev/null 2>&1 || { echo "setpriv is missing, refusing to run without the no-sudo guard" >&2; exit 97; }\n'
            printf 'export PATH=%q:"$PATH"\n' "$work/bin"
            for e in "${envarr[@]}"; do printf 'export %s=%q\n' "${e%%=*}" "${e#*=}"; done
            printf 'exec setpriv --no-new-privs'
            for a in "$@"; do printf ' %q' "$a"; done
            printf '\n'
        } >"$runner"
        distrobox enter "$box" -- bash "$runner" </dev/null 2>&1 | tee "$log" || rc=${PIPESTATUS[0]}
        return "$rc"
    }

    report_failure() { # label, exit code
        if [ "$2" -eq 97 ]; then
            echo "   $1 was not run: setpriv is missing, so the no-sudo guard could not be applied."
        elif [ -e "$work/sudo-called" ] || grep -qiE 'sudo|no new privileges|no_new_privs' "$log"; then
            echo "   $1 failed because it wanted sudo, which this recipe blocks on purpose."
            echo "   Do the root-only step yourself (see the message above), then run this again."
        else
            echo "   $1 failed (exit $2)."
        fi
        failed=1
    }

    print_note() {
        if [ -n "$note" ]; then
            printf '%b\n' "${note//__PREFIX__/$brew_dir}" | sed 's/^/   /'
        fi
    }

    # Export what a row provides to the host. Never overwrites anything that exists.
    do_exports() {
        local t=$1 s name dest created=0 already=0 bn
        load "$t"
        [ -n "$exports" ] || return 0
        mkdir -p -- "$export_dir"
        while IFS= read -r s; do
            [ -n "$s" ] || continue
            name=$(export_name "$s")
            dest="$export_dir/$name"
            if [ "$s" = "$dest" ]; then continue; fi
            if [ -e "$dest" ] || [ -L "$dest" ]; then
                if recorded "$dest"; then
                    already=$((already + 1))
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
            record "export $dest"
            created=$((created + 1))
            echo "   Exported $dest"
        done < <(export_sources "$t")
        if [ "$already" -gt 0 ]; then echo "   $already already exported."; fi
    }

    missing_package() {
        echo "   $label is not in the box. It comes with the toolbox image ($ref); the image is rebuilt weekly."
        echo "   Get the latest image and replace the box: ujust dev-toolbox --upgrade"
        echo "   (This recipe does not install packages itself, because that would need sudo.)"
        failed=1
    }

    # Directories an install step creates (the box shares the home, so these are in your home)
    row_dirs() {
        case "$1" in
            sdkman) echo "$HOME/.sdkman" ;;
            nvm) echo "${NVM_DIR:-$HOME/.nvm}" ;;
            rustup) echo "$HOME/.rustup $HOME/.cargo" ;;
        esac
    }

    # Before an install step: remember, once, whether each directory already existed
    note_dirs() {
        local d
        for d in $(row_dirs "$1"); do
            if grep -qF -- "dir $d " "$state_file" 2>/dev/null; then continue; fi
            if [ -e "$d" ]; then record "dir $d existed"; else record "dir $d created"; fi
        done
    }

    install_rustup() {
        local rc=0
        if [ "$(state rustup)" = installed ]; then
            echo "   Already set up (~/.cargo/bin/rustup exists)."
            return 0
        fi
        if [ -z "${where[rustup-init]:-}" ]; then
            missing_package
            return 0
        fi
        echo "   The box only has rustup-init (there is no /usr/bin/rustup until it has run in your home)."
        echo "   It downloads the stable toolchain from static.rust-lang.org: a normal download, not a piped script,"
        echo "   and it does not touch your shell rc files (--no-modify-path)."
        if ! ask "   [y] run 'rustup-init -y --no-modify-path --default-toolchain stable', anything else skips: "; then
            echo "   Skipped."
            return 0
        fi
        note_dirs rustup
        run_guarded rustup "" rustup-init -y --no-modify-path --default-toolchain stable || rc=$?
        if [ "$rc" -ne 0 ]; then
            report_failure "rustup-init" "$rc"
            return 0
        fi
        if [ "$(state rustup)" = missing ]; then
            echo "   rustup-init finished but ~/.cargo/bin/rustup does not exist; check its output above."
            failed=1
            return 0
        fi
        echo "   Installed rustup with a stable toolchain."
    }

    install_installer() {
        local t=$1 file sum size envarr=() argarr=() rc=0
        case "$ref" in
            https://*) ;;
            *)
                echo "   Refusing a non-https installer URL: $ref"
                failed=1
                return 0
                ;;
        esac
        file="$work/$t-installer.sh"
        echo "   Downloading $ref"
        if ! curl -fsSL --proto '=https' --tlsv1.2 -o "$file" "$ref"; then
            echo "   Download failed; skipping $label."
            failed=1
            return 0
        fi
        sum=$(sha256sum "$file" | cut -d' ' -f1)
        size=$(stat -c %s "$file")
        echo "   sha256 $sum"
        echo "   size   $size bytes"
        echo "   This is vendor code, not ours: running it means you trust $ref."
        if ! ask "   [v] view it, [y] run it, anything else skips: " "$file"; then
            echo "   Skipped $label."
            return 0
        fi
        read -ra argarr <<<"$iargs"
        note_dirs "$t"
        run_guarded "$t" "$envs" bash "$file" "${argarr[@]}" || rc=$?
        if [ "$rc" -ne 0 ]; then
            report_failure "$label" "$rc"
            return 0
        fi
        if [ "$(state "$t")" = missing ]; then
            echo "   The installer finished but $label is still not detected; check its output above."
            failed=1
            return 0
        fi
        echo "   Installed $label."
    }

    install_one() {
        local t=$1 st
        load "$t"
        st=$(state "$t")
        echo "== $label"
        case "$src" in
            image)
                if [ "$t" = rustup ]; then
                    install_rustup
                elif [ "$st" = missing ]; then
                    missing_package
                else
                    echo "   Already in the box (from the toolbox image)."
                fi
                ;;
            installer)
                if [ "$st" != missing ] && [ "$force" = 0 ]; then
                    echo "   Already installed, skipping (--force runs the installer again)."
                else
                    install_installer "$t"
                fi
                ;;
        esac
        load "$t"
        if [ "$(state "$t")" = installed ]; then print_note; fi
    }

    states=()
    sel=()
    cur=-1

    draw() {
        local i m p s
        for i in "${!tool_ids[@]}"; do
            load "${tool_ids[i]}"
            s=""
            case "${states[i]}" in
                installed)
                    m='[-]'
                    s="  (installed)"
                    ;;
                *) if [ "${sel[i]}" = 1 ]; then m='[x]'; else m='[ ]'; fi ;;
            esac
            if [ "$i" -eq "$cur" ]; then p='>'; else p=' '; fi
            printf '\033[2K%s %s %-8s from %s%s\n' "$p" "$m" "$label" "$(if [ "$src" = image ]; then echo "image ($ref)"; else echo installer; fi)" "$s"
        done
        printf '\033[2K  SPACE toggles, ENTER sets up the ticked ones, q skips\n'
    }

    move() {
        local d=$1 i=$cur n=${#tool_ids[@]}
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
        for i in "${!tool_ids[@]}"; do
            states[i]=$(state "${tool_ids[i]}")
            load "${tool_ids[i]}"
            sel[i]=0
            if [ "${states[i]}" = missing ]; then
                any=1
                if [ "$def" = 1 ]; then sel[i]=1; fi
                if [ "$cur" -lt 0 ]; then cur=$i; fi
            fi
        done
        if [ "$any" = 0 ]; then
            echo "Every tool on the list is already set up."
            return 0
        fi
        echo "Tools in the box"
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
                    echo "Skipped the tool list."
                    return 0
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
                printf '\033[%dA' $((${#tool_ids[@]} + 1))
                draw
            fi
        done
        if [ -t 1 ]; then printf '\033[?25h'; fi
        for i in "${!tool_ids[@]}"; do
            if [ "${sel[i]}" = 1 ]; then want+=("${tool_ids[i]}"); fi
        done
    }

    # --remove: destroy the box and remove only what the state file says this recipe created
    size_of() { du -sh -- "$1" 2>/dev/null | cut -f1; }
    drop_state() { # exact line to delete from the state file
        if [ -f "$state_file" ]; then
            grep -vxF -- "$1" "$state_file" >"$work/state.new" || true
            cat "$work/state.new" >"$state_file"
        fi
    }
    safe_dir() { # absolute, under $HOME, not $HOME itself, no ..
        case "$1" in
            "$HOME"/*) ;;
            *) return 1 ;;
        esac
        case "$1" in
            *..*) return 1 ;;
        esac
        return 0
    }
    conf_key_remove() { # kind, old value
        local tmp="$work/conf.new" kind=$1 old=$2
        case "$kind" in
            changed) awk -v v="container_name_default=\"$old\"" '/^[[:space:]]*container_name_default=/ { print v; next } { print }' "$conf_file" >"$tmp" ;;
            *) grep -vE '^[[:space:]]*container_name_default=' "$conf_file" >"$tmp" || true ;;
        esac
        if [ "$kind" = created ] && ! grep -q '[^[:space:]]' "$tmp"; then
            rm -f -- "$conf_file"
        else
            cat "$tmp" >"$conf_file"
        fi
    }

    do_remove() {
        local p kind rest cur conf_line have_box=0 line
        local exps=() dirs=() skipped=() lnch=()
        if [ ! -f "$state_file" ]; then
            echo "No state file ($state_file): this recipe has nothing recorded, so there is nothing to remove."
            return 0
        fi
        while IFS= read -r p; do
            if [ -e "$p" ] || [ -L "$p" ]; then
                case "$p" in
                    "$export_dir"/*) exps+=("$p") ;;
                    *) skipped+=("$p (not under $export_dir, left alone)") ;;
                esac
            fi
        done < <(sed -n 's/^export //p' "$state_file")
        while IFS= read -r p; do
            if [ -e "$p" ] || [ -L "$p" ]; then
                case "$p" in
                    "$app_dir"/fedora-toolbox-*.desktop) lnch+=("$p") ;;
                    *) skipped+=("$p (not a launcher path this recipe creates, left alone)") ;;
                esac
            fi
        done < <(sed -n 's/^launcher //p' "$state_file")
        conf_line=$(grep -E '^conf (created|appended|changed)' "$state_file" | head -1 || true)
        if grep -qx "box $box" "$state_file" && box_exists; then have_box=1; fi
        while IFS= read -r line; do
            p=${line#dir }
            kind=${p##* }
            p=${p% *}
            if [ "$kind" = existed ]; then
                skipped+=("$p (already existed before this recipe, left alone)")
            elif [ -e "$p" ] && safe_dir "$p"; then
                dirs+=("$p")
            elif [ -e "$p" ]; then
                skipped+=("$p (not a safe path under your home, left alone)")
            fi
        done < <(grep '^dir ' "$state_file" || true)

        echo "This would remove, in this order:"
        for p in "${exps[@]}"; do echo "  export    $p  ($(size_of "$p"))"; done
        for p in "${lnch[@]}"; do echo "  launcher  $p  ($(size_of "$p"))"; done
        if [ -n "$conf_line" ]; then
            cur=$(conf_value)
            if [ "$cur" = "$box" ]; then
                echo "  setting   container_name_default in $conf_file (${conf_line#conf })"
            else
                skipped+=("container_name_default in $conf_file (now '$cur', not what this recipe wrote)")
                conf_line=""
            fi
        fi
        if [ "$have_box" = 1 ]; then echo "  container $box  (distrobox rm --force; size not shown)"; fi
        for p in "${dirs[@]}"; do echo "  directory $p  ($(size_of "$p"))"; done
        echo "  state     $state_file  (last)"
        if [ "${#skipped[@]}" -gt 0 ]; then
            echo "Left alone:"
            for p in "${skipped[@]}"; do echo "  $p"; done
        fi
        echo "Never touched: anything under /usr or /etc, $export_dir itself, files this recipe did not create. No sudo is used."
        if [ "$dry" = 1 ]; then
            echo "Dry run: nothing was removed."
            return 0
        fi
        echo
        echo "Warning: ~/.cargo and ~/.sdkman can hold things you installed later (cargo install binaries,"
        echo "JDKs, Spark, Hadoop). They are lost with the directory."
        printf "Type yes to remove all of the above: "
        IFS= read -r -u 3 line || line=""
        printf '%s\n' "$line"
        if [ "$line" != yes ]; then
            echo "Nothing was removed."
            return 0
        fi
        for p in "${exps[@]}"; do
            rm -f -- "$p" || {
                echo "Could not remove $p; stopped. Run again to finish."
                return 1
            }
            drop_state "export $p"
            echo "Removed $p"
        done
        for p in "${lnch[@]}"; do
            rm -f -- "$p" || {
                echo "Could not remove $p; stopped. Run again to finish."
                return 1
            }
            drop_state "launcher $p"
            echo "Removed $p"
        done
        if [ "${#lnch[@]}" -gt 0 ]; then refresh_apps; fi
        if [ -n "$conf_line" ]; then
            kind=${conf_line#conf }
            rest=${kind#* }
            kind=${kind%% *}
            if [ "$rest" = "$kind" ]; then rest=""; fi
            conf_key_remove "$kind" "$rest" || {
                echo "Could not edit $conf_file; stopped. Run again to finish."
                return 1
            }
            drop_state "$conf_line"
            echo "Removed the container_name_default setting"
        fi
        if [ "$have_box" = 1 ]; then
            distrobox rm --force "$box" </dev/null || {
                echo "Could not remove the container $box; stopped. Run again to finish."
                return 1
            }
            drop_state "box $box"
            drop_state "box-no-brew-mount"
            echo "Removed the container $box"
        fi
        for p in "${dirs[@]}"; do
            rm -rf -- "$p" || {
                echo "Could not remove $p; stopped. Run again to finish."
                return 1
            }
            drop_state "dir $p created"
            echo "Removed $p"
        done
        rm -f -- "$state_file"
        echo "Removed $state_file. Done."
    }

    # --ide: launchers that start an IDE inside the box
    isel=()
    ist=()
    icur=-1

    ide_draw() {
        local i m p s
        for i in "${!ide_ids[@]}"; do
            ide_load "${ide_ids[i]}"
            s=""
            case "${ist[i]}" in
                done)
                    m='[-]'
                    s="  (launcher exists)"
                    ;;
                none)
                    m='[-]'
                    s="  (not detected)"
                    ;;
                *) if [ "${isel[i]}" = 1 ]; then m='[x]'; else m='[ ]'; fi ;;
            esac
            if [ "$i" -eq "$icur" ]; then p='>'; else p=' '; fi
            printf '\033[2K%s %s %s%s\n' "$p" "$m" "$iname" "$s"
        done
        printf '\033[2K  SPACE toggles, ENTER creates the ticked launchers, q skips\n'
    }

    ide_move() {
        local d=$1 i=$icur n=${#ide_ids[@]}
        while :; do
            i=$(((i + d + n) % n))
            if [ "${ist[i]}" = ready ]; then
                icur=$i
                return 0
            fi
            if [ "$i" -eq "$icur" ]; then return 0; fi
        done
    }

    ide_checklist() {
        local i key rest any=0
        for i in "${!ide_ids[@]}"; do
            isel[i]=0
            if [ -e "$(ide_file "${ide_ids[i]}")" ]; then
                ist[i]=done
            elif ide_detect "${ide_ids[i]}"; then
                ist[i]=ready
                isel[i]=1
                any=1
                if [ "$icur" -lt 0 ]; then icur=$i; fi
            else
                ist[i]=none
            fi
        done
        if [ "$any" = 0 ]; then
            echo "No detected IDE still needs a launcher. 'ujust dev-toolbox --ide --list' says why."
            return 0
        fi
        echo "IDE launchers (they start the IDE inside $box)"
        if [ -t 1 ]; then
            printf '\033[?25l'
            ide_draw
        fi
        while :; do
            key=""
            IFS= read -rsn1 -u 3 key || key=EOF
            case "$key" in
                EOF | q | Q)
                    if [ -t 1 ]; then printf '\033[?25h'; fi
                    echo "Skipped."
                    return 0
                    ;;
                '') break ;;
                ' ')
                    if [ "${ist[icur]}" = ready ]; then isel[icur]=$((1 - isel[icur])); fi
                    ;;
                j | J) ide_move 1 ;;
                k | K) ide_move -1 ;;
                $'\x1b')
                    rest=""
                    IFS= read -rsn2 -t 0.05 -u 3 rest || true
                    case "$rest" in
                        '[A') ide_move -1 ;;
                        '[B') ide_move 1 ;;
                    esac
                    ;;
            esac
            if [ -t 1 ]; then
                printf '\033[%dA' $((${#ide_ids[@]} + 1))
                ide_draw
            fi
        done
        if [ -t 1 ]; then printf '\033[?25h'; fi
        for i in "${!ide_ids[@]}"; do
            if [ "${isel[i]}" = 1 ]; then want+=("${ide_ids[i]}"); fi
        done
    }

    # Create one launcher. Never overwrites a file this recipe did not create.
    make_launcher() { # file, name, command, icon, wm class, categories
        local f=$1
        if [ -e "$f" ] || [ -L "$f" ]; then
            if grep -qxF -- "launcher $f" "$state_file" 2>/dev/null; then
                echo "   Already created $f"
            else
                echo "   Skipped $f: it exists and was not created by this recipe (not touched)."
            fi
            return 0
        fi
        ide_write "$f" "$2" "$3" "$4" "$5" "$6"
        record "launcher $f"
        echo "   Created $f"
        echo "   It runs: distrobox enter -n $box -- $3 %F"
    }

    install_ide() {
        local t=$1
        ide_load "$t"
        echo "== $iname"
        if [ -e "$(ide_file "$t")" ]; then
            make_launcher "$(ide_file "$t")" "$iname" "" "" "" ""
            return 0
        fi
        if ! ide_detect "$t"; then
            echo "   $idmsg"
            failed=1
            return 0
        fi
        make_launcher "$(ide_file "$t")" "$iname" "$idcmd" "$idicon" "$iwm" "$icat"
    }

    install_custom() {
        local name=${custom[0]} cmd=${custom[1]} icon=${custom[2]:-} id
        id=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9\n' '-' | sed 's/^-*//; s/-*$//')
        echo "== $name"
        if [ -z "$id" ]; then
            echo "   The name needs letters or digits."
            failed=1
            return 0
        fi
        case "$cmd" in
            "$HOME"/*) ;;
            *)
                echo "   The command must be an absolute path under your home (the box sees your home, not the host's /usr)."
                failed=1
                return 0
                ;;
        esac
        case "$cmd$icon" in
            *'"'* | *%* | *$'\n'*)
                echo "   Quotes, percent signs and newlines are not allowed in the command or icon."
                failed=1
                return 0
                ;;
        esac
        if [ ! -f "$cmd" ] || [ ! -x "$cmd" ]; then
            echo "   $cmd is not an executable file."
            failed=1
            return 0
        fi
        if [ -n "$icon" ] && [ ! -f "$icon" ]; then
            echo "   Icon $icon not found; using a generic icon."
            icon=""
        fi
        make_launcher "$(ide_file "$id")" "$name" "$cmd" "$icon" "" "Development;"
    }

    ide_box_ready() {
        local st
        if ! box_exists; then
            echo "The box $box does not exist. Create it first with: ujust dev-toolbox (this option never creates it)."
            return 1
        fi
        st=$(distrobox list 2>/dev/null | awk -F'|' -v b="$box" '{ n = $2; gsub(/ /, "", n); if (n == b) { s = $3; gsub(/^ +| +$/, "", s); print s } }')
        case "$st" in
            Up*) ;;
            *)
                echo "The box is not running (status: ${st:-unknown})."
                if ask "[y] start it now, anything else leaves it stopped (distrobox enter starts it on first launch anyway): "; then
                    podman start "$box" >/dev/null || {
                        echo "Could not start $box."
                        return 1
                    }
                fi
                ;;
        esac
    }

    do_ide() {
        local t
        ide_box_ready || return 1
        resolve_all
        if [ "${#custom[@]}" -gt 0 ]; then
            install_custom
        else
            if [ "${#want[@]}" -eq 0 ]; then ide_checklist; fi
            for t in "${want[@]}"; do install_ide "$t"; done
        fi
        refresh_apps
        echo
        echo "The launcher starts the IDE as a process of the container, so its terminals, run configurations and"
        echo "language servers use the box's compilers, libraries and package managers. The GUI works through"
        echo "distrobox's display and GPU passthrough. Downloads made inside the IDE (JDKs, plugins) land in your"
        echo "shared home, and a recreated box needs no new launchers."
        echo "To undo: ujust dev-toolbox --ide --remove (only launchers listed in $state_file are deleted)."
    }

    ide_remove() {
        local p t ok f files=()
        while IFS= read -r p; do
            case "$p" in
                "$app_dir"/fedora-toolbox-*.desktop) ;;
                *) continue ;;
            esac
            if [ "${#want[@]}" -gt 0 ]; then
                ok=0
                for t in "${want[@]}"; do
                    if [ "$p" = "$(ide_file "$t")" ]; then ok=1; fi
                done
                [ "$ok" = 1 ] || continue
            fi
            files+=("$p")
        done < <(sed -n 's/^launcher //p' "$state_file" 2>/dev/null)
        if [ "${#files[@]}" -eq 0 ]; then
            echo "No launchers recorded by this recipe; nothing to remove."
            return 0
        fi
        echo "This would delete (only files this recipe created):"
        for f in "${files[@]}"; do echo "  $f"; done
        if [ "$dry" = 1 ]; then
            echo "Dry run: nothing was removed."
            return 0
        fi
        if ! ask "[y] delete them, anything else keeps them: "; then
            echo "Nothing was removed."
            return 0
        fi
        for f in "${files[@]}"; do
            rm -f -- "$f"
            drop_state "launcher $f"
            echo "Removed $f"
        done
        refresh_apps
    }

    if [ "$ide" = 1 ]; then
        if [ "$remove" = 1 ]; then ide_remove || failed=1; else do_ide || failed=1; fi
        exit "$failed"
    fi

    if [ "$remove" = 1 ]; then
        do_remove || failed=1
        exit "$failed"
    fi

    # --upgrade: compare the base image the box was built from with the latest one; replace the box if newer
    img_ver() { # image id: VERSION_ID from /etc/os-release inside it, or unknown
        local v
        v=$(podman run --rm --entrypoint cat "$1" /etc/os-release 2>/dev/null | sed -n 's/^VERSION_ID=//p' | tr -d "\"'" | head -1 || true)
        echo "${v:-unknown}"
    }

    do_upgrade() {
        local image cur_id new_id cur_dig new_dig cur_ver new_ver line
        local o='{' c='}'
        local f_id="$o$o.Id$c$c" f_dig="$o$o.Digest$c$c" f_img="$o$o.Image$c$c"
        if ! box_exists; then
            echo "The box $box does not exist; create it first with: ujust dev-toolbox"
            return 1
        fi
        command -v podman >/dev/null 2>&1 || {
            echo "podman is not installed."
            return 1
        }
        image=$(def_image)
        if [ -z "$image" ]; then
            echo "No image= line in $def_file (and DEV_TOOLBOX_IMAGE is not set)."
            return 1
        fi
        echo "Toolbox image: $image"
        echo "Pulling it (a normal image pull) to see whether it changed"
        podman pull -q "$image" >/dev/null || {
            echo "Could not pull $image."
            return 1
        }
        new_id=$(podman image inspect --format "$f_id" "$image")
        cur_id=$(podman inspect --type container --format "$f_img" "$box")
        cur_dig=$(podman image inspect --format "$f_dig" "$cur_id" 2>/dev/null || echo unknown)
        new_dig=$(podman image inspect --format "$f_dig" "$new_id" 2>/dev/null || echo unknown)
        cur_ver=$(img_ver "$cur_id")
        new_ver=$(img_ver "$new_id")
        echo "Box $box was created from:  $cur_id"
        echo "  digest $cur_dig, Fedora $cur_ver"
        echo "Latest $image:  $new_id"
        echo "  digest $new_dig, Fedora $new_ver"
        if [ "$cur_id" = "$new_id" ]; then
            echo "The box is already on the latest image."
            return 0
        fi
        if [ "$check_only" = 1 ]; then
            echo "A newer image is available. Check only: nothing was changed."
            return 0
        fi
        if [ "$cur_ver" != "$new_ver" ] && [ "$cur_ver" != unknown ] && [ "$new_ver" != unknown ]; then
            echo "Warning: the Fedora release changes from $cur_ver to $new_ver. Tools you built or installed in your"
            echo "home (~/.cargo, SDKMAN, Python environments with compiled extensions) may need a rebuild."
        fi
        echo
        echo "Upgrading replaces the container: your home is shared, so your files, ~/.cargo, ~/.rustup,"
        echo "~/.sdkman, ~/.nvm and caches survive; the box is recreated from the image and the"
        echo "container's own filesystem is lost. Exports listed in the state file are made again."
        printf "Type yes to replace the box: "
        IFS= read -r -u 3 line || line=""
        printf '%s\n' "$line"
        if [ "$line" != yes ]; then
            echo "Nothing was changed."
            exit 0
        fi
        recreate=1
        assume=1
        no_checklist=1
        return 0
    }

    if [ "$upgrade" = 1 ]; then
        do_upgrade || exit 1
        if [ "$recreate" = 0 ]; then exit 0; fi
    fi

    echo "Installers in the box are vendor scripts (SDKMAN, nvm). Each one is downloaded to a file, hashed and shown to you before it runs."
    step_box || {
        undo_note
        exit "$failed"
    }
    step_default
    resolve_all
    if [ "${#want[@]}" -eq 0 ] && [ "$no_checklist" = 0 ]; then checklist; fi
    for t in "${want[@]}"; do
        install_one "$t"
    done
    echo "== Exports to $export_dir"
    resolve_all
    for t in "${tool_ids[@]}" "${group_ids[@]}"; do
        if [ "$(state "$t")" = installed ]; then do_exports "$t"; fi
    done
    undo_note
    exit "$failed"
