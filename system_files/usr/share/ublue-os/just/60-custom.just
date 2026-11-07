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

# Let every Flatpak app read the host's GTK config, icons and ~/.themes (read-only)
flatpak-theme-access:
    #!/usr/bin/env bash
    set -euo pipefail
    # Flatpak apps only see the host theme if these paths are exposed. This is a global override,
    # so it applies to every app. Undo with: ujust flatpak-theme-reset
    flatpak override --user \
        --filesystem=xdg-config/gtk-3.0:ro \
        --filesystem=xdg-config/gtk-4.0:ro \
        --filesystem=xdg-data/icons:ro \
        --filesystem=~/.themes:ro
    echo "Flatpak apps can now read your GTK config, icons and ~/.themes. Restart running apps."

# Undo flatpak-theme-access by deleting only its four entries from the global override
flatpak-theme-reset:
    #!/usr/bin/env bash
    set -euo pipefail
    file="${XDG_DATA_HOME:-$HOME/.local/share}/flatpak/overrides/global"
    [ -f "$file" ] || { echo "No global override file at $file; nothing to do"; exit 0; }
    # `flatpak override --reset` would also drop unrelated global overrides, so edit the list
    # (literal matching, not regex)
    content=$(<"$file")
    for p in 'xdg-config/gtk-3.0:ro' 'xdg-config/gtk-4.0:ro' 'xdg-data/icons:ro' '~/.themes:ro'; do
        content=${content//"$p;"/}
    done
    tmp=$(mktemp "$file.XXXXXX")
    printf '%s\n' "$content" > "$tmp"
    mv -- "$tmp" "$file"
    echo "Removed the theme entries from $file"

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

