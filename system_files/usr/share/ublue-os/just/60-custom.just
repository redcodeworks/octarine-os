# vim: set ft=make :

# Step-by-step setup for a new user: groups, zsh, Flatpak access, fonts, fish terminal, GNOME search (--help for usage)
[group('Setup')]
[positional-arguments]
user-setup *args:
    #!/usr/bin/env bash
    set -uo pipefail
    menu_lib="${OCTARINE_MENU_LIB:-/usr/share/octarine-os/lib/menu.sh}"
    # shellcheck source=/dev/null
    if [ -r "$menu_lib" ]; then . "$menu_lib"; fi
    if ! declare -F menu_ready >/dev/null; then menu_ready() { return 1; }; menu_ready_one() { return 1; }; menu_tty() { return 1; }; menu_title() { printf '%s\n' "$1"; }; menu_confirm() { return 1; }; fi
    mode=ask
    only_list=""
    user=""
    valid_steps=" groups shell flatpak fonts fish-terminal search "
    args=("$@")
    i=0
    while [ "$i" -lt "${#args[@]}" ]; do
        a=${args[$i]}
        case "$a" in
            help | --help | -h) printf '%s\n' 'One-time user setup, a checklist with one y/n question per step. `ujust user-setup [user] [--yes|--no] [--only STEP[,STEP...]]`. Steps in order: groups (gamemode, input and libvirt where it is installed; sudo), shell (login shell zsh; sudo), flatpak (access overrides), fonts (Nerd Fonts from Homebrew casks: a 12-font developer set by default), fish-terminal (Ptyxis fish profile and the starship prompt), search (GNOME search providers). --yes takes every default without asking (steps that need a value are skipped), --no only prints the plan. Sudo is used only by the groups and shell steps.'; exit 0 ;;
            --yes) mode=yes ;;
            --no) mode=no ;;
            --only)
                i=$((i + 1))
                only_list=${args[$i]:-}
                [ -n "$only_list" ] || { echo "--only needs a step list" >&2; exit 2; }
                ;;
            --only=*) only_list=${a#--only=} ;;
            -*) echo "Unknown option: $a (use --yes, --no or --only STEP[,STEP...])" >&2; exit 2 ;;
            *)
                if [ -n "$user" ]; then echo "Only one user name is accepted" >&2; exit 2; fi
                user=$a
                ;;
        esac
        i=$((i + 1))
    done
    if [ -n "$only_list" ]; then
        for s in ${only_list//,/ }; do
            case "$valid_steps" in
                *" $s "*) ;;
                *) echo "Unknown step: $s (steps:${valid_steps% })" >&2; exit 2 ;;
            esac
        done
    fi
    user=${user:-$(id -un)}
    if ! [[ "$user" =~ ^[a-z_][a-z0-9_-]*$ ]] || ! id "$user" >/dev/null 2>&1; then
        echo "'$user' is not an existing user name"
        exit 1
    fi

    names=()
    results=()
    undos=()
    failed=0
    cur_step=""

    record() { names+=("$1"); results+=("$2"); undos+=("${3:--}"); }

    # sel <step>: the step is selected (every step when --only is not given)
    sel() {
        [ -z "$only_list" ] && return 0
        case ",$only_list," in *",$1,"*) return 0 ;; esac
        return 1
    }
    # ask <default y|n> <question>: sets $answer to y or n
    ask() {
        local def=$1 q=$2 reply hint="[Y/n]"
        [ "$def" = n ] && hint="[y/N]"
        case "$mode" in
            yes) answer=$def; return ;;
            no) answer=n; return ;;
        esac
        printf '%s %s ' "$q" "$hint"
        read -r reply || reply=""
        case "$reply" in
            [Yy]*) answer=y ;;
            [Nn]*) answer=n ;;
            *) answer=$def ;;
        esac
    }

    in_list() { local n=$1; shift; local i; for i in "$@"; do [ "$i" = "$n" ] && return 0; done; return 1; }
    installed() { flatpak info "$1" >/dev/null 2>&1; }

    # has_val <app> <key> <value...>: the user override of <app> lists <value> under <key> (any of the spellings)
    has_val() {
        local app=$1 key=$2 shown v
        shift 2
        shown=$(flatpak override --user --show "$app" 2>/dev/null) || return 1
        for v in "$@"; do
            printf '%s\n' "$shown" | awk -F= -v k="$key" -v v="$v" '
                $1 == k { n = split($2, a, ";"); for (i = 1; i <= n; i++) if (a[i] == v) f = 1 }
                END { exit !f }' && return 0
        done
        return 1
    }

    # flatpak_step <name> <default> <app> <sentence> <undo> <done-check-command> <apply-command>
    # Commands are run with eval so they can carry the old recipes' flags verbatim.
    flatpak_step() {
        local name=$1 def=$2 app=$3 sentence=$4 undo=$5 donecheck=$6 apply=$7
        echo
        echo "== $name"
        if ! installed "$app"; then
            echo "Skipped: $app is not installed."
            record "$name" "skipped (not installed)"
            return
        fi
        if eval "$donecheck"; then
            echo "Already in place."
            record "$name" "already done"
            return
        fi
        echo "$sentence"
        ask "$def" "Apply?"
        if [ "$answer" != y ]; then
            if [ "$mode" = no ]; then record "$name" "planned (would ask)"; else record "$name" "skipped (not applied)"; fi
            return
        fi
        if eval "$apply"; then
            record "$name" "applied" "$undo"
        else
            echo "Failed: $name" >&2
            failed=1
            record "$name" "FAILED"
        fi
    }

    # Terminal with gum: one checklist of steps up front, a summary and one confirmation; then the chosen steps run
    # like `--yes --only <steps>` (each still prints what it does and how to undo it). Without gum, or with --yes,
    # --no or --only, nothing here applies and the per-step questions are unchanged.
    ui=0
    if [ "$mode" = ask ] && [ -z "$only_list" ] && menu_ready; then
        ui=1
        menu_title "octarineOS user setup"
        # only name the groups that exist here (libvirt exists only where libvirt is installed, so not on the default image)
        menu_groups=()
        for g in gamemode input libvirt; do getent group "$g" >/dev/null 2>&1 && menu_groups+=("$g"); done
        case "${#menu_groups[@]}" in
            0) menu_groups_text="no extra groups" ;;
            1) menu_groups_text="${menu_groups[0]}" ;;
            *) menu_groups_text="$(IFS=,; echo "${menu_groups[*]:0:${#menu_groups[@]}-1}" | sed 's/,/, /g') and ${menu_groups[${#menu_groups[@]}-1]}" ;;
        esac
        menu_multi "User setup: choose the steps" \
            "^Account^0" \
            "groups^Add $user to $menu_groups_text (sudo)^1" \
            "shell^Login shell zsh (sudo)^1" \
            "^Apps^0" \
            "flatpak^Flatpak access overrides^1" \
            "fonts^Nerd Fonts from Homebrew casks^1" \
            "^Desktop^0" \
            "fish-terminal^Fish terminal profile with the starship prompt^1" \
            "search^GNOME search providers^1"
        if [ "${#MENU_RESULT[@]}" -eq 0 ]; then echo "Nothing selected; nothing changed."; exit 0; fi
        echo "Selected steps: ${MENU_RESULT[*]}"
        if ! menu_confirm "Run these steps?" y; then echo "Nothing changed."; exit 0; fi
        only_list=$(IFS=,; echo "${MENU_RESULT[*]}")
        mode=yes
    fi

    if sel groups; then
    cur_step=groups
    # 1. groups. gamemode and input only exist in /usr/lib/group, so their lines are copied into /etc/group first
    # or usermod -aG would not see them.
    groups_todo=()
    groups_missing=0
    for g in gamemode input libvirt; do
        if ! getent group "$g" >/dev/null; then
            echo "Skipping $g: no such group on this system"
            continue
        fi
        id -nG "$user" | tr ' ' '\n' | grep -qx "$g" || groups_todo+=("$g")
    done
    echo "== groups"
    if [ "${#groups_todo[@]}" -eq 0 ]; then
        echo "$user is already in every available group (gamemode, input, libvirt where installed)."
        record "groups" "already done"
    else
        echo "Will add $user to: ${groups_todo[*]} (uses sudo; takes effect at next login)."
        ask y "Apply?"
        if [ "$answer" != y ]; then
            if [ "$mode" = no ]; then record "groups" "planned (would ask)"; else record "groups" "skipped (not applied)"; fi
        else
            gfail=0
            undo=""
            for g in "${groups_todo[@]}"; do
                if sudo sh -c "grep -q '^$g:' /etc/group || grep '^$g:' /usr/lib/group >> /etc/group" && sudo usermod -aG "$g" "$user"; then
                    echo "Added $user to $g"
                    undo="$undo sudo gpasswd -d $user $g;"
                else
                    echo "Failed to add $user to $g" >&2
                    gfail=1
                fi
            done
            if [ "$gfail" = 1 ]; then failed=1; record "groups" "FAILED" "$undo"; else
                echo "Log out and back in for the new groups to apply."
                record "groups" "applied" "$undo"
            fi
        fi
    fi

    fi

    if sel shell; then
    cur_step=shell
    # 1b. login shell. zsh is opt-in: /etc/default/useradd keeps the packaged default, so this step is how a user gets zsh.
    # chsh is not installed on this image, so usermod -s does the change.
    echo
    echo "== login-shell"
    zsh=${USER_SETUP_ZSH:-/usr/bin/zsh}
    shells_file=${USER_SETUP_SHELLS:-/etc/shells}
    skel=${USER_SETUP_SKEL:-/etc/skel}
    cur=$(getent passwd "$user" | cut -d: -f7)
    if [ "$cur" = "$zsh" ]; then
        echo "Already zsh."
        record "login-shell" "already done"
    elif [ ! -x "$zsh" ]; then
        echo "Skipped: $zsh does not exist on this system."
        record "login-shell" "skipped (no zsh)"
    elif ! grep -qxF "$zsh" "$shells_file" 2>/dev/null; then
        echo "Skipped: $zsh is not listed in $shells_file, so it is not an allowed login shell."
        record "login-shell" "skipped (not in /etc/shells)"
    else
        echo "Switch $user's login shell from ${cur:-unknown} to zsh? Takes effect at the next login; bash stays installed as the fallback."
        ask y "Apply?"
        if [ "$answer" != y ]; then
            if [ "$mode" = no ]; then record "login-shell" "planned (would ask)"; else record "login-shell" "skipped (not applied)"; fi
        elif sudo usermod -s "$zsh" "$user"; then
            echo "Login shell of $user is now $zsh (next login)."
            if [ "$user" = "$(id -un)" ]; then
                if [ ! -e "$HOME/.zshrc" ] && [ ! -e "$HOME/.zprofile" ] && [ ! -e "$HOME/.zshenv" ]; then
                    for f in .zshrc .zprofile; do
                        [ -f "$skel/$f" ] && cp -n "$skel/$f" "$HOME/$f"
                    done
                    echo "Copied the skeleton zsh startup files so zsh's first-run wizard does not appear."
                fi
            else
                echo "For $user's home, run as that user: cp -n $skel/.zshrc ~/"
            fi
            record "login-shell" "applied" "sudo usermod -s ${cur:-/bin/bash} $user (effective at next login)"
        else
            echo "Failed: login-shell" >&2
            failed=1
            record "login-shell" "FAILED"
        fi
    fi

    fi

    if sel flatpak; then
    cur_step=flatpak
    # 2. Flatpak access steps (same overrides as the former single recipes)
    # games directory: needs a value, default no
    echo
    echo "== flatpak-games-access"
    games_apps=()
    for app in com.valvesoftware.Steam com.usebottles.bottles net.lutris.Lutris; do
        installed "$app" && games_apps+=("$app")
    done
    if [ "${#games_apps[@]}" -eq 0 ]; then
        echo "Skipped: none of Steam, Bottles and Lutris (Flatpak) is installed."
        record "flatpak-games-access" "skipped (not installed)"
    elif [ "$mode" != ask ] && [ "$ui" != 1 ]; then
        echo "Needs a directory path: skipped without a prompt."
        record "flatpak-games-access" "skipped (needs a path)"
    else
        echo "Gives the installed Flatpak game launchers (${games_apps[*]}) access to one games directory."
        printf 'Games directory (empty to skip): '
        read -r path || path=""
        if [ -z "$path" ]; then
            record "flatpak-games-access" "skipped (no path)"
        else
            path=${path/#\~/$HOME}
            resolved=$(realpath -m -- "$path")
            home=$(realpath -m -- "$HOME")
            case "$resolved" in
                / | "$home" | /home | /var | /var/home | /usr | /etc | /boot | /root | /mnt | /media | /run | /tmp)
                    echo "Refusing to expose $resolved to every game launcher. Pick a dedicated games directory."
                    record "flatpak-games-access" "skipped (refused path)"
                    resolved=""
                    ;;
            esac
            if [ -n "$resolved" ]; then
                alldone=1
                for app in "${games_apps[@]}"; do has_val "$app" filesystems "$resolved" || alldone=0; done
                if [ "$alldone" = 1 ]; then
                    echo "Already in place."
                    record "flatpak-games-access" "already done"
                else
                    gfail=0
                    undo=""
                    mkdir -p -- "$resolved" || gfail=1
                    for app in "${games_apps[@]}"; do
                        if flatpak override --user --filesystem="$resolved" "$app"; then
                            undo="$undo flatpak override --user --nofilesystem=$resolved $app;"
                        else
                            gfail=1
                        fi
                    done
                    if [ "$gfail" = 1 ]; then failed=1; echo "Failed: flatpak-games-access" >&2; record "flatpak-games-access" "FAILED" "$undo"; else
                        echo "${games_apps[*]} can now use $resolved"
                        record "flatpak-games-access" "applied" "$undo"
                    fi
                fi
            fi
        fi
    fi

    # These widen the sandbox: default no. Skip it if you do not need controller support beyond what Steam Input does
    flatpak_step "steam-flatpak-devices" n com.valvesoftware.Steam \
        "Lets Flatpak Steam access USB and input devices (controllers). This widens the sandbox." \
        "flatpak override --user --nodevice=usb --nodevice=input com.valvesoftware.Steam" \
        'has_val com.valvesoftware.Steam devices usb && has_val com.valvesoftware.Steam devices input' \
        'flatpak override --user --device=usb --device=input com.valvesoftware.Steam && echo "Flatpak Steam can now access USB and input devices"'

    flatpak_step "vscode-flatpak-podman" y com.visualstudio.code \
        "Lets Flatpak VS Code use Wayland and the rootless Podman socket (for dev containers)." \
        "flatpak override --user --nosocket=wayland --nofilesystem=xdg-run/podman com.visualstudio.code" \
        'has_val com.visualstudio.code sockets wayland && has_val com.visualstudio.code filesystems xdg-run/podman' \
        'flatpak override --user --socket=wayland --filesystem=xdg-run/podman com.visualstudio.code && echo "VS Code can reach \$XDG_RUNTIME_DIR/podman. Enable it with: systemctl --user enable --now podman.socket"'

    flatpak_step "podman-desktop-deny-docker-socket" y io.podman_desktop.PodmanDesktop \
        "Stops Podman Desktop from reaching a Docker socket (it should only talk to Podman); this removes access." \
        "remove the '!/run/docker.sock' line from ~/.local/share/flatpak/overrides/io.podman_desktop.PodmanDesktop (Flatseal does the same)" \
        'has_val io.podman_desktop.PodmanDesktop filesystems "!/run/docker.sock"' \
        'flatpak override --user --nofilesystem=/run/docker.sock io.podman_desktop.PodmanDesktop && echo "Podman Desktop can no longer access /run/docker.sock"'

    flatpak_step "chrome-flatpak-webapps" y com.google.Chrome \
        "Lets Flatpak Chrome install web apps as launchers (writes desktop entries and icons under ~/.local/share)." \
        "flatpak override --user --nofilesystem=~/.local/share/applications --nofilesystem=~/.local/share/icons com.google.Chrome" \
        'has_val com.google.Chrome filesystems "~/.local/share/applications" "$HOME/.local/share/applications" && has_val com.google.Chrome filesystems "~/.local/share/icons" "$HOME/.local/share/icons"' \
        'flatpak override --user --filesystem=~/.local/share/applications --filesystem=~/.local/share/icons com.google.Chrome && echo "Chrome can now write web app launchers to ~/.local/share/applications"'

    flatpak_step "gearlever-applications" y it.mijorus.gearlever \
        "Lets Gear Lever manage AppImages in ~/Applications (creates the directory)." \
        "flatpak override --user --nofilesystem=~/Applications it.mijorus.gearlever" \
        'has_val it.mijorus.gearlever filesystems "~/Applications" "$HOME/Applications"' \
        'mkdir -p "$HOME/Applications" && flatpak override --user --filesystem=~/Applications it.mijorus.gearlever && echo "Gear Lever can now use ~/Applications"'

    fi

    # fonts: Nerd Fonts from Homebrew casks (Homebrew checks the cask checksums; nothing is downloaded here)
    if sel fonts; then
    cur_step=fonts
    echo
    echo "== fonts (Nerd Fonts)"
    if ! command -v brew >/dev/null 2>&1; then
        echo "Skipped: Homebrew is missing (the image installs it on first boot; rerun later)."
        record "fonts" "skipped (no brew)"
    elif [ "$mode" = no ]; then
        echo "Plan: offer the 12-font developer set (default), JetBrains Mono Nerd Font only, a pick from all Nerd Font casks, or skip; install with Homebrew."
        record "fonts" "planned (would ask)"
    else
        fonts_brewfile=${USER_SETUP_FONTS_BREWFILE:-/usr/share/octarine-os/homebrew/fonts.Brewfile}
        fonts_choice=1
        mrc=3
        if [ "$ui" = 1 ]; then
            menu_one "Nerd Fonts from Homebrew casks (Homebrew checks their checksums; casks land in ~/.local/share/fonts)" \
                "1^Developer set (12 Nerd Fonts, Bluefin's developer list plus Fantasque)" "2^JetBrains Mono Nerd Font only" \
                "3^Pick from all Nerd Font casks" "4^Skip"
            mrc=$?
            case "$mrc" in 0) fonts_choice=$MENU_ONE ;; 1) fonts_choice=4 ;; esac
        fi
        if [ "$mrc" = 3 ] && { [ "$mode" = ask ] || [ "$ui" = 1 ]; }; then
            echo "Nerd Fonts from Homebrew casks (Homebrew checks their checksums; casks land in ~/.local/share/fonts):"
            echo "  1) Developer set (12 Nerd Fonts, Bluefin's developer list plus Fantasque) [default]"
            echo "  2) JetBrains Mono Nerd Font only"
            echo "  3) pick from all Nerd Font casks"
            echo "  4) skip"
            printf 'Choice [1]: '
            read -r reply || reply=""
            case "$reply" in
                "" | 1) fonts_choice=1 ;;
                2) fonts_choice=2 ;;
                3) fonts_choice=3 ;;
                *) fonts_choice=4 ;;
            esac
        fi
        selected=()
        case "$fonts_choice" in
            2) selected=(font-jetbrains-mono-nerd-font) ;;
            3)
                mapfile -t allcasks < <(brew search --cask nerd-font 2>/dev/null | grep -E '^font-[a-z0-9-]+-nerd-font$' | sort -u)
                if [ "${#allcasks[@]}" -eq 0 ]; then
                    echo "No Nerd Font casks found (is Homebrew working?)."
                else
                    mrc=3
                    if [ "$ui" = 1 ]; then
                        specs=()
                        for c in "${allcasks[@]}"; do specs+=("$c^$c^0"); done
                        menu_multi "Nerd Font casks" "${specs[@]}"
                        mrc=$?
                        if [ "$mrc" = 0 ]; then selected+=("${MENU_RESULT[@]}"); fi
                    fi
                    if [ "$mrc" = 3 ]; then
                        n=0
                        for c in "${allcasks[@]}"; do n=$((n + 1)); echo "  $n) $c"; done
                        printf 'Numbers or cask names separated by spaces, Enter = none: '
                        read -r reply || reply=""
                        for tok in $reply; do
                            if [[ "$tok" =~ ^[0-9]+$ ]] && [ "$tok" -ge 1 ] && [ "$tok" -le "${#allcasks[@]}" ]; then
                                selected+=("${allcasks[$((tok - 1))]}")
                            elif in_list "$tok" "${allcasks[@]}"; then
                                selected+=("$tok")
                            else
                                echo "Ignoring '$tok': not in the list of Nerd Font casks."
                            fi
                        done
                    fi
                fi
                ;;
        esac
        if [ "$fonts_choice" = 4 ] || { [ "$fonts_choice" != 1 ] && [ "${#selected[@]}" -eq 0 ]; }; then
            record "fonts" "skipped (not applied)"
        elif [ "$fonts_choice" = 1 ]; then
            if [ ! -f "$fonts_brewfile" ]; then
                echo "Failed: $fonts_brewfile is missing." >&2
                failed=1
                record "fonts" "FAILED"
            else
                allin=1
                casks=()
                while read -r kind cname _; do
                    [ "$kind" = cask ] || continue
                    cname=${cname//\"/}
                    casks+=("$cname")
                    brew list --cask "$cname" >/dev/null 2>&1 || allin=0
                done <"$fonts_brewfile"
                if [ "$allin" = 1 ]; then
                    echo "The developer font set is already installed."
                    record "fonts" "already done"
                elif brew bundle --file "$fonts_brewfile"; then
                    echo "Installed the developer font set."
                    record "fonts" "applied" "brew uninstall --cask ${casks[*]}"
                else
                    echo "Failed: fonts" >&2
                    failed=1
                    record "fonts" "FAILED"
                fi
            fi
        else
            toinstall=()
            for c in "${selected[@]}"; do
                brew list --cask "$c" >/dev/null 2>&1 || toinstall+=("$c")
            done
            if [ "${#toinstall[@]}" -eq 0 ]; then
                echo "Already installed: ${selected[*]}"
                record "fonts" "already done"
            elif brew install --cask "${toinstall[@]}"; then
                echo "Installed: ${toinstall[*]}"
                record "fonts" "applied" "brew uninstall --cask ${toinstall[*]}"
            else
                echo "Failed: fonts" >&2
                failed=1
                record "fonts" "FAILED"
            fi
        fi
        # terminal font, only on an explicit choice
        if command -v ptyxis >/dev/null 2>&1 && command -v gsettings >/dev/null 2>&1 && command -v fc-list >/dev/null 2>&1; then
            mapfile -t fams < <(fc-list : family 2>/dev/null | grep -i 'nerd font' | sed 's/,.*//' | sort -u)
            if [ "${#fams[@]}" -gt 0 ] && { [ "$mode" = ask ] || [ "$ui" = 1 ]; }; then
                reply=""
                mrc=3
                if [ "$ui" = 1 ]; then
                    specs=()
                    n=0
                    for f in "${fams[@]}"; do n=$((n + 1)); specs+=("$n^$f"); done
                    specs+=("0^No change")
                    menu_one "Ptyxis terminal font (Medium 10)" "${specs[@]}"
                    mrc=$?
                    if [ "$mrc" = 0 ] && [ "$MENU_ONE" != 0 ]; then reply=$MENU_ONE; fi
                fi
                if [ "$mrc" = 3 ]; then
                    echo "Ptyxis terminal font (installed Nerd Font families):"
                    n=0
                    for f in "${fams[@]}"; do n=$((n + 1)); echo "  $n) $f"; done
                    printf 'Number to use as the terminal font (Medium 10), Enter = no change: '
                    read -r reply || reply=""
                fi
                if [[ "$reply" =~ ^[0-9]+$ ]] && [ "$reply" -ge 1 ] && [ "$reply" -le "${#fams[@]}" ]; then
                    fam=${fams[$((reply - 1))]}
                    if gsettings set org.gnome.Ptyxis font-name "$fam Medium 10" && gsettings set org.gnome.Ptyxis use-system-font false; then
                        echo "Ptyxis uses $fam Medium 10 (new windows)."
                        record "fonts: terminal font" "applied" "gsettings reset org.gnome.Ptyxis font-name; gsettings reset org.gnome.Ptyxis use-system-font"
                    else
                        failed=1
                        record "fonts: terminal font" "FAILED"
                    fi
                else
                    record "fonts: terminal font" "skipped (no change)"
                fi
            else
                record "fonts: terminal font" "skipped (no change by default)"
            fi
        fi
    fi
    fi

    if sel fish-terminal; then
    cur_step=fish-terminal
    # 1c. fish terminal profile in Ptyxis plus the starship prompt (Homebrew only, no installer script)
    echo
    echo "== fish-profile"
    fish=${USER_SETUP_FISH:-/usr/bin/fish}
    pschema=org.gnome.Ptyxis
    prof_schema=org.gnome.Ptyxis.Profile
    conf="$HOME/.config/fish/conf.d/starship.fish"
    gs_list() { gsettings get "$pschema" profile-uuids 2>/dev/null | grep -oE "'[^']+'" | tr -d "'"; }
    find_fish_profile() {
        local u c v
        for u in $(gs_list); do
            c=$(gsettings get "$prof_schema:/org/gnome/Ptyxis/Profiles/$u/" custom-command 2>/dev/null)
            v=$(gsettings get "$prof_schema:/org/gnome/Ptyxis/Profiles/$u/" use-custom-command 2>/dev/null)
            if [ "$c" = "'$fish'" ] && [ "$v" = true ]; then echo "$u"; return 0; fi
        done
        return 1
    }
    cur_default() { gsettings get "$pschema" default-profile-uuid 2>/dev/null | tr -d "'"; }

    if [ ! -x "$fish" ]; then
        echo "Skipped: $fish is missing (fish is an optional package of the image; install it with the image's package set, then rerun)."
        record "fish-profile: ptyxis" "skipped (no fish)"
        record "fish-profile: starship" "skipped (no fish)"
    else
        a_state=todo
        if ! command -v ptyxis >/dev/null 2>&1 || ! command -v gsettings >/dev/null 2>&1; then
            a_state=none
        else
            existing=$(find_fish_profile || true)
            if [ -n "$existing" ] && [ "$(cur_default)" = "$existing" ]; then a_state=done; fi
        fi
        b_state=todo
        need_install=0
        if command -v starship >/dev/null 2>&1; then
            :
        elif command -v brew >/dev/null 2>&1; then
            need_install=1
        else
            b_state=nobrew
        fi
        if [ "$b_state" = todo ]; then
            if [ -f "$conf" ] && grep -qF 'starship init fish' "$conf"; then
                [ "$need_install" = 0 ] && b_state=done
            elif [ -f "$conf" ]; then
                b_state=otherfile
            fi
        fi
        [ "$a_state" = none ] && echo "Part A skipped: Ptyxis or gsettings is not available."
        [ "$b_state" = nobrew ] && echo "Part B skipped: starship is not installed and Homebrew is missing (the image installs Homebrew on first boot; rerun later)."
        [ "$b_state" = otherfile ] && echo "Part B skipped: $conf exists with other content; left alone."
        if [ "$a_state" = todo ] || [ "$b_state" = todo ]; then
            echo "Sets up a Ptyxis profile that starts fish (made the default; open new Ptyxis windows to see it) and the starship prompt (brew install starship if needed, hooked into fish through $conf)."
            ask y "Apply?"
            run_it=$answer
        else
            run_it=n
        fi
        # part A
        case "$a_state" in
            none) record "fish-profile: ptyxis" "skipped (no ptyxis/gsettings)" ;;
            done) echo "Ptyxis fish profile already the default."; record "fish-profile: ptyxis" "already done" ;;
            todo)
                if [ "$run_it" != y ]; then
                    if [ "$mode" = no ]; then record "fish-profile: ptyxis" "planned (would ask)"; else record "fish-profile: ptyxis" "skipped (not applied)"; fi
                else
                    prev=$(cur_default)
                    created=0
                    ok=1
                    uuid=$existing
                    if [ -z "$uuid" ]; then
                        uuid=$(uuidgen | tr -d - | tr 'A-F' 'a-f')
                        created=1
                        p="$prof_schema:/org/gnome/Ptyxis/Profiles/$uuid/"
                        gsettings set "$p" label fish && gsettings set "$p" custom-command "$fish" && gsettings set "$p" use-custom-command true || ok=0
                        if [ "$ok" = 1 ]; then
                            newlist="["
                            for u in $(gs_list) "$uuid"; do newlist="$newlist'$u', "; done
                            newlist="${newlist%, }]"
                            gsettings set "$pschema" profile-uuids "$newlist" || ok=0
                        fi
                    fi
                    [ "$ok" = 1 ] && { gsettings set "$pschema" default-profile-uuid "$uuid" || ok=0; }
                    if [ "$ok" = 1 ]; then
                        echo "Ptyxis profile $uuid starts fish and is the default (new windows pick it up)."
                        if [ -n "$prev" ]; then undo="gsettings set $pschema default-profile-uuid '$prev'"; else undo="gsettings reset $pschema default-profile-uuid"; fi
                        if [ "$created" = 1 ]; then
                            undo="$undo; dconf reset -f /org/gnome/Ptyxis/Profiles/$uuid/ and set profile-uuids again without '$uuid' (gsettings set $pschema profile-uuids \"[...]\")"
                        fi
                        record "fish-profile: ptyxis" "applied" "$undo"
                    else
                        echo "Failed: fish-profile (Ptyxis part)" >&2
                        failed=1
                        record "fish-profile: ptyxis" "FAILED"
                    fi
                fi
                ;;
        esac
        # part B
        case "$b_state" in
            nobrew) record "fish-profile: starship" "skipped (no brew)" ;;
            otherfile) record "fish-profile: starship" "skipped (starship.fish has other content)" ;;
            done) echo "Starship already installed and hooked into fish."; record "fish-profile: starship" "already done" ;;
            todo)
                if [ "$run_it" != y ]; then
                    if [ "$mode" = no ]; then record "fish-profile: starship" "planned (would ask)"; else record "fish-profile: starship" "skipped (not applied)"; fi
                else
                    ok=1
                    if [ "$need_install" = 1 ]; then brew install starship || ok=0; fi
                    if [ "$ok" = 1 ] && [ ! -f "$conf" ]; then
                        mkdir -p "$(dirname "$conf")" && {
                            echo "# Created by ujust user-setup"
                            echo "if status is-interactive; and type -q starship; starship init fish | source; end"
                        } >"$conf" || ok=0
                    fi
                    if [ "$ok" = 1 ]; then
                        echo "Starship is installed and hooked into fish (hint: starship preset --list shows ready-made styles)."
                        record "fish-profile: starship" "applied" "rm $conf; brew uninstall starship"
                    else
                        echo "Failed: fish-profile (starship part)" >&2
                        failed=1
                        record "fish-profile: starship" "FAILED"
                    fi
                fi
                ;;
        esac
    fi

    fi

    # search: GNOME search providers. Calculator, Bazaar, Characters and Clocks are DefaultDisabled in their provider
    # files, so they only show once their id is in `enabled`; a provider missing from sort-order sorts after the listed
    # ones. The lists are merged with the value read right before writing: the user may have changed them in Settings.
    if sel search; then
    cur_step=search
    echo
    echo "== gnome-search"
    sschema=org.gnome.desktop.search-providers
    calc=org.gnome.Calculator.desktop
    sdirs=${USER_SETUP_SEARCH_DIRS:-/usr/share/gnome-shell/search-providers:/var/lib/flatpak/exports/share/gnome-shell/search-providers:$HOME/.local/share/flatpak/exports/share/gnome-shell/search-providers}
    provider_present() {
        local d IFS=:
        for d in $sdirs; do
            grep -lxF "DesktopId=$1" "$d"/*.ini >/dev/null 2>&1 && return 0
        done
        return 1
    }
    sget() { gsettings get "$sschema" "$1" 2>/dev/null | grep -oE "'[^']+'" | tr -d "'"; }
    # mklist <id...>: GVariant string array text
    mklist() {
        local out="[" i
        for i in "$@"; do out="$out'$i', "; done
        [ "$out" = "[" ] && { echo "@as []"; return; }
        echo "${out%, }]"
    }
    if ! command -v gsettings >/dev/null 2>&1; then
        echo "Skipped: gsettings is not available."
        record "gnome-search: providers" "skipped (no gsettings)"
        record "gnome-search: calculator first" "skipped (no gsettings)"
    else
        mapfile -t s_enabled < <(sget enabled)
        mapfile -t s_disabled < <(sget disabled)
        mapfile -t s_sort < <(sget sort-order)
        present=()
        to_enable=()
        for id in org.gnome.Calculator.desktop io.github.kolunmi.Bazaar.desktop org.gnome.Characters.desktop org.gnome.clocks.desktop; do
            if ! provider_present "$id"; then
                echo "Skipped $id: its search provider is not installed."
                continue
            fi
            present+=("$id")
            if ! in_list "$id" "${s_enabled[@]}" || in_list "$id" "${s_disabled[@]}"; then to_enable+=("$id"); fi
        done
        sort_todo=0
        if provider_present "$calc"; then
            [ "${s_sort[0]:-}" = "$calc" ] || sort_todo=1
        fi
        if [ "${#to_enable[@]}" -eq 0 ] && [ "$sort_todo" = 0 ]; then
            echo "Nothing to do (providers enabled, or not installed; Calculator already first)."
            record "gnome-search: providers" "already done"
            record "gnome-search: calculator first" "already done"
        else
            echo "Enables the GNOME search providers for ${to_enable[*]:-(none needed)} and puts the Calculator first in the search order. Entries you already have stay as they are."
            ask y "Apply?"
            if [ "$answer" != y ]; then
                if [ "$mode" = no ]; then r="planned (would ask)"; else r="skipped (not applied)"; fi
                record "gnome-search: providers" "$r"
                record "gnome-search: calculator first" "$r"
            else
                if [ "${#to_enable[@]}" -eq 0 ]; then
                    record "gnome-search: providers" "already done"
                else
                    # merge with the current values, read now
                    mapfile -t cur_enabled < <(sget enabled)
                    mapfile -t cur_disabled < <(sget disabled)
                    new_enabled=("${cur_enabled[@]}")
                    new_disabled=()
                    for id in "${to_enable[@]}"; do in_list "$id" "${new_enabled[@]}" || new_enabled+=("$id"); done
                    for id in "${cur_disabled[@]}"; do in_list "$id" "${to_enable[@]}" || new_disabled+=("$id"); done
                    pok=1
                    if [ "${#new_enabled[@]}" -ne "${#cur_enabled[@]}" ]; then
                        gsettings set "$sschema" enabled "$(mklist "${new_enabled[@]}")" || pok=0
                    fi
                    if [ "${#new_disabled[@]}" -ne "${#cur_disabled[@]}" ]; then
                        gsettings set "$sschema" disabled "$(mklist "${new_disabled[@]}")" || pok=0
                    fi
                    if [ "$pok" = 1 ]; then
                        echo "Enabled: ${to_enable[*]}"
                        record "gnome-search: providers" "applied" "gsettings set $sschema enabled \"$(mklist "${cur_enabled[@]}")\" (the value before this run; 'dconf reset /org/gnome/desktop/search-providers/enabled' resets the whole key to defaults and drops providers you enabled by hand)"
                    else
                        echo "Failed: gnome-search providers" >&2
                        failed=1
                        record "gnome-search: providers" "FAILED"
                    fi
                fi
                if [ "$sort_todo" = 0 ]; then
                    record "gnome-search: calculator first" "already done"
                else
                    mapfile -t cur_sort < <(sget sort-order)
                    if [ "${cur_sort[0]:-}" = "$calc" ]; then
                        record "gnome-search: calculator first" "already done"
                    else
                        new_sort=("$calc")
                        for id in "${cur_sort[@]}"; do [ "$id" = "$calc" ] || new_sort+=("$id"); done
                        if gsettings set "$sschema" sort-order "$(mklist "${new_sort[@]}")"; then
                            echo "Calculator is first in the search order."
                            record "gnome-search: calculator first" "applied" "gsettings set $sschema sort-order \"$(mklist "${cur_sort[@]}")\" (the value before this run; 'dconf reset /org/gnome/desktop/search-providers/sort-order' resets the whole key to defaults)"
                        else
                            echo "Failed: gnome-search sort order" >&2
                            failed=1
                            record "gnome-search: calculator first" "FAILED"
                        fi
                    fi
                fi
            fi
        fi
    fi
    fi

    echo
    echo "== Summary (user: $user, mode: $mode)"
    printf '%-36s %s\n' "STEP" "RESULT"
    for i in "${!names[@]}"; do
        printf '%-36s %s\n' "${names[$i]}" "${results[$i]}"
    done
    any=0
    for i in "${!names[@]}"; do
        if [ "${results[$i]}" = applied ] || [ "${results[$i]}" = FAILED ]; then
            if [ "${undos[$i]}" != "-" ] && [ -n "${undos[$i]}" ]; then
                [ "$any" = 0 ] && { echo; echo "To undo (per step):"; any=1; }
                echo "  ${names[$i]}: ${undos[$i]}"
            fi
        fi
    done
    if [ "$any" = 1 ]; then
        echo "A --nofilesystem undo records a denial for that path. 'flatpak override --user --reset <app>' removes the app's other user overrides too."
    fi
    exit "$failed"

# Install the Flatpak apps this image lists; run it from a desktop terminal (--help for usage)
[group('Setup')]
[positional-arguments]
flatpak-preinstall *args:
    #!/usr/bin/env bash
    set -uo pipefail
    menu_lib="${OCTARINE_MENU_LIB:-/usr/share/octarine-os/lib/menu.sh}"
    # shellcheck source=/dev/null
    if [ -r "$menu_lib" ]; then . "$menu_lib"; fi
    if ! declare -F menu_ready >/dev/null; then menu_ready() { return 1; }; menu_ready_one() { return 1; }; menu_tty() { return 1; }; menu_title() { printf '%s\n' "$1"; }; menu_confirm() { return 1; }; fi
    dry=0
    for a in "$@"; do
        case "$a" in
            --dry-run) dry=1 ;;
            help | --help | -h) echo 'ujust flatpak-preinstall [--dry-run]: install the Flatpak apps listed in /usr/share/flatpak/preinstall.d. Run it as yourself from a desktop terminal, not with sudo (it needs your session bus; polkit may ask to authorize). --dry-run only shows the plan. Safe to repeat.'; exit 0 ;;
            *) echo "Unknown option: $a" >&2; echo "Usage: ujust flatpak-preinstall [--dry-run]" >&2; exit 2 ;;
        esac
    done
    flatpak_bin=${FLATPAK_BIN:-/usr/bin/flatpak}
    dir=${FLATPAK_PREINSTALL_DIR:-/usr/share/flatpak/preinstall.d}
    echo "Flatpak apps this will install (those already installed are left alone):"
    shopt -s nullglob
    count=0
    for f in "$dir"/*.preinstall; do
        while IFS= read -r line; do
            case "$line" in
                "[Flatpak Preinstall "*"]") ref=${line#"[Flatpak Preinstall "}; echo "  ${ref%]}"; count=$((count + 1)) ;;
            esac
        done <"$f"
    done
    [ "$count" -gt 0 ] || { echo "  (no list found in $dir)"; exit 1; }
    [ "$dry" = 1 ] && { echo "Dry run: nothing was changed."; exit 0; }
    if [ "$(id -u)" = 0 ]; then
        echo "Run this as your normal user from the desktop, not with sudo or as root (root has no session bus)." >&2
        exit 1
    fi
    if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
        echo "No desktop session bus found (DBUS_SESSION_BUS_ADDRESS is not set). Run this from a terminal inside your desktop session." >&2
        exit 1
    fi
    if ! "$flatpak_bin" remotes --columns=name 2>/dev/null | grep -qx flathub; then
        echo "The flathub remote is missing. Check with: flatpak remotes" >&2
        echo "The image adds it at boot (flatpak-add-fedora-repos.service); add it by hand with: flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo" >&2
        exit 1
    fi
    if ! getent ahosts dl.flathub.org >/dev/null 2>&1; then
        echo "No network: dl.flathub.org does not resolve. Connect and run this again." >&2
        exit 1
    fi
    if menu_tty && ! menu_confirm "Install these apps now?" y; then echo "Nothing installed."; exit 0; fi
    echo "Installing. If a polkit prompt appears, authorize it."
    out=$(mktemp)
    "$flatpak_bin" preinstall -y 2>&1 | tee "$out"
    status=${PIPESTATUS[0]}
    if [ "$status" -eq 0 ]; then
        echo "Done (exit status 0)."
    else
        echo "Failed (exit status $status)." >&2
        if grep -qi 'autolaunch' "$out"; then
            echo "The error mentions D-Bus autolaunch: an enabled 'fedora' OCI remote (stock Silverblue) asks for a token over the session bus. This recipe already runs in your session, so please report it; as a workaround, 'flatpak remote-modify --disable fedora' (system) and run it again." >&2
        fi
    fi
    rm -f -- "${out:?}"
    exit "$status"

# Step-by-step gaming setup: Steam, ProtonUp-Qt, Lutris, gamescope, extest, launchers, GameMode (--help for usage)
[group('Gaming')]
[positional-arguments]
gaming-setup *args:
    #!/usr/bin/env bash
    set -uo pipefail
    menu_lib="${OCTARINE_MENU_LIB:-/usr/share/octarine-os/lib/menu.sh}"
    # shellcheck source=/dev/null
    if [ -r "$menu_lib" ]; then . "$menu_lib"; fi
    if ! declare -F menu_ready >/dev/null; then menu_ready() { return 1; }; menu_ready_one() { return 1; }; menu_tty() { return 1; }; menu_title() { printf '%s\n' "$1"; }; menu_confirm() { return 1; }; fi
    mode=ask
    steps=""
    valid=" steam protonup lutris extensions extest desktop gamemode reset "
    usage="Usage: ujust gaming-setup [steam|protonup|lutris|extensions|extest|desktop|gamemode|reset ...] [--yes|--no]"
    for a in "$@"; do
        case "$a" in
            --yes) mode=yes ;;
            --no) mode=no ;;
            help | --help | -h) printf '%s\n' 'Gaming setup, a checklist with one y/n question per step, or name steps to run exactly those. `ujust gaming-setup [STEP...] [--yes|--no]`. Steps: steam (Flatpak Steam), protonup (ProtonUp-Qt Flatpak), lutris (Lutris Flatpak), extensions (gamescope and MangoHud Vulkan layers matching Steam'\''s runtime, Proton-GE, and the PATH override so they resolve inside the sandbox), extest (install the prebuilt extest libraries, 32-bit and 64-bit, from /usr/lib/extest, which the image ships), desktop (generated Steam launchers in ~/.local/share/applications: extest hooked in when it is installed, plus a gamescope launcher at your display'\''s resolution and refresh rate), gamemode (the GameMode tuning as ~/.config/gamemode.ini), reset (undo: generated launchers, the PATH line, optionally the extest library and the gamemode file). Flatpak apps are installed only when Flathub lists them as verified. --yes takes the defaults, --no only prints the plan. Settings: EXTEST_DEST (default ~/.local/lib/extest), GAMING_SETUP_RES (WxH@Hz instead of detecting it)'; exit 0 ;;
            -*) echo "Unknown option: $a" >&2; echo "$usage" >&2; exit 1 ;;
            *)
                case "$valid" in
                    *" $a "*) steps="$steps $a" ;;
                    *) echo "Unknown step: $a" >&2; echo "$usage" >&2; exit 1 ;;
                esac
                ;;
        esac
    done

    steam=com.valvesoftware.Steam
    apps_dir="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
    override_file="${XDG_DATA_HOME:-$HOME/.local/share}/flatpak/overrides/$steam"
    state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/octarine-os/gaming-setup"
    ext_dest=$(readlink -f -- "${EXTEST_DEST:-$HOME/.local/lib/extest}")
    ext_src="${GAMING_SETUP_EXTEST_SRC:-/usr/lib/extest}"
    ext_lib32="$ext_dest/lib/libextest.so"
    ext_so="$ext_dest/lib64/libextest.so"
    marker="X-Octarine-Generated=ujust gaming-setup"
    names=()
    results=()
    undos=()
    failed=0
    cur=""
    record() { names+=("$1"); results+=("$2"); undos+=("${3:--}"); }

    # selected <step>: explicitly named, or no step named at all
    selected() { [ -z "$steps" ] && return 0; case " $steps " in *" $1 "*) return 0 ;; esac; return 1; }
    explicit() { case " $steps " in *" $1 "*) return 0 ;; esac; return 1; }
    # ask <default y|n> <question>: an explicitly named step counts as yes
    ask() {
        local def=$1 q=$2 reply hint="[Y/n]"
        [ "$def" = n ] && hint="[y/N]"
        if [ "$mode" = no ]; then answer=n; return; fi
        if [ "$cur" != reset ] && explicit "$cur"; then answer=y; return; fi
        if [ "$mode" = yes ]; then answer=$def; return; fi
        printf '%s %s ' "$q" "$hint"
        read -r reply || reply=""
        case "$reply" in [Yy]*) answer=y ;; [Nn]*) answer=n ;; *) answer=$def ;; esac
    }
    skipped_result() { if [ "$mode" = no ]; then echo "planned (would ask)"; else echo "skipped (not applied)"; fi; }

    app_install_type() { flatpak list --app --columns=application,installation 2>/dev/null | awk -v a="$1" '$1 == a {print $2; exit}'; }
    installed() { flatpak info "$1" >/dev/null 2>&1; }

    # verified <app-id>: Flathub's appstream data marks the app verified (fails closed when it cannot tell)
    verified() {
        local d f dirs=${GAMING_SETUP_APPSTREAM_DIRS:-$HOME/.local/share/flatpak/appstream/flathub/x86_64/active:/var/lib/flatpak/appstream/flathub/x86_64/active} IFS=:
        for d in $dirs; do
            f="$d/appstream.xml.gz"
            [ -f "$f" ] || continue
            zcat "$f" 2>/dev/null | awk -v id="$1" '
                /<component/ { inb = 0; ok = 0 }
                index($0, "<id>" id "</id>") { inb = 1 }
                inb && /verification::verified">true</ { ok = 1 }
                /<\/component>/ { if (inb && ok) f = 1; inb = 0 }
                END { exit !f }' && return 0
        done
        return 1
    }
    # install_app <app-id>: install from Flathub in the user installation when verified; sets $inst_result
    install_app() {
        local id=$1
        if ! verified "$id"; then
            echo "Not installing $id: Flathub does not list it as verified (or the catalog is not available; run flatpak update --appstream and retry)."
            inst_result="skipped (not verified)"
            return 0
        fi
        flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo >/dev/null 2>&1
        if flatpak install --user -y flathub "$id"; then inst_result=applied; return 0; fi
        inst_result=FAILED
        return 1
    }
    app_step() { # step label app-id default
        cur=$1
        echo
        echo "== $1"
        if installed "$3"; then
            echo "$2 is already installed."
            record "$1" "already done"
            return
        fi
        echo "Installs $2 ($3) from Flathub, only if Flathub lists it as verified."
        ask "$4" "Apply?"
        if [ "$answer" != y ]; then record "$1" "$(skipped_result)"; return; fi
        install_app "$3"
        case "$inst_result" in
            applied) record "$1" applied "flatpak uninstall --user $3" ;;
            FAILED) failed=1; record "$1" FAILED ;;
            *) record "$1" "$inst_result" ;;
        esac
    }
    # path_value: the PATH override for Steam, with the extension bin directories that are installed
    path_value() {
        local v="PATH=/app/bin:/app/utils/bin:/usr/bin"
        flatpak info "org.freedesktop.Platform.VulkanLayer.gamescope//$1" >/dev/null 2>&1 && v="$v:/usr/lib/extensions/vulkan/gamescope/bin"
        flatpak info "org.freedesktop.Platform.VulkanLayer.MangoHud//$1" >/dev/null 2>&1 && v="$v:/usr/lib/extensions/vulkan/MangoHud/bin"
        echo "$v"
    }

    # GameMode's desiredgov=powersave is the workaround for upstream gamemode#419 and only right on amd-pstate in active
    # mode (amd-pstate-epp). On other CPUs or drivers the step is not pre-ticked and the line is left out of the file.
    pstate_active=0
    [ "$(cat "${GAMING_SETUP_PSTATE_STATUS:-/sys/devices/system/cpu/amd_pstate/status}" 2>/dev/null)" = active ] && pstate_active=1
    gm_default=$pstate_active
    # Terminal with gum and no step named: a checklist of the steps (the chosen ones run as if named, so they count
    # as confirmed); reset is only ever named explicitly. Otherwise the per-step questions are unchanged.
    if [ "$mode" = ask ] && [ -z "$steps" ] && menu_ready; then
        menu_title "octarineOS gaming setup"
        menu_multi "Gaming setup: choose the steps (Flathub apps are installed only when verified)" \
            "^Apps^0" \
            "steam^Steam^1" "protonup^ProtonUp-Qt^1" "lutris^Lutris^0" \
            "^Steam extras^0" \
            "extensions^gamescope, MangoHud, Proton-GE and the PATH override^1" \
            "extest^extest libraries (Steam Input on Wayland)^0" \
            "desktop^Generated Steam launchers^1" \
            "^Tuning^0" \
            "gamemode^GameMode tuning in ~/.config/gamemode.ini^$gm_default"
        if [ "${#MENU_RESULT[@]}" -eq 0 ]; then echo "Nothing selected; nothing changed."; exit 0; fi
        echo "Selected steps: ${MENU_RESULT[*]}"
        if ! menu_confirm "Run these steps?" y; then echo "Nothing changed."; exit 0; fi
        steps=" ${MENU_RESULT[*]}"
    fi

    if selected steam && ! explicit reset; then app_step steam "Steam" "$steam" y; fi
    if selected protonup && ! explicit reset; then app_step protonup "ProtonUp-Qt" net.davidotek.pupgui2 y; fi
    if selected lutris && ! explicit reset; then app_step lutris "Lutris" net.lutris.Lutris n; fi

    # extensions: gamescope and MangoHud Vulkan layers (branch = Steam's runtime branch) and Proton-GE (branch stable)
    if selected extensions && ! explicit reset; then
    cur=extensions
    echo
    echo "== extensions"
    inst=$(app_install_type "$steam")
    if [ -z "$inst" ]; then
        echo "Skipped: $steam is not installed (step steam)."
        record "extensions" "skipped (no Steam)"
    else
        branch=$(flatpak info --show-runtime "$steam" | cut -d/ -f3)
        refs=("org.freedesktop.Platform.VulkanLayer.gamescope//$branch" "org.freedesktop.Platform.VulkanLayer.MangoHud//$branch" "com.valvesoftware.Steam.CompatibilityTool.Proton-GE//stable")
        todo=()
        for ref in "${refs[@]}"; do
            if flatpak info "$ref" >/dev/null 2>&1; then continue; fi
            if flatpak remote-info flathub "$ref" >/dev/null 2>&1; then todo+=("$ref"); else echo "Not available on Flathub: $ref"; fi
        done
        path_done=0
        [ -f "$override_file" ] && grep -qxF "$(path_value "$branch")" "$override_file" && path_done=1
        if [ "${#todo[@]}" -eq 0 ] && [ "$path_done" = 1 ]; then
            echo "Extensions installed and the PATH override is in place."
            record "extensions" "already done"
        else
            echo "Installs (${inst}): ${todo[*]:-nothing new} and sets the Steam PATH override so gamescope and mangohud resolve inside the sandbox. Steam runtime branch: $branch."
            ask y "Apply?"
            if [ "$answer" != y ]; then
                record "extensions" "$(skipped_result)"
            else
                ok=1
                if [ "${#todo[@]}" -gt 0 ]; then flatpak install --"$inst" -y flathub "${todo[@]}" || ok=0; fi
                flatpak override --user "--env=$(path_value "$branch")" "$steam" || ok=0
                if [ "$ok" = 1 ]; then
                    echo "In Steam, set a game's launch options to, for example: gamescope -f -W 2560 -H 1440 -r 144 --adaptive-sync -- %command%   or   mangohud %command%"
                    record "extensions" applied "ujust gaming-setup reset removes the PATH line; flatpak uninstall ${todo[*]:-the extensions} removes them"
                else
                    failed=1
                    record "extensions" FAILED
                fi
            fi
        fi
    fi
    fi

    # extest: install the prebuilt libraries the image ships in /usr/lib/extest (built from https://github.com/redcodeworks/extest,
    # a fork of https://github.com/Supreeeme/extest by Supreeeme and contributors, MIT license) into $ext_dest, where the
    # Flatpak Steam reaches them through --filesystem=<dir>:ro. Nothing is built here.
    if selected extest && ! explicit reset; then
    cur=extest
    echo
    echo "== extest"
    same() { [ -f "$1" ] && [ -f "$2" ] && [ "$(sha256sum "$1" | cut -d' ' -f1)" = "$(sha256sum "$2" | cut -d' ' -f1)" ]; }
    if [ ! -f "$ext_src/lib/libextest.so" ] || [ ! -f "$ext_src/lib64/libextest.so" ]; then
        echo "The extest libraries are missing from $ext_src: this image does not ship them (update the image)." >&2
        failed=1
        record "extest" FAILED
    elif same "$ext_src/lib/libextest.so" "$ext_lib32" && same "$ext_src/lib64/libextest.so" "$ext_so"; then
        echo "extest is already installed: $ext_dest/lib and $ext_dest/lib64"
        record "extest" "already done"
    else
        echo "Installs the prebuilt extest libraries (X11 XTEST to uinput shim for Steam Input on Wayland) from $ext_src into $ext_dest, 32-bit as lib/libextest.so and 64-bit as lib64/libextest.so. Not verified end to end inside the Flatpak client."
        ask n "Apply?"
        if [ "$answer" != y ]; then
            record "extest" "$(skipped_result)"
        else
            # a file that is already there and differs (for example a library built by hand earlier) is kept with a timestamp
            stamp=$(date +%Y%m%d-%H%M%S)
            for f in "$ext_lib32" "$ext_so"; do
                if [ -f "$f" ]; then cp -p -- "$f" "$f.bak-$stamp" && echo "Kept the existing $f as $f.bak-$stamp"; fi
            done
            if install -Dm755 "$ext_src/lib/libextest.so" "$ext_lib32" && install -Dm755 "$ext_src/lib64/libextest.so" "$ext_so"; then
                echo "Installed $ext_lib32 and $ext_so (extest by Supreeeme and contributors, MIT license: https://github.com/Supreeeme/extest). Run the desktop step next."
                record "extest" applied "ujust gaming-setup reset (offers to remove the libraries)"
            else
                echo "Failed: could not install the extest libraries into $ext_dest" >&2
                failed=1
                record "extest" FAILED
            fi
        fi
    fi
    fi

    # desktop: generated launchers, recognizable by the X-Octarine-Generated key; only files carrying it are overwritten
    if selected desktop && ! explicit reset; then
    cur=desktop
    echo
    echo "== desktop (Steam launchers)"
    if ! installed "$steam"; then
        echo "Skipped: $steam is not installed (step steam)."
        record "desktop" "skipped (no Steam)"
    else
        hook=""
        label=""
        # LD_PRELOAD carries the literal $LIB: the dynamic loader (ld.so(8)) expands it to lib or lib64 per process, so
        # Steam's 32-bit client loads the 32-bit library and the 64-bit client the 64-bit one. In an Exec line the argument
        # is quoted and the dollar sign escaped (the desktop entry spec: \\$ in the file is \$ after unescaping, $ after
        # quoting); the shell must not see it, hence single quotes here.
        if [ -f "$ext_lib32" ] && [ -f "$ext_so" ]; then hook=' --filesystem='"$ext_dest"':ro "--env=LD_PRELOAD='"$ext_dest"'/\\$LIB/libextest.so"'; label="extest"; fi
        res=${GAMING_SETUP_RES:-}
        if [ -z "$res" ] && command -v gdbus >/dev/null 2>&1; then
            st=$(gdbus call --session --dest org.gnome.Mutter.DisplayConfig --object-path /org/gnome/Mutter/DisplayConfig --method org.gnome.Mutter.DisplayConfig.GetCurrentState 2>/dev/null | tr -d '\n')
            cur_mode=$(printf '%s' "$st" | grep -oE "\('[0-9]+x[0-9]+@[0-9.]+', [0-9]+, [0-9]+, [0-9.]+, [^{]*\{[^}]*'is-current': <true>" | head -1)
            if [ -n "$cur_mode" ]; then
                res=$(printf '%s' "$cur_mode" | sed -E "s/^\('[0-9]+x[0-9]+@[0-9.]+', ([0-9]+), ([0-9]+), ([0-9.]+),.*/\1x\2@\3/")
            fi
        fi
        if [ -z "$res" ] && command -v niri >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
            r=$(niri msg --json outputs 2>/dev/null | jq -r 'to_entries[0].value | .modes[.current_mode] | "\(.width)x\(.height)@\(.refresh_rate / 1000)"' 2>/dev/null)
            [[ "$r" =~ ^[0-9]+x[0-9]+@[0-9.]+$ ]] && res=$r
        fi
        if [ -z "$res" ] && [ "$mode" = ask ] && ! explicit desktop; then
            printf 'Could not detect the display mode. Enter it as WIDTHxHEIGHT@HZ (empty to skip the gamescope launcher): '
            read -r res || res=""
        fi
        if [ -n "$res" ] && ! [[ "$res" =~ ^[0-9]+x[0-9]+@[0-9.]+$ ]]; then
            echo "Ignoring '$res': not WIDTHxHEIGHT@HZ."
            res=""
        fi
        if [ -z "$res" ]; then
            echo "No display mode found: the gamescope launcher will not be generated (set GAMING_SETUP_RES=WIDTHxHEIGHT@HZ to give it)."
        else
            gw=${res%%x*}; rest=${res#*x}; gh=${rest%%@*}; ghz=${rest#*@}; ghz=$(printf '%.0f' "$ghz")
        fi
        echo "Generates Steam launchers in $apps_dir${label:+ with extest hooked in}${res:+, and a gamescope launcher at ${gw}x${gh} ${ghz} Hz}; only files carrying the $marker line are ever overwritten."
        ask y "Apply?"
        if [ "$answer" != y ]; then
            record "desktop" "$(skipped_result)"
        else
            mkdir -p "$apps_dir"
            changed=0
            dfail=0
            gen() { # file name exec
                local f="$apps_dir/$1" content
                content=$(printf '%s\n' "[Desktop Entry]" \
                    "# Generated by ujust gaming-setup; regenerate with: ujust gaming-setup desktop; remove with: ujust gaming-setup reset" \
                    "$marker" "Type=Application" "Name=$2" "Exec=$3" "Icon=com.valvesoftware.Steam" "Terminal=false" "Categories=Game;")
                if [ -f "$f" ] && ! grep -qxF "$marker" "$f"; then
                    echo "Not overwriting $f: it has no generated-file marker."
                    dfail=1
                    return
                fi
                if [ -f "$f" ] && [ "$(cat "$f")" = "$content" ]; then return; fi
                if printf '%s\n' "$content" >"$f"; then changed=1; else dfail=1; fi
            }
            gen octarine-gaming-steam.desktop "Steam${label:+ ($label)}" "flatpak run$hook $steam %U"
            if [ -n "$res" ]; then
                gen octarine-gaming-steam-gamescope.desktop "Steam (gamescope${label:+, $label})" "flatpak run --command=gamescope$hook $steam -f -W $gw -H $gh -r $ghz --adaptive-sync -- steam -gamepadui"
            fi
            command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$apps_dir" 2>/dev/null
            if [ "$dfail" = 1 ]; then failed=1; record "desktop" FAILED
            elif [ "$changed" = 0 ]; then echo "Launchers already up to date."; record "desktop" "already done"
            else
                echo "Launchers written to $apps_dir."
                record "desktop" applied "ujust gaming-setup reset removes the generated launchers (files named octarine-gaming-*.desktop)"
            fi
        fi
    fi
    fi

    # gamemode: the GameMode tuning as ~/.config/gamemode.ini (never overwritten silently)
    if selected gamemode && ! explicit reset; then
    cur=gamemode
    echo
    echo "== gamemode"
    src_ini=${GAMING_SETUP_GAMEMODE_SRC:-/usr/share/octarine-os/gamemode.ini}
    dest_ini="${XDG_CONFIG_HOME:-$HOME/.config}/gamemode.ini"
    if [ ! -f "$src_ini" ]; then
        echo "Skipped: $src_ini is missing."
        record "gamemode" "skipped (no source file)"
    else
        if [ "$pstate_active" = 0 ]; then
            # not amd-pstate-epp: drop the desiredgov workaround (its comment block and the line); the rest stays
            gm_tmp=$(mktemp)
            sed '/^; Keep the CPU governor/,/^desiredgov=/d' "$src_ini" >"$gm_tmp"
            src_ini=$gm_tmp
            echo "Note: amd-pstate is not in active mode on this machine, so desiredgov=powersave (the workaround for gamemode#419) is left out."
        fi
        command -v tuned-adm >/dev/null 2>&1 || echo "Note: tuned-adm is not installed, so the tuned part of the GameMode start and end hooks does nothing."
        id -nG | tr ' ' '\n' | grep -qx gamemode || echo "Note: you are not in the gamemode group, so renice does nothing; run ujust user-setup (groups step) and log in again."
        if [ -f "$dest_ini" ] && cmp -s "$src_ini" "$dest_ini"; then
            echo "$dest_ini already has the tuning."
            record "gamemode" "already done"
        else
            if [ -f "$dest_ini" ]; then
                echo "$dest_ini exists and differs:"
                diff -u "$dest_ini" "$src_ini"
                echo "Replacing it keeps a timestamped backup."
                ask n "Replace it?"
            else
                echo "Installs the GameMode tuning (renice=10,$([ "$pstate_active" = 1 ] && echo " desiredgov=powersave,") tuned latency-performance while a game runs) as $dest_ini."
                ask y "Apply?"
            fi
            if [ "$answer" != y ]; then
                record "gamemode" "$(skipped_result)"
            else
                mkdir -p "$state_dir" "$(dirname "$dest_ini")"
                backup=""
                if [ -f "$dest_ini" ]; then
                    backup="$dest_ini.bak-$(date +%Y%m%d%H%M%S)"
                    cp -p -- "$dest_ini" "$backup"
                fi
                if cp -- "$src_ini" "$dest_ini"; then
                    sha256sum "$dest_ini" | cut -d' ' -f1 >"$state_dir/gamemode.sha256"
                    printf '%s\n' "$backup" >"$state_dir/gamemode.backup"
                    echo "Installed $dest_ini${backup:+ (previous file saved as $backup)}."
                    record "gamemode" applied "ujust gaming-setup reset restores the backup or removes the file if unchanged"
                else
                    failed=1
                    record "gamemode" FAILED
                fi
            fi
        fi
    fi
    fi

    # reset: undo what this recipe did; installed Flatpaks stay
    if explicit reset; then
    cur=reset
    echo
    echo "== reset"
    mapfile -t gen_files < <(grep -lxF "$marker" "$apps_dir"/octarine-gaming-*.desktop 2>/dev/null)
    ask y "Remove the generated launchers (${#gen_files[@]} found)?"
    if [ "$answer" = y ]; then
        if [ "${#gen_files[@]}" -gt 0 ]; then rm -f -- "${gen_files[@]}"; echo "Removed ${gen_files[*]}"; fi
        record "reset: launchers" applied
    else
        record "reset: launchers" "$(skipped_result)"
    fi
    # only the lines this recipe (or the old steam-gamescope-setup / extest-steam-setup) added
    ask y "Remove the PATH override line from $override_file?"
    if [ "$answer" = y ]; then
        if [ -f "$override_file" ] && grep -q '^PATH=.*/usr/lib/extensions/vulkan/' "$override_file"; then
            tmp=$(mktemp "$override_file.XXXXXX")
            grep -v '^PATH=.*/usr/lib/extensions/vulkan/' "$override_file" >"$tmp" || true
            mv -- "$tmp" "$override_file"
            echo "Removed the PATH override from $override_file"
        fi
        if [ -f "$override_file" ] && grep -qxF "LD_PRELOAD=$ext_so" "$override_file"; then
            tmp=$(mktemp "$override_file.XXXXXX")
            grep -vxF "LD_PRELOAD=$ext_so" "$override_file" >"$tmp" || true
            content=$(<"$tmp")
            content=${content//"$ext_dest:ro;"/}
            printf '%s\n' "$content" >"$tmp"
            mv -- "$tmp" "$override_file"
            echo "Removed the old extest override entries from $override_file"
        fi
        record "reset: PATH override" applied
    else
        record "reset: PATH override" "$(skipped_result)"
    fi
    ask n "Also remove the extest libraries in $ext_dest?"
    if [ "$answer" = y ]; then
        rm -f -- "${ext_so:?}" "${ext_lib32:?}"
        rmdir "${ext_dest:?}/lib" "${ext_dest:?}/lib64" "${ext_dest:?}" 2>/dev/null
        record "reset: extest library" applied "ujust gaming-setup extest installs them again"
    else
        record "reset: extest library" "$(skipped_result)"
    fi
    dest_ini="${XDG_CONFIG_HOME:-$HOME/.config}/gamemode.ini"
    ask y "Undo the GameMode file (restore the backup, or remove it if unchanged)?"
    if [ "$answer" = y ]; then
        if [ -f "$state_dir/gamemode.sha256" ] && [ -f "$dest_ini" ] && [ "$(sha256sum "$dest_ini" | cut -d' ' -f1)" = "$(cat "$state_dir/gamemode.sha256")" ]; then
            backup=$(cat "$state_dir/gamemode.backup" 2>/dev/null)
            if [ -n "$backup" ] && [ -f "$backup" ]; then mv -f -- "$backup" "$dest_ini"; echo "Restored $backup to $dest_ini"; else rm -f -- "${dest_ini:?}"; echo "Removed $dest_ini"; fi
            rm -f "${state_dir:?}/gamemode.sha256" "${state_dir:?}/gamemode.backup"
            record "reset: gamemode file" applied
        elif [ ! -f "$state_dir/gamemode.sha256" ]; then
            echo "No record that this recipe installed $dest_ini; left alone."
            record "reset: gamemode file" "skipped (not ours)"
        else
            echo "$dest_ini changed since it was installed; left alone."
            record "reset: gamemode file" "skipped (changed since)"
        fi
    else
        record "reset: gamemode file" "$(skipped_result)"
    fi
    fi

    echo
    echo "== Summary (mode: $mode)"
    printf '%-28s %s\n' "STEP" "RESULT"
    for i in "${!names[@]}"; do printf '%-28s %s\n' "${names[$i]}" "${results[$i]}"; done
    any=0
    for i in "${!names[@]}"; do
        if [ "${results[$i]}" = applied ] && [ "${undos[$i]}" != "-" ]; then
            [ "$any" = 0 ] && { echo; echo "To undo (per step):"; any=1; }
            echo "  ${names[$i]}: ${undos[$i]}"
        fi
    done
    exit "$failed"

# Set up niri: copy config parts, portal file and polkit drop-in (--help)
[group('Setup')]
[positional-arguments]
niri-setup *args:
    #!/usr/bin/env bash
    set -uo pipefail
    menu_lib="${OCTARINE_MENU_LIB:-/usr/share/octarine-os/lib/menu.sh}"
    # shellcheck source=/dev/null
    if [ -r "$menu_lib" ]; then . "$menu_lib"; fi
    if ! declare -F menu_ready >/dev/null; then menu_ready() { return 1; }; menu_ready_one() { return 1; }; menu_tty() { return 1; }; menu_title() { printf '%s\n' "$1"; }; menu_confirm() { return 1; }; fi
    mode=ask
    only_list=""
    valid_steps=" niri portals polkit keybinds "
    kb_layout=""
    kb_switch=""
    kb_move=""
    kb_other=""
    kb_flags=0
    no_wizard=0
    # kb_set <option> <value>: validate a keybind wizard option (exit 2 on a bad name)
    kb_set() {
        local opt=$1 val=$2
        case "$opt" in
            --keybinds)
                case "$val" in standard | compact | hhkb) kb_layout=$val ;; *) echo "Unknown layout: $val (use standard, compact or hhkb)" >&2; exit 2 ;; esac
                ;;
            --switch-mod | --move-mod | --other-mod)
                case "$val" in
                    ctrl-alt | ctrl-super | meh | hypr) ;;
                    super) [ "$opt" = --other-mod ] || { echo "Unknown modifier for $opt: super (use ctrl-alt, ctrl-super, meh or hypr; super is only for --other-mod)" >&2; exit 2; } ;;
                    *) echo "Unknown modifier for $opt: $val (use ctrl-alt, ctrl-super, meh, hypr or, for --other-mod only, super)" >&2; exit 2 ;;
                esac
                case "$opt" in --switch-mod) kb_switch=$val ;; --move-mod) kb_move=$val ;; *) kb_other=$val ;; esac
                ;;
        esac
        kb_flags=1
    }
    args=("$@")
    i=0
    while [ "$i" -lt "${#args[@]}" ]; do
        a=${args[$i]}
        case "$a" in
            help | --help | -h) printf '%s\n' 'Set up a niri session in your home directory, a checklist with one y/n question per step. `ujust niri-setup [--yes|--no] [--only STEP[,STEP...]]`. Steps: niri (copies the image'\''s /etc/niri/*.kdl into ~/.config/niri/: a config.kdl that only lists include lines, plus one small file per topic; they are yours to edit, and deleting an include line from config.kdl drops that part), portals (~/.config/xdg-desktop-portal/niri-portals.conf: the packaged niri portal choices with the Secret portal pointed at oo7, which owns the secret service on this image), polkit (~/.config/noctalia/10-octarine-os.toml: turns on Noctalia'\''s built-in polkit agent, because niri has none; skipped when Noctalia is not installed), keybinds (EXPERIMENTAL keybind wizard, never part of the default run: you keep niri'\''s default key bindings unless you start it). A file that already exists and differs is never replaced silently: you see a diff, the default is keep, and a replacement first saves FILE.bak-YYYYMMDD-HHMMSS. --yes takes the defaults (existing different files are kept, the keybind wizard is not started), --no only prints the plan, --only runs the named steps. No sudo is used. niri applies config changes live; restart Noctalia for the polkit drop-in; the portal file applies at your next login.'
            printf '%s\n' 'Keybind wizard (experimental): the layouts and generated files may change between image versions. It validates the result with `niri validate` and restores the previous files on failure, and you can always return to niri'\''s defaults by putting include "40-binds.kdl" back in ~/.config/niri/config.kdl. Questions: the keyboard layout (Standard keys always, plus Compact = vim-style hjkl, or HHKB; the two extras exclude each other), the modifier for switching (focus) columns and workspaces, the modifier for moving them (must differ from the switching one) and the modifier for other actions. Modifiers: ctrl-alt (default for switching), ctrl-super (default for moving), meh (Ctrl+Alt+Shift), hypr (Ctrl+Alt+Shift+Super) and, for other actions only, super (default). MEH and HYPR need keys mapped in your keyboard firmware (a custom QMK mapping); most keyboards do not have them, so they are never preselected. It writes 40-binds-standard.kdl and 41-binds-compact.kdl or 41-binds-hhkb.kdl into ~/.config/niri/ and replaces the include "40-binds.kdl" line of config.kdl. Without a menu: `ujust niri-setup --only keybinds --keybinds standard|compact|hhkb [--switch-mod M] [--move-mod M] [--other-mod M]`; --no-wizard keeps the defaults; unknown names and the same modifier for switching and moving exit 2.'
            exit 0 ;;
            --keybinds | --switch-mod | --move-mod | --other-mod)
                i=$((i + 1))
                [ -n "${args[$i]:-}" ] || { echo "$a needs a value" >&2; exit 2; }
                kb_set "$a" "${args[$i]}"
                ;;
            --keybinds=* | --switch-mod=* | --move-mod=* | --other-mod=*) kb_set "${a%%=*}" "${a#*=}" ;;
            --no-wizard) no_wizard=1 ;;
            --yes) mode=yes ;;
            --no) mode=no ;;
            --only)
                i=$((i + 1))
                only_list=${args[$i]:-}
                [ -n "$only_list" ] || { echo "--only needs a step list" >&2; exit 2; }
                ;;
            --only=*) only_list=${a#--only=} ;;
            -*) echo "Unknown option: $a (use --yes, --no, --only STEP[,STEP...], or the keybind wizard options --keybinds, --switch-mod, --move-mod, --other-mod, --no-wizard)" >&2; exit 2 ;;
            *) echo "Unexpected argument: $a (steps are given with --only STEP[,STEP...])" >&2; exit 2 ;;
        esac
        i=$((i + 1))
    done
    if [ "$no_wizard" = 1 ] && [ "$kb_flags" = 1 ]; then echo "--no-wizard cannot be combined with the keybind wizard options" >&2; exit 2; fi
    # Defaults: switching ctrl-alt, moving ctrl-super, other actions super; the first two move to the next free one when
    # the other is taken. The same modifier for switching and moving is refused.
    if [ -z "$kb_switch" ]; then kb_switch=ctrl-alt; [ "$kb_move" = ctrl-alt ] && kb_switch=ctrl-super; fi
    if [ -z "$kb_move" ]; then kb_move=ctrl-super; [ "$kb_switch" = ctrl-super ] && kb_move=ctrl-alt; fi
    [ -n "$kb_layout" ] || kb_layout=standard
    [ -n "$kb_other" ] || kb_other=super
    if [ "$kb_switch" = "$kb_move" ]; then
        echo "The same modifier ($kb_switch) cannot be used for switching and for moving: pick two different ones (--switch-mod and --move-mod)." >&2
        exit 2
    fi
    if [ -n "$only_list" ]; then
        for s in ${only_list//,/ }; do
            case "$valid_steps" in
                *" $s "*) ;;
                *) echo "Unknown step: $s (steps:${valid_steps% })" >&2; exit 2 ;;
            esac
        done
    fi

    # Sources: the niri parts live in /etc/niri, the other two files in /usr/share/octarine-os/niri-setup. The test mode
    # OCTARINE_NIRI_SETUP_SRC points both at a fake tree ($SRC/niri/*.kdl, $SRC/niri-portals.conf, $SRC/10-octarine-os.toml).
    if [ -n "${OCTARINE_NIRI_SETUP_SRC:-}" ]; then
        niri_src=$OCTARINE_NIRI_SETUP_SRC/niri
        share_src=$OCTARINE_NIRI_SETUP_SRC
    else
        niri_src=/etc/niri
        share_src=/usr/share/octarine-os/niri-setup
    fi
    cfg="${XDG_CONFIG_HOME:-$HOME/.config}"
    names=()
    results=()
    undos=()
    failed=0
    kept_any=0
    preconfirmed=0

    record() { names+=("$1"); results+=("$2"); undos+=("${3:--}"); }
    sel() {
        [ -z "$only_list" ] && return 0
        case ",$only_list," in *",$1,"*) return 0 ;; esac
        return 1
    }
    # ask <default y|n> <question>: sets $answer. --yes takes the default, --no never applies.
    ask() {
        local def=$1 q=$2 reply hint="[Y/n]"
        [ "$def" = n ] && hint="[y/N]"
        case "$mode" in
            yes) answer=$def; return ;;
            no) answer=n; return ;;
        esac
        printf '%s %s ' "$q" "$hint"
        read -r reply || reply=""
        case "$reply" in
            [Yy]*) answer=y ;;
            [Nn]*) answer=n ;;
            *) answer=$def ;;
        esac
    }

    # ask_apply: the "Apply?" question of a step; a step chosen in the checklist was confirmed there already
    ask_apply() { if [ "$preconfirmed" = 1 ] && [ "$mode" != no ]; then answer=y; else ask y "Apply?"; fi; }

    # place <label> <src> <dest>: copy src to dest unless the destination is identical (already done). A different
    # existing file is never replaced silently: diff, default keep, backup before an explicit yes. Sets $place_result to
    # applied, already, kept, planned or failed, and $place_backup to the backup path when one was made.
    place() {
        local label=$1 src=$2 dest=$3 backup n
        place_backup=""
        if [ ! -f "$src" ]; then
            echo "  $label: source $src is missing" >&2
            place_result=failed
            return
        fi
        if [ -f "$dest" ] && cmp -s "$src" "$dest"; then
            echo "  $label: $dest is already identical (already done)."
            place_result=already
            return
        fi
        if [ -e "$dest" ] && [ ! -f "$dest" ]; then
            echo "  $label: $dest exists and is not a regular file; left alone." >&2
            place_result=failed
            return
        fi
        if [ -f "$dest" ]; then
            echo "  $label: $dest exists and differs (- yours, + shipped):"
            diff -u "$dest" "$src" | sed 's/^/    /'
            if [ "$mode" = no ]; then
                echo "  Plan: would ask before replacing it (default keep; a replacement saves a timestamped backup)."
                place_result=planned
                return
            fi
            echo "  Replacing it saves your file as $dest.bak-<date>-<time> first."
            ask n "  Replace $dest?"
            if [ "$answer" != y ]; then
                echo "  Kept your $dest."
                place_result=kept
                return
            fi
            backup="$dest.bak-$(date +%Y%m%d-%H%M%S)"
            n=0
            while [ -e "$backup" ]; do n=$((n + 1)); backup="$dest.bak-$(date +%Y%m%d-%H%M%S)-$n"; done
            if ! cp -p -- "$dest" "$backup"; then
                echo "  Could not back up $dest; nothing replaced." >&2
                place_result=failed
                return
            fi
            place_backup=$backup
        elif [ "$mode" = no ]; then
            echo "  Plan: would create $dest."
            place_result=planned
            return
        fi
        if mkdir -p -- "$(dirname "$dest")" && cp -- "$src" "$dest"; then
            echo "  $label: wrote $dest${place_backup:+ (your previous file is saved as $place_backup)}."
            place_result=applied
        else
            echo "  $label: could not write $dest" >&2
            place_result=failed
        fi
    }
    # Fold the per-file results of a step into one summary row.
    # finish_step <step> <undo>
    finish_step() {
        local step=$1 undo=$2 r
        if [ "${#file_results[@]}" -eq 0 ]; then record "$step" "skipped (nothing to do)"; return; fi
        for r in "${file_results[@]}"; do [ "$r" = failed ] && { failed=1; record "$step" FAILED; return; }; done
        for r in "${file_results[@]}"; do [ "$r" = applied ] && { record "$step" applied "$undo"; return; }; done
        for r in "${file_results[@]}"; do [ "$r" = planned ] && { record "$step" "planned (would ask)"; return; }; done
        for r in "${file_results[@]}"; do [ "$r" = kept ] && { kept_any=1; record "$step" "skipped (kept your different file)"; return; }; done
        record "$step" "already done"
    }

    # ---- keybind wizard (experimental)
    kb_mod_string() {
        case "$1" in
            ctrl-alt) echo "Ctrl+Alt" ;;
            ctrl-super) echo "Ctrl+Super" ;;
            meh) echo "Ctrl+Alt+Shift" ;;
            hypr) echo "Ctrl+Alt+Shift+Super" ;;
            super) echo "Mod" ;;
        esac
    }
    kb_qmk_note="needs these keys mapped in your keyboard firmware (a custom QMK mapping); most keyboards do not have them"
    # kb_mod_items <default id> <with super 0|1>: fills kb_items (id^text^), MEH and HYPR carry the note, never the default
    kb_mod_items() {
        local def=$1 id txt ids="ctrl-alt ctrl-super meh hypr"
        [ "$2" = 1 ] && ids="super ctrl-alt ctrl-super meh hypr"
        kb_items=()
        for id in $ids; do
            case "$id" in
                ctrl-alt) txt="Ctrl+Alt" ;;
                ctrl-super) txt="Ctrl+Super" ;;
                super) txt="Super" ;;
                meh) txt="MEH (Ctrl+Alt+Shift): $kb_qmk_note" ;;
                hypr) txt="HYPR (Ctrl+Alt+Shift+Super): $kb_qmk_note" ;;
            esac
            [ "$id" = "$def" ] && txt="$txt (default)"
            kb_items+=("$id^$txt^")
        done
    }
    # kb_pick <header> <default id> <item>...: sets $kb_picked; returns 1 when the choice was cancelled (Esc)
    kb_pick() {
        local header=$1 def=$2 spec id txt n reply rc
        shift 2
        kb_picked=""
        if menu_ready_one; then
            menu_one "$header" "$@"
            rc=$?
            if [ "$rc" = 0 ]; then kb_picked=$MENU_ONE; return 0; fi
            if [ "$rc" != 3 ]; then return 1; fi
        fi
        while true; do
            echo "$header"
            n=0
            for spec in "$@"; do
                n=$((n + 1))
                IFS='^' read -r id txt _ <<<"$spec"
                printf '  %d) %s\n' "$n" "$txt"
            done
            printf 'Choose 1-%d (Enter = the default): ' "$n"
            if ! read -r reply; then kb_picked=$def; return 0; fi
            if [ -z "$reply" ]; then kb_picked=$def; return 0; fi
            if [[ "$reply" =~ ^[0-9]+$ ]] && [ "$reply" -ge 1 ] && [ "$reply" -le "$n" ]; then
                n=0
                for spec in "$@"; do
                    n=$((n + 1))
                    IFS='^' read -r id txt _ <<<"$spec"
                    [ "$n" = "$reply" ] && { kb_picked=$id; return 0; }
                done
            fi
            echo "Not a valid choice: $reply"
        done
    }
    # kb_wizard: the four questions; sets kb_layout, kb_switch, kb_move, kb_other; returns 1 when cancelled
    kb_wizard() {
        kb_pick "Keyboard layout (the Standard keys are always included)" standard \
            "standard^Standard keyboard (arrows, PageUp, PageDown, Home, End) (default)^" \
            "compact^Compact keyboard (adds vim-style hjkl)^" \
            "hhkb^HHKB layout^" || return 1
        kb_layout=$kb_picked
        kb_mod_items ctrl-alt 0
        kb_pick "Modifier for SWITCHING columns and workspaces (focus)" ctrl-alt "${kb_items[@]}" || return 1
        kb_switch=$kb_picked
        local def=ctrl-super
        [ "$kb_switch" = ctrl-super ] && def=ctrl-alt
        while true; do
            kb_mod_items "$def" 0
            kb_pick "Modifier for MOVING columns, windows and columns to other workspaces" "$def" "${kb_items[@]}" || return 1
            kb_move=$kb_picked
            [ "$kb_move" != "$kb_switch" ] && break
            echo "The same modifier cannot be used for switching and for moving: $kb_switch is taken. Pick a different one."
        done
        kb_mod_items super 1
        kb_pick "Modifier for OTHER actions (terminal, close window, fullscreen, maximize, overview and the rest)" super "${kb_items[@]}" || return 1
        kb_other=$kb_picked
        return 0
    }
    # kb_apply: render the templates, write the files, switch the include lines, validate, restore on failure
    kb_apply() {
        local tdir=$share_src/keybinds conf="$cfg/niri/config.kdl" tmp snap dest name f n r
        local files=("standard") dests=() labels=() bks=() newconf any_kept=0 matched std
        [ "$kb_layout" = standard ] || files+=("$kb_layout")
        echo "Layout: $kb_layout; switching: $(kb_mod_string "$kb_switch"); moving: $(kb_mod_string "$kb_move"); other actions: $(kb_mod_string "$kb_other")."
        for f in "${files[@]}"; do
            if [ ! -f "$tdir/$f.kdl.in" ]; then
                echo "  template $tdir/$f.kdl.in is missing" >&2
                failed=1
                record "keybinds" FAILED
                return
            fi
        done
        if [ ! -f "$conf" ]; then
            echo "Skipped: $conf does not exist; run ujust niri-setup --only niri first, so there is a config.kdl to include the key bindings from."
            record "keybinds" "skipped (no config.kdl yet)"
            return
        fi
        tmp=$(mktemp -d) || { failed=1; record "keybinds" FAILED; return; }
        snap=$tmp/snap
        mkdir -p "$snap"
        for f in "${files[@]}"; do
            case "$f" in standard) name=40-binds-standard.kdl ;; *) name=41-binds-$f.kdl ;; esac
            sed -e "s|@SWITCH@|$(kb_mod_string "$kb_switch")|g" -e "s|@MOVE@|$(kb_mod_string "$kb_move")|g" \
                -e "s|@OTHER@|$(kb_mod_string "$kb_other")|g" "$tdir/$f.kdl.in" >"$tmp/$name"
            dests+=("$cfg/niri/$name")
            labels+=("$name")
        done
        for dest in "${dests[@]}" "$conf"; do
            if [ -f "$dest" ]; then cp -p -- "$dest" "$snap/$(basename "$dest")"; else : >"$snap/$(basename "$dest").absent"; fi
        done
        for n in "${!dests[@]}"; do
            place "${labels[$n]}" "$tmp/${labels[$n]}" "${dests[$n]}"
            file_results+=("$place_result")
            [ -n "$place_backup" ] && bks+=("$place_backup")
            [ "$place_result" = kept ] && any_kept=1
            if [ "$place_result" = failed ]; then
                echo "  Nothing else was changed." >&2
                failed=1
                record "keybinds" FAILED
                rm -rf -- "$tmp"
                return
            fi
        done
        if [ "$any_kept" = 1 ]; then
            echo "  You kept a different generated file, so config.kdl was not changed. Re-run and answer y to replace it."
        else
            # config.kdl: the line of the plain binds (or of an earlier wizard run) becomes the generated includes
            newconf=$tmp/config.kdl.new
            awk -v extra="$([ "$kb_layout" = standard ] && echo "" || echo "41-binds-$kb_layout.kdl")" '
                function emit() { print "include \"40-binds-standard.kdl\""; if (extra != "") print "include \"" extra "\"" }
                /^[[:space:]]*include[[:space:]]+"(40-binds\.kdl|40-binds-standard\.kdl|41-binds-(compact|hhkb)\.kdl)"[[:space:]]*$/ {
                    if (!done) { emit(); done = 1 }
                    next
                }
                { print }
                END { if (!done) exit 3 }' "$conf" >"$newconf"
            matched=$?
            std=1
            if [ "$matched" != 0 ]; then
                std=0
                awk -v extra="$([ "$kb_layout" = standard ] && echo "" || echo "41-binds-$kb_layout.kdl")" '
                    function emit() { print "include \"40-binds-standard.kdl\""; if (extra != "") print "include \"" extra "\"" }
                    /^[[:space:]]*include[[:space:]]+"50-noctalia\.kdl"/ && !done { emit(); done = 1 }
                    { print }
                    END { if (!done) emit() }' "$conf" >"$newconf"
            fi
            if cmp -s "$conf" "$newconf"; then
                echo "  config.kdl: the include lines are already right (already done)."
                file_results+=("already")
            else
                echo "  config.kdl: the include line change (- now, + new):"
                diff -u "$conf" "$newconf" | sed 's/^/    /'
                answer=y
                if [ "$std" = 0 ]; then
                    echo "  Your config.kdl does not have the standard include list, so the new lines would be added by guess."
                    ask n "  Apply this change to $conf?"
                fi
                if [ "$answer" = y ]; then
                    dest="$conf.bak-$(date +%Y%m%d-%H%M%S)"
                    n=0
                    while [ -e "$dest" ]; do n=$((n + 1)); dest="$conf.bak-$(date +%Y%m%d-%H%M%S)-$n"; done
                    if cp -p -- "$conf" "$dest" && cp -- "$newconf" "$conf"; then
                        bks+=("$dest")
                        echo "  config.kdl: updated (your previous file is saved as $dest)."
                        file_results+=("applied")
                    else
                        echo "  config.kdl: could not be updated" >&2
                        file_results+=("failed")
                    fi
                else
                    echo "  Kept your $conf. To use the generated parts add these lines to it, before the include of 50-noctalia.kdl:"
                    echo "    include \"40-binds-standard.kdl\""
                    [ "$kb_layout" = standard ] || echo "    include \"41-binds-$kb_layout.kdl\""
                    file_results+=("kept")
                fi
            fi
        fi
        for r in "${file_results[@]}"; do
            if [ "$r" = failed ]; then
                failed=1
                record "keybinds" FAILED
                rm -rf -- "$tmp"
                return
            fi
        done
        if [[ " ${file_results[*]} " == *" applied "* ]]; then
            if command -v niri >/dev/null 2>&1; then
                if niri validate -c "$conf" >"$tmp/validate.out" 2>&1; then
                    echo "  niri validate: $conf is valid."
                else
                    echo "  niri validate rejected the result:" >&2
                    sed 's/^/    /' "$tmp/validate.out" >&2
                    for dest in "${dests[@]}" "$conf"; do
                        name=$(basename "$dest")
                        if [ -f "$snap/$name" ]; then cp -p -- "$snap/$name" "$dest"; else rm -f -- "$dest"; fi
                    done
                    for f in "${bks[@]}"; do rm -f -- "$f"; done
                    echo "  The previous files were restored; nothing was changed." >&2
                    failed=1
                    record "keybinds" FAILED
                    rm -rf -- "$tmp"
                    return
                fi
            else
                echo "  niri is not installed here: validation was skipped."
            fi
        fi
        rm -rf -- "$tmp"
        finish_step keybinds "put include \"40-binds.kdl\" back in ${cfg}/niri/config.kdl instead of the 40-binds-*.kdl and 41-binds-*.kdl lines (or restore the .bak-* files); delete the generated 40-binds-standard.kdl and 41-binds-*.kdl if you do not want them"
    }

    # Terminal with gum: a checklist of steps up front; the chosen steps are not asked "Apply?" again, but replacing an
    # existing different file is still its own question (default keep).
    if [ "$mode" = ask ] && [ -z "$only_list" ] && menu_ready; then
        menu_title "octarineOS niri setup"
        menu_multi "Niri setup: choose the steps (no sudo; nothing existing is replaced without asking)" \
            "niri^Niri config files in ~/.config/niri^1" \
            "portals^Portal config with the oo7 secret portal^1" \
            "polkit^Noctalia polkit agent drop-in^1" \
            "keybinds^Keybind wizard (experimental)^$kb_flags"
        if [ "${#MENU_RESULT[@]}" -eq 0 ]; then echo "Nothing selected; nothing changed."; exit 0; fi
        echo "Selected steps: ${MENU_RESULT[*]}"
        if ! menu_confirm "Run these steps?" y; then echo "Nothing changed."; exit 0; fi
        only_list=$(IFS=,; echo "${MENU_RESULT[*]}")
        preconfirmed=1
    fi

    if sel niri; then
        echo
        echo "== niri"
        echo "Copies the niri config parts from $niri_src into ${cfg}/niri/ (config.kdl lists them with include lines). The copies are yours to edit."
        file_results=()
        shopt -s nullglob
        parts=("$niri_src"/*.kdl)
        shopt -u nullglob
        if [ "${#parts[@]}" -eq 0 ]; then
            echo "Skipped: no *.kdl files in $niri_src."
            record "niri" "skipped (no source files)"
        else
            ask_apply
            if [ "$answer" != y ] && [ "$mode" != no ]; then
                record "niri" "skipped (not applied)"
            else
                for p in "${parts[@]}"; do
                    place "$(basename "$p")" "$p" "$cfg/niri/$(basename "$p")"
                    file_results+=("$place_result")
                    if [ "$place_result" = kept ] && [ "$(basename "$p")" = config.kdl ]; then
                        echo "  Note: your config.kdl was kept, so the copied parts are not used until it has include lines for them (see the shipped config.kdl)."
                    fi
                done
                finish_step niri "delete the copied files in ${cfg}/niri/ (or restore a .bak-* file); with no config.kdl niri falls back to /etc/niri/config.kdl"
            fi
        fi
    fi

    if sel keybinds; then
        echo
        echo "== keybinds"
        echo "Keybind wizard (experimental): writes ${cfg}/niri/40-binds-standard.kdl (plus 41-binds-compact.kdl or 41-binds-hhkb.kdl) and swaps the include \"40-binds.kdl\" line of config.kdl for them. Without it you keep niri's default key bindings."
        file_results=()
        kb_run=0
        if [ "$no_wizard" = 1 ]; then
            echo "Skipped (--no-wizard): niri's default key bindings (40-binds.kdl) stay."
            record "keybinds" "skipped (wizard not started)"
        elif [ "$mode" = no ]; then
            echo "Plan: would ask 'Start the keybind wizard (experimental)?' (default no)."
            record "keybinds" "planned (would ask)"
        elif [ "$kb_flags" = 1 ]; then
            echo "Notice: the keybind wizard is experimental; the layouts and generated files may change between image versions. The result is checked with niri validate and the previous files are restored on failure."
            kb_run=1
        elif [ "$mode" = yes ]; then
            echo "Skipped: --yes alone does not start the keybind wizard (it is experimental). Use --keybinds standard|compact|hhkb to run it without questions."
            record "keybinds" "skipped (wizard not started)"
        else
            echo "Notice: the keybind wizard is experimental. The layouts and generated files may change between image versions; the result is checked with niri validate and the previous files are restored on failure, and you can always go back to niri's defaults (include \"40-binds.kdl\" in config.kdl)."
            ask n "Start the keybind wizard (experimental)?"
            if [ "$answer" != y ]; then
                echo "Not started: niri's default key bindings stay."
                record "keybinds" "skipped (wizard not started)"
            elif kb_wizard; then
                kb_run=1
            else
                echo "Wizard cancelled; nothing changed."
                record "keybinds" "skipped (wizard cancelled)"
            fi
        fi
        if [ "$kb_run" = 1 ]; then kb_apply; fi
    fi

    if sel portals; then
        echo
        echo "== portals"
        echo "Installs ${cfg}/xdg-desktop-portal/niri-portals.conf: the packaged niri portal choices with the Secret portal set to oo7-portal (this image's secret service is oo7, while niri's packaged file selects gnome-keyring). A user file replaces the packaged one entirely."
        file_results=()
        ask_apply
        if [ "$answer" != y ] && [ "$mode" != no ]; then
            record "portals" "skipped (not applied)"
        else
            place niri-portals.conf "$share_src/niri-portals.conf" "$cfg/xdg-desktop-portal/niri-portals.conf"
            file_results+=("$place_result")
            finish_step portals "delete ${cfg}/xdg-desktop-portal/niri-portals.conf (the packaged file applies again at the next login)"
        fi
    fi

    if sel polkit; then
        echo
        echo "== polkit"
        echo "Writes ${cfg}/noctalia/10-octarine-os.toml, which turns on Noctalia's built-in polkit agent ([shell] polkit_agent = true): niri has no agent of its own, so without one privileged prompts fail in a niri session. Do not run another polkit agent beside it. Your own config.toml still wins (its name sorts after 10-)."
        file_results=()
        if ! command -v noctalia >/dev/null 2>&1; then
            echo "Skipped: noctalia is not installed."
            record "polkit" "skipped (noctalia not installed)"
        else
            ask_apply
            if [ "$answer" != y ] && [ "$mode" != no ]; then
                record "polkit" "skipped (not applied)"
            else
                place 10-octarine-os.toml "$share_src/10-octarine-os.toml" "$cfg/noctalia/10-octarine-os.toml"
                file_results+=("$place_result")
                finish_step polkit "delete ${cfg}/noctalia/10-octarine-os.toml and restart Noctalia"
            fi
        fi
    fi

    echo
    echo "== Summary (mode: $mode)"
    printf '%-12s %s\n' "STEP" "RESULT"
    for i in "${!names[@]}"; do
        printf '%-12s %s\n' "${names[$i]}" "${results[$i]}"
    done
    any=0
    for i in "${!names[@]}"; do
        if [ "${results[$i]}" = applied ] && [ "${undos[$i]}" != "-" ]; then
            [ "$any" = 0 ] && { echo; echo "To undo (per step):"; any=1; }
            echo "  ${names[$i]}: ${undos[$i]}"
        fi
    done
    for i in "${!names[@]}"; do
        if [ "${results[$i]}" = applied ]; then
            case "${names[$i]}" in
                niri) echo "niri: reloads included config files live, no restart needed (a syntax error is shown in a notification)." ;;
                portals) echo "portals: applies at your next login." ;;
                keybinds) echo "keybinds: niri reloads the generated key bindings live (the wizard is experimental: the layouts may change between image versions)." ;;
                polkit) echo "polkit: restart Noctalia (or log in again) for the drop-in to take effect." ;;
            esac
        fi
    done
    for i in "${!names[@]}"; do
        if [ "${results[$i]}" = FAILED ]; then echo "Re-run the failed step: ujust niri-setup --only ${names[$i]}"; fi
    done
    [ "$kept_any" = 1 ] && echo "Files you already had were kept. Re-run and answer y to a replace question to take the shipped file (your file is backed up first)."
    exit "$failed"

# Themes and icons from the gnome-themes repo; no arguments opens a menu of its recipes (--help lists them)
[group('Appearance')]
[positional-arguments]
gnome-candy *args:
    #!/usr/bin/env bash
    set -euo pipefail
    menu_lib="${OCTARINE_MENU_LIB:-/usr/share/octarine-os/lib/menu.sh}"
    # shellcheck source=/dev/null
    if [ -r "$menu_lib" ]; then . "$menu_lib"; fi
    if ! declare -F menu_ready >/dev/null; then menu_ready() { return 1; }; menu_ready_one() { return 1; }; menu_tty() { return 1; }; menu_title() { printf '%s\n' "$1"; }; menu_confirm() { return 1; }; fi
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
    # No arguments in a terminal: a menu of the checked-out repository's public recipes (name - comment), read from the
    # structured `just --dump --dump-format json` (never from the human `just --list`, which prints group headings).
    # Private recipes and `default` are not offered; only REQUIRED parameters (no default) are asked for. A parser
    # failure or no parser (jq, then python3) shows the plain recipe list instead, never a broken menu.
    if [ "$#" -eq 0 ] && menu_ready_one; then
        recipes_tsv() {
            local json
            json=$(just --justfile "$dir/justfile" --working-directory "$dir" --dump --dump-format json 2>/dev/null) || return 1
            if command -v jq >/dev/null 2>&1; then
                printf '%s' "$json" | jq -r '.recipes | to_entries | map(select(.value.private == false and .key != "default"))
                    | map({n: .key, d: (.value.doc // ""), g: ([.value.attributes[]? | select(type == "object") | .group // empty] | first // "~"),
                           r: ([.value.parameters[]? | select(.default == null and .kind != "star") | .name] | join(" "))})
                    | sort_by(.g, .n) | .[] | [.n, .d, .r] | join("\u001f")' 2>/dev/null
            elif command -v python3 >/dev/null 2>&1; then
                printf '%s' "$json" | python3 -I -c '
    import json, sys
    d = json.load(sys.stdin)
    rows = []
    for n, r in d["recipes"].items():
        if r.get("private") or n == "default":
            continue
        g = "~"
        for a in r.get("attributes", []):
            if isinstance(a, dict) and a.get("group"):
                g = a["group"]
                break
        req = [p["name"] for p in r.get("parameters", []) if p.get("default") is None and p.get("kind") != "star"]
        rows.append((g, n, r.get("doc") or "", " ".join(req)))
    for g, n, doc, req in sorted(rows):
        print("\x1f".join([n, doc, req]))' 2>/dev/null
            else
                return 1
            fi
        }
        specs=()
        declare -A required_of=()
        if rows=$(recipes_tsv); then
            while IFS=$'\x1f' read -r rname rdoc rreq; do
                [ -n "$rname" ] || continue
                rdoc=${rdoc//^/ }
                specs+=("$rname^$rname${rdoc:+ - $rdoc}")
                required_of[$rname]=$rreq
            done <<<"$rows"
        fi
        if [ "${#specs[@]}" -eq 0 ]; then
            echo "Recipes of gnome-themes (run: ujust gnome-candy <recipe>):"
            just --justfile "$dir/justfile" --working-directory "$dir" --summary | tr ' ' '\n' | sed 's/^/  /'
            exit 0
        fi
        if menu_one "gnome-candy: choose a recipe" "${specs[@]}"; then
            vals=()
            for pname in ${required_of[$MENU_ONE]:-}; do
                read -r -p "$pname: " pval || pval=""
                if [ -z "$pval" ]; then echo "$pname is required; nothing run."; exit 0; fi
                vals+=("$pval")
            done
            exec just --justfile "$dir/justfile" --working-directory "$dir" "$MENU_ONE" "${vals[@]}"
        fi
        echo "Nothing chosen."
        exit 0
    fi
    if [ "${1:-}" = help ] || [ "${1:-}" = --help ]; then
        echo "ujust gnome-candy [recipe [arguments]]: runs a recipe of github.com/redcodeworks/gnome-themes from a fresh checkout. Recipes:"
        just --justfile "$dir/justfile" --working-directory "$dir" --list --unsorted
        exit 0
    fi
    exec just --justfile "$dir/justfile" --working-directory "$dir" "$@"

# Switch between the octarineOS images (default, dx, nvidia, nvidia-dx) and channels (latest, beta, testing)
[group('Setup')]
[positional-arguments]
switch-image *args:
    #!/usr/bin/env bash
    set -uo pipefail
    menu_lib="${OCTARINE_MENU_LIB:-/usr/share/octarine-os/lib/menu.sh}"
    # shellcheck source=/dev/null
    if [ -r "$menu_lib" ]; then . "$menu_lib"; fi
    if ! declare -F menu_ready >/dev/null; then menu_ready() { return 1; }; menu_ready_one() { return 1; }; menu_tty() { return 1; }; menu_title() { printf '%s\n' "$1"; }; menu_confirm() { return 1; }; fi
    mode=ask
    list=0
    force=0
    image=""
    channel=""
    for a in "$@"; do
        case "$a" in
            help | --help | -h) printf '%s\n' 'Switch this machine to another octarineOS image or channel. `ujust switch-image [IMAGE] [CHANNEL] [--yes|--no|--force|--list]`. The nvidia images ask first on a machine without an NVIDIA GPU (--yes alone does not bypass it; --force does). Images: default, dx (developer tools), nvidia (proprietary NVIDIA driver), nvidia-dx. Channels: latest (the default), beta (built on the next Fedora base), testing (unreleased builds; not every image has one). Without arguments it shows the current image and asks. With only an image it keeps the current channel (latest when pinned). It checks that the target is published, then runs `sudo bootc switch --enforce-container-sigpolicy`; reboot to use it, `sudo bootc rollback` to undo. --list shows what is published, --yes skips the question, --no only prints the plan.'; exit 0 ;;
            --yes) mode=yes ;;
            --no) mode=no ;;
            --list) list=1 ;;
            --force) force=1 ;;
            default | dx | nvidia | nvidia-dx) image=$a ;;
            latest | beta | testing) channel=$a ;;
            -*) echo "Unknown option: $a (use --yes, --no, --force or --list)" >&2; exit 2 ;;
            *) echo "Unknown image or channel: $a (images: default, dx, nvidia, nvidia-dx; channels: latest, beta, testing)" >&2; exit 2 ;;
        esac
    done
    name_of() {
        case "$1" in
            default) echo octarine-os ;;
            dx) echo octarine-os-dx ;;
            nvidia) echo octarine-os-nvidia ;;
            nvidia-dx) echo octarine-os-nvidia-dx ;;
        esac
    }
    # The running image, from the booted deployment: transport prefix and digest stripped
    cur_ref=${OCTARINE_SWITCH_CURRENT_REF:-}
    if [ -z "$cur_ref" ]; then
        cur_ref=$(rpm-ostree status -b --json 2>/dev/null | jq -r '.deployments[0]."container-image-reference" // empty' 2>/dev/null)
    fi
    cur=$(printf '%s' "$cur_ref" | sed -E 's#^ostree[a-z-]*:##; s#^docker://##; s#@sha256:[0-9a-f]+$##')
    cur_image=other
    cur_channel=""
    registry=ghcr.io/redcodeworks
    if [ -n "$cur" ]; then
        name_tag=${cur##*/}
        cur_name=${name_tag%%:*}
        cur_tag=latest
        case "$name_tag" in *:*) cur_tag=${name_tag#*:} ;; esac
        for k in default dx nvidia nvidia-dx; do
            if [ "$cur_name" = "$(name_of "$k")" ]; then cur_image=$k; registry=${cur%/*}; fi
        done
        case "$cur_tag" in latest | beta | testing) cur_channel=$cur_tag ;; esac
    fi
    # probe IMAGE CHANNEL: 0 published, 1 not published, 2 registry unreachable
    probe() {
        local err rc
        err=$(timeout 25 skopeo inspect --raw "docker://$registry/$(name_of "$1"):$2" 2>&1 >/dev/null)
        rc=$?
        if [ "$rc" = 0 ]; then return 0; fi
        case "$err" in
            *"manifest unknown"* | *"name unknown"* | *"not found"* | *"requested access"* | *"denied"* | *"404"*) return 1 ;;
        esac
        return 2
    }
    if [ -n "$cur" ]; then
        echo "Current: $cur"
    else
        echo "Current: unknown (rpm-ostree reports no container image)"
    fi
    if [ "$list" = 1 ]; then
        tmp=$(mktemp -d)
        trap 'rm -rf -- "$tmp"' EXIT
        for k in default dx nvidia nvidia-dx; do
            for c in latest beta testing; do
                (probe "$k" "$c"; echo $? >"$tmp/$k.$c") &
            done
        done
        wait
        printf '%-12s %-18s %-18s %-18s\n' IMAGE latest beta testing
        for k in default dx nvidia nvidia-dx; do
            row=$(printf '%-12s' "$k")
            for c in latest beta testing; do
                case "$(cat "$tmp/$k.$c" 2>/dev/null)" in 0) s=published ;; 1) s="not published" ;; *) s=unknown ;; esac
                if [ "$k" = "$cur_image" ] && [ "$c" = "$cur_channel" ]; then s="$s (current)"; fi
                row+=$(printf ' %-18s' "$s")
            done
            printf '%s\n' "$row"
        done
        exit 0
    fi
    if [ -z "$image" ]; then
        if menu_ready_one; then
            menu_one "Which image?" \
                "default^default: the base image" \
                "dx^dx: developer tools, compilers and virtualization" \
                "nvidia^nvidia: proprietary NVIDIA driver" \
                "nvidia-dx^nvidia-dx: NVIDIA driver and developer tools" || { echo "No image chosen; nothing changed."; exit 0; }
            image=$MENU_ONE
        else
            echo "Name an image: default, dx, nvidia or nvidia-dx (ujust switch-image --help)" >&2
            exit 2
        fi
    fi
    if [ -z "$channel" ]; then
        if [ -n "$cur_channel" ] && { [ "$mode" != ask ] || ! menu_ready_one; }; then
            channel=$cur_channel
        elif menu_ready_one; then
            menu_one "Which channel?" \
                "latest^latest: tested daily build (recommended)" \
                "beta^beta: built on the next Fedora base, not tested for daily use" \
                "testing^testing: unreleased builds" || { echo "No channel chosen; nothing changed."; exit 0; }
            channel=$MENU_ONE
        else
            channel=latest
        fi
    fi
    ref="$registry/$(name_of "$image"):$channel"
    if [ "$image" = "$cur_image" ] && [ "$channel" = "$cur_channel" ]; then
        echo "Already on $image ($channel)."
        exit 0
    fi
    # An image that a bootc switch already STAGED (waiting for the reboot) is not the booted one: do not switch (and ask for a security key touch) again.
    staged_ref=${OCTARINE_SWITCH_STAGED_REF-}
    if [ -z "${OCTARINE_SWITCH_STAGED_REF+x}" ]; then
        staged_ref=$(rpm-ostree status --json 2>/dev/null | jq -r '[.deployments[] | select(.staged == true)][0]."container-image-reference" // empty' 2>/dev/null)
    fi
    staged=$(printf '%s' "$staged_ref" | sed -E 's#^ostree[a-z-]*:##; s#^docker://##; s#@sha256:[0-9a-f]+$##')
    if [ -n "$staged" ] && [ "$staged" = "$ref" ]; then
        echo "$image ($channel) is already staged: reboot to use it. Nothing to do ('sudo bootc rollback' goes back to the previous deployment)."
        exit 0
    fi
    if [ -n "$staged" ]; then echo "Note: $staged is staged and waiting for a reboot; this switch replaces it."; fi
    # nvidia images on a machine without an NVIDIA GPU: say so and ask (--yes alone does not bypass it, --force does)
    case "$image" in
        nvidia | nvidia-dx)
            has_nvidia=0
            for v in "${OCTARINE_SYSFS_DRM:-/sys/class/drm}"/card*/device/vendor; do
                [ -r "$v" ] && [ "$(cat "$v" 2>/dev/null)" = 0x10de ] && has_nvidia=1
            done
            if [ "$has_nvidia" = 0 ] && [ "$force" = 0 ]; then
                echo "This machine has no NVIDIA GPU, so the $image image gives you a driver you cannot use (and it needs Secure Boot key enrollment)."
                if [ "$mode" = no ]; then
                    echo "(A real run would ask for confirmation, or need --force.)"
                elif [ "$mode" = yes ]; then
                    echo "Not switching: --yes does not bypass this. Add --force to switch anyway." >&2
                    exit 1
                else
                    menu_confirm "Switch to $image anyway?" n || { echo "Left as it is."; exit 0; }
                fi
            fi
            ;;
    esac
    echo "Target:  $ref"
    probe "$image" "$channel"
    case $? in
        0) ;;
        1) echo "$ref is not published (yet). Run 'ujust switch-image --list' to see what is." >&2; exit 1 ;;
        *) echo "Could not reach the registry to check $ref. Check the network and try again." >&2; exit 1 ;;
    esac
    case "$image" in
        nvidia | nvidia-dx) echo "With Secure Boot, run 'ujust enroll-secure-boot-key' first if you have not enrolled the key." ;;
    esac
    case "$image" in
        nvidia-dx) echo "If bootc refuses with a signature-policy error, update to the newest image of your current line, reboot, and run this again (this image's signature rule only exists on images built after it was added)." ;;
    esac
    case "$channel" in
        beta | testing) echo "The $channel channel is not tested for daily use." ;;
    esac
    cmd=(sudo bootc switch --enforce-container-sigpolicy "$ref")
    if [ "$mode" = no ]; then
        echo "Would run: ${cmd[*]}"
        exit 0
    fi
    if [ "$mode" = ask ]; then
        menu_confirm "Switch to $image ($channel)?" n || { echo "Left as it is."; exit 0; }
    fi
    "${cmd[@]}" || { echo "bootc switch failed; nothing changed." >&2; exit 1; }
    echo "Switched. Reboot to use $image ($channel); 'sudo bootc rollback' goes back to the previous deployment."

# TPM2 auto-unlock for LUKS volumes: a checklist of every LUKS device; enroll, re-enroll or remove (menu or arguments)
[group('Setup')]
[positional-arguments]
luks-tpm-unlock *args:
    #!/usr/bin/env bash
    set -uo pipefail
    menu_lib="${OCTARINE_MENU_LIB:-/usr/share/octarine-os/lib/menu.sh}"
    # shellcheck source=/dev/null
    if [ -r "$menu_lib" ]; then . "$menu_lib"; fi
    if ! declare -F menu_ready >/dev/null; then menu_ready() { return 1; }; menu_ready_one() { return 1; }; menu_tty() { return 1; }; menu_title() { printf '%s\n' "$1"; }; menu_confirm() { return 1; }; fi
    action=""
    pcrs=7+14
    pin=0
    mode=ask
    want=()
    for a in "$@"; do
        case "$a" in
            help | --help | -h) printf '%s\n' 'Let the TPM unlock LUKS volumes at boot. `ujust luks-tpm-unlock [enroll|remove] [DEVICE...] [--pcrs=7+14|7] [--pin] [--yes|--no]`. It lists every LUKS device (root and data), shows which already have a TPM2 key, and asks which to change; DEVICE is a path or UUID. enroll replaces an existing TPM2 key, then asks for the volume passphrase; remove deletes only the TPM2 key (passphrases stay). PCR 7+14 (default) ties the key to the Secure Boot state and to the enrolled MOK keys, so enrolling or removing a MOK key breaks the unlock until you re-enroll; --pcrs=7 ties it to the Secure Boot state only. --pin asks for a PIN at boot as well. Uses sudo (YubiKey). On AMD CPUs read the warning it prints first.'; exit 0 ;;
            enroll | remove) action=$a ;;
            --pcrs=*) pcrs=${a#--pcrs=} ;;
            --pin) pin=1 ;;
            --yes) mode=yes ;;
            --no) mode=no ;;
            -*) echo "Unknown option: $a (use --pcrs=7|7+14, --pin, --yes or --no)" >&2; exit 2 ;;
            *) want+=("$a") ;;
        esac
    done
    case "$pcrs" in 7 | 7+14) ;; *) echo "--pcrs takes 7 or 7+14" >&2; exit 2 ;; esac
    if [ ! -e "${OCTARINE_TPM_DEVICE:-/dev/tpmrm0}" ]; then
        echo "This machine has no TPM 2.0 device (${OCTARINE_TPM_DEVICE:-/dev/tpmrm0} is missing), so TPM2 auto-unlock is not possible here. Check the firmware settings (fTPM or PTT) if you expected one. Nothing changed."
        exit 0
    fi
    sudo -v || { echo "sudo is needed to read the LUKS headers (YubiKey touch)." >&2; exit 1; }
    devs=()
    declare -A uuid_of=() size_of=() tpm_of=()
    while read -r name fstype uid sz; do
        [ "$fstype" = crypto_LUKS ] || continue
        devs+=("$name")
        uuid_of[$name]=$uid
        size_of[$name]=$sz
    done < <(lsblk -rpno NAME,FSTYPE,UUID,SIZE 2>/dev/null)
    if [ "${#devs[@]}" -eq 0 ]; then echo "No LUKS devices found."; exit 0; fi
    cmdline=${OCTARINE_LUKS_CMDLINE:-/proc/cmdline}
    root_uuid=$(tr ' ' '\n' <"$cmdline" 2>/dev/null | sed -n 's/^rd\.luks\.uuid=luks-//p' | head -n1)
    for d in "${devs[@]}"; do
        if sudo cryptsetup luksDump "$d" 2>/dev/null | grep -q systemd-tpm2; then tpm_of[$d]=yes; else tpm_of[$d]=no; fi
    done
    describe() { # device
        local role=data
        [ -n "$root_uuid" ] && [ "${uuid_of[$1]}" = "$root_uuid" ] && role=root
        printf '%s  %s  %s  %s  TPM2 key: %s' "$1" "${size_of[$1]}" "${uuid_of[$1]:0:8}" "$role" "$([ "${tpm_of[$1]}" = yes ] && echo enrolled || echo none)"
    }
    if [ -z "$action" ]; then
        if menu_ready_one; then
            menu_one "What do you want to do?" \
                "enroll^Enroll or re-enroll TPM2 unlock" \
                "remove^Remove TPM2 unlock" || { echo "Nothing chosen; nothing changed."; exit 0; }
            action=$MENU_ONE
        else
            echo "Name an action: enroll or remove (ujust luks-tpm-unlock --help)" >&2
            exit 2
        fi
    fi
    chosen=()
    if [ "${#want[@]}" -gt 0 ]; then
        for w in "${want[@]}"; do
            hit=""
            for d in "${devs[@]}"; do
                if [ "$w" = "$d" ] || [ "$w" = "${uuid_of[$d]}" ] || [ "$w" = "/dev/disk/by-uuid/${uuid_of[$d]}" ]; then hit=$d; fi
            done
            [ -n "$hit" ] || { echo "No LUKS device matches: $w" >&2; exit 2; }
            chosen+=("$hit")
        done
    elif menu_ready; then
        items=()
        for d in "${devs[@]}"; do
            sel=0
            if [ "$action" = enroll ] && [ "${tpm_of[$d]}" = no ]; then sel=1; fi
            if [ "$action" = remove ] && [ "${tpm_of[$d]}" = yes ]; then sel=1; fi
            items+=("$d^$(describe "$d")^$sel")
        done
        menu_multi "LUKS devices: tick the ones to $action" "${items[@]}"
        chosen=("${MENU_RESULT[@]}")
    else
        for d in "${devs[@]}"; do describe "$d"; echo; done
        echo "Name the devices (path or UUID) or run it in a terminal for the checklist." >&2
        exit 2
    fi
    if [ "${#chosen[@]}" -eq 0 ]; then echo "Nothing selected."; exit 0; fi
    if [ "$action" = enroll ]; then
        cpuinfo=${OCTARINE_LUKS_CPUINFO:-/proc/cpuinfo}
        if grep -qi AuthenticAMD "$cpuinfo" 2>/dev/null; then
            echo "WARNING: do not use TPM-only unlock if your CPU is vulnerable to faulTPM (AMD Zen 1 to Zen 3), and"
            echo "Zen 4 has a similar exploit that a BIOS update mitigates. With physical access an attacker may be"
            echo "able to read the key. Adding a PIN (--pin) makes this much harder."
            if [ "$mode" = ask ]; then menu_confirm "Enroll anyway?" n || { echo "Left as it is."; exit 0; }; fi
        fi
    fi
    for d in "${chosen[@]}"; do
        echo "$action  PCR $pcrs$([ "$pin" = 1 ] && echo ' + PIN')  $(describe "$d")"
    done
    if [ "$mode" = no ]; then exit 0; fi
    if [ "$mode" = ask ]; then
        menu_confirm "Go ahead?" n || { echo "Left as it is."; exit 0; }
    fi
    failed=0
    root_done=0
    for d in "${chosen[@]}"; do
        if [ "$action" = remove ]; then
            echo "== Removing the TPM2 key from $d"
            sudo systemd-cryptenroll --wipe-slot=tpm2 "$d" || failed=1
            continue
        fi
        # One call enrolls the new TPM2 key first and wipes the old TPM2 slot only when that succeeded (systemd-cryptenroll(1),
        # --wipe-slot=: "the enrollment is completed first, and only when successful the wipe operation executed"), so a
        # cancelled or failed enrollment leaves the old key in place.
        enroll_args=(--tpm2-device=auto "--tpm2-pcrs=$pcrs")
        if [ "$pin" = 1 ]; then enroll_args+=(--tpm2-with-pin=yes); fi
        if [ "${tpm_of[$d]}" = yes ]; then
            echo "== Replacing the TPM2 key on $d (asks for the volume passphrase; the old key stays if this fails)"
            enroll_args+=(--wipe-slot=tpm2)
        else
            echo "== Enrolling $d (asks for the volume passphrase)"
        fi
        sudo systemd-cryptenroll "${enroll_args[@]}" "$d" || { failed=1; continue; }
        if [ -n "$root_uuid" ] && [ "${uuid_of[$d]}" = "$root_uuid" ]; then root_done=1; fi
    done
    if [ "$failed" = 1 ]; then echo "Some devices failed; the passphrase still works for all of them." >&2; fi
    if [ "$root_done" = 1 ]; then
        echo "Reboot to test it. If the root volume still asks for the passphrase, the initramfs may lack tpm2-tss:"
        echo "  sudo rpm-ostree initramfs --enable --arg=--force-add --arg=tpm2-tss"
    fi
    if [ "$action" = enroll ]; then
        if [ "$pcrs" = 7 ]; then echo "Passphrases are untouched. The key stops working when the Secure Boot state changes; run this again to re-enroll."
        else echo "Passphrases are untouched. The key stops working when the Secure Boot state or the MOK keys change (mokutil --import or --delete); run this again to re-enroll."; fi
    fi
    exit "$failed"

# Detect the fan and temperature chip of this board and load its driver at boot (--help for usage)
[group('System')]
[positional-arguments]
sensors-setup *args:
    #!/usr/bin/env bash
    set -uo pipefail
    menu_lib="${OCTARINE_MENU_LIB:-/usr/share/octarine-os/lib/menu.sh}"
    # shellcheck source=/dev/null
    if [ -r "$menu_lib" ]; then . "$menu_lib"; fi
    if ! declare -F menu_confirm >/dev/null; then menu_confirm() { return 1; }; fi
    mode=ask
    for a in "$@"; do
        case "$a" in
            help | --help | -h) printf '%s\n' 'Make the fan, pump and temperature chip of this board visible to Linux. `ujust sensors-setup [--yes|--no]`. Some boards (many ASUS and other desktop boards) hide their fan headers until the kernel module of the Super I/O chip is loaded; the module depends on the chip (nct6775, it87, ...), so the image does not load any by default. This recipe runs `sensors-detect --auto` from lm_sensors (uses sudo once, YubiKey touch; sensors-detect also writes /etc/sysconfig/lm_sensors and /etc/modprobe.d/lm_sensors.conf and enables lm_sensors.service, which is how Fedora packages it), reads the modules it found, writes them to /etc/modules-load.d/octarine-sensors.conf, loads them now and shows the `sensors` fan and temperature lines. --yes asks nothing (a different existing file is replaced after a timestamped backup, and the older hand-made nct6775.conf is replaced too); --no only shows the plan and the current state and changes nothing. The setting lives in /etc and the driver ships with the kernel, so it survives image updates: do NOT re-run it after an update, only after a hardware change (new board or chip). Some boards also need the kernel argument acpi_enforce_resources=lax; this recipe does not set it.'; exit 0 ;;
            --yes) mode=yes ;;
            --no) mode=no ;;
            *) echo "Unknown argument: $a (use --yes, --no or --help)" >&2; exit 1 ;;
        esac
    done
    sysconfig=${OCTARINE_SENSORS_SYSCONFIG:-/etc/sysconfig/lm_sensors}
    dir=${OCTARINE_MODULES_LOAD_DIR:-/etc/modules-load.d}
    target="$dir/octarine-sensors.conf"
    legacy="$dir/nct6775.conf"
    if ! command -v sensors-detect >/dev/null 2>&1; then
        echo "sensors-detect is not installed (package lm_sensors, part of the image's optional packages); nothing changed." >&2
        exit 1
    fi
    echo "Plan: run 'sudo sensors-detect --auto', write the modules it finds to $target, load them with modprobe, show the sensors."
    [ -e "$target" ] && echo "Existing: $target"
    [ -e "$legacy" ] && echo "Existing (older hand-made name): $legacy"
    if [ "$mode" = no ]; then echo "(--no: nothing was run or changed)"; exit 0; fi
    if [ "$mode" = ask ]; then
        menu_confirm "Probe the hardware with sensors-detect --auto and write the module list?" n || { echo "Left as it is."; exit 0; }
    fi
    echo "== Step with sudo (YubiKey touch; not retried): sensors-detect --auto"
    if ! sudo -v; then
        echo "sudo failed. Run it yourself, then re-run this recipe: sudo sensors-detect --auto" >&2
        exit 1
    fi
    detect_out=$(sudo sensors-detect --auto 2>&1)
    detect_rc=$?
    if [ "$detect_rc" -ne 0 ]; then
        printf '%s\n' "$detect_out" | tail -n 15 >&2
        echo "sensors-detect failed (exit $detect_rc). Nothing was written. Re-run: sudo sensors-detect --auto" >&2
        exit 1
    fi
    if printf '%s\n' "$detect_out" | grep -qE 'no sensors were detected|No modules to load'; then
        echo "No sensor chip needs a driver on this machine; nothing written. (If your fan headers are still missing, the chip may be unsupported or need acpi_enforce_resources=lax, which this recipe does not set.)"
        exit 0
    fi
    mods=()
    if [ -r "$sysconfig" ]; then
        for var in BUS_MODULES HWMON_MODULES; do
            val=$(sed -n "s/^${var}=\"\\(.*\\)\"[[:space:]]*\$/\\1/p" "$sysconfig" | tail -n 1)
            for m in $val; do
                case "$m" in
                    *[!A-Za-z0-9_-]* | "") echo "Ignoring an odd module name in $sysconfig: $m" >&2 ;;
                    *) case " ${mods[*]:-} " in *" $m "*) ;; *) mods+=("$m") ;; esac ;;
                esac
            done
        done
    fi
    if [ "${#mods[@]}" -eq 0 ]; then
        echo "sensors-detect found chips but listed no module to load (their drivers load by themselves); nothing written."
        exit 0
    fi
    echo "Modules to load: ${mods[*]}"
    new=$(mktemp)
    trap 'rm -f -- "$new"' EXIT
    {
        echo "# Written by 'ujust sensors-setup' (sensors-detect --auto): drivers for this board's fan and temperature chips."
        echo "# Undo: sudo rm $target ; then 'sudo modprobe -r <module>' or reboot."
        printf '%s\n' "${mods[@]}"
    } >"$new"
    failed=0
    ts=$(date +%Y%m%d-%H%M%S)
    if [ -e "$target" ] && cmp -s "$new" "$target"; then
        echo "Already done: $target has exactly this content."
    else
        replace=1
        if [ -e "$target" ]; then
            echo "== $target exists and differs:"
            diff -u "$target" "$new" || true
            if [ "$mode" = ask ]; then menu_confirm "Replace it (a backup is kept)?" n || { replace=0; echo "Kept the existing file."; }; fi
        fi
        if [ "$replace" = 1 ]; then
            if [ -e "$target" ]; then
                sudo cp -p "$target" "$target.bak-$ts" || failed=1
                echo "Backup: $target.bak-$ts"
            fi
            if sudo tee "$target" <"$new" >/dev/null; then echo "Wrote $target"; else echo "Could not write $target. Run: sudo tee $target" >&2; failed=1; fi
        fi
    fi
    if [ -e "$legacy" ]; then
        echo "Note: the older hand-made file $legacy exists; it loads modules too."
        doit=0
        if [ "$mode" = yes ]; then doit=1; elif menu_confirm "Replace $legacy with octarine-sensors.conf (a backup is kept)?" n; then doit=1; fi
        if [ "$doit" = 1 ]; then
            if sudo mv "$legacy" "$legacy.bak-$ts"; then echo "Moved $legacy to $legacy.bak-$ts (undo: sudo mv it back)"; else failed=1; fi
        else
            echo "Kept $legacy."
        fi
    fi
    for m in "${mods[@]}"; do
        if sudo modprobe "$m"; then echo "Loaded $m"; else echo "Could not load $m (try: sudo modprobe $m)" >&2; failed=1; fi
    done
    echo "== Fan and temperature lines from sensors:"
    if command -v sensors >/dev/null 2>&1; then
        sensors 2>/dev/null | grep -Ei '^[A-Za-z0-9_-]+-(isa|pci|virtual|acpi|i2c)|fan[0-9]*:|pump|temp[0-9]*:|^[A-Za-z]+ *[0-9]*:.*°C' || echo "(sensors printed no fan or temperature lines)"
    else
        echo "(sensors is not installed)"
    fi
    echo
    echo "This persists across image updates (a file in /etc, the driver comes with the kernel): no need to re-run after an update, only after a hardware change."
    echo "If some fan headers are still missing, some boards also need the kernel argument acpi_enforce_resources=lax; this recipe does not set it."
    echo "Undo: sudo rm $target ; sudo modprobe -r ${mods[*]} ; sudo systemctl disable --now lm_sensors.service (sensors-detect enabled it)"
    exit "$failed"

# Vendor and hardware setup: a checklist of steps, each shown only when this machine has the hardware (--help)
[group('Setup')]
[positional-arguments]
hardware-setup *args:
    #!/usr/bin/env bash
    set -uo pipefail
    menu_lib="${OCTARINE_MENU_LIB:-/usr/share/octarine-os/lib/menu.sh}"
    # shellcheck source=/dev/null
    if [ -r "$menu_lib" ]; then . "$menu_lib"; fi
    if ! declare -F menu_ready >/dev/null; then menu_ready() { return 1; }; menu_ready_one() { return 1; }; menu_tty() { return 1; }; menu_title() { printf '%s\n' "$1"; }; menu_confirm() { return 1; }; menu_multi() { return 3; }; fi
    ujust_cmd=${OCTARINE_UJUST:-ujust}
    drm=${OCTARINE_SYSFS_DRM:-/sys/class/drm}
    valid_steps=" sensors amd-gpu amd-kargs amd-cpu-gaming rocm rocm-export nvidia cuda cuda-export secure-boot tpm-luks fido-key iommu wake-on-lan "
    mode=ask
    list=0
    only_list=""
    export_flag=""
    args=("$@")
    i=0
    while [ "$i" -lt "${#args[@]}" ]; do
        a=${args[$i]}
        case "$a" in
            help | --help | -h) printf '%s\n' 'Vendor and hardware specific setup, one checklist. `ujust hardware-setup [--yes|--no|--list] [--only STEP[,STEP...]]`. Every step detects its hardware and is hidden when the machine does not have it. Steps: sensors (fan and temperature chip driver; runs ujust sensors-setup), amd-gpu (the LACT Flatpak and its daemon lactd for AMD GPUs), amd-kargs (optional: the kernel argument amdgpu.ppfeaturemask that unlocks overclocking in LACT; not shipped by default; needs sudo and a reboot), amd-cpu-gaming (GameMode tuning for amd-pstate; runs ujust gaming-setup gamemode), rocm (AMD GPU compute tools in a rootless distrobox; runs ujust toolbox rocm) and rocm-export, nvidia (switch to the NVIDIA image; runs ujust switch-image), cuda (CUDA toolbox; runs ujust dev --only cuda, dx image) and cuda-export, secure-boot (enroll the image key; runs ujust enroll-secure-boot-key), tpm-luks (TPM2 auto-unlock; runs ujust luks-tpm-unlock), fido-key (register a security key for sudo and polkit through pam_u2f; needs a touch), iommu (kernel arguments iommu=pt, plus intel_iommu=on on Intel, for device passthrough; optional; runs ujust virthost-setup --only iommu, dx image; sudo, reboot), wake-on-lan (Wake-on-LAN for the wired NIC; runs ujust wake-on-lan). The standalone recipes stay as they are; this menu only calls them. --list shows every step as available, done or not applicable with the reason. --only names steps (a step that does not apply prints "not applicable" and exits 0). --yes runs every available step that is ticked by default (never the optional ones, and never one that is already done), --no only prints the plan. Steps that use sudo or a hardware touch say so and are never retried. ROCm and CUDA boxes export nothing by default: --export also runs the export steps (rocm-export: hipcc, rocminfo, rocm-smi; cuda-export: nvcc) with distrobox-export into ~/.local/bin, resolving each real path inside the box and never overwriting a file that is not an export of that box; --unexport removes only those wrappers. Undo of an export: ujust hardware-setup --only rocm-export --unexport (or distrobox-export --bin PATH --export-path ~/.local/bin --unexport), and distrobox rm --force rocm or cuda for the box itself. Wrappers start the container on first use and cover only what is exported; entering the box (distrobox enter rocm -- rocminfo, distrobox enter cuda -- nvcc ...) always works without them. The rocm step installs the ROCm tools from Fedora in a rootless distrobox (nothing on the host); whether that build supports your GPU, for example RDNA4 gfx1201, is not verified.'; exit 0 ;;
            --yes) mode=yes ;;
            --no) mode=no ;;
            --list) list=1 ;;
            --export) export_flag=export ;;
            --unexport) export_flag=unexport ;;
            --only)
                i=$((i + 1))
                only_list=${args[$i]:-}
                [ -n "$only_list" ] || { echo "--only needs a step list" >&2; exit 2; }
                ;;
            --only=*) only_list=${a#--only=} ;;
            -*) echo "Unknown option: $a (use --yes, --no, --list, --export, --unexport or --only STEP[,STEP...])" >&2; exit 2 ;;
            *) echo "Unexpected argument: $a (steps are given with --only STEP[,STEP...])" >&2; exit 2 ;;
        esac
        i=$((i + 1))
    done
    if [ -n "$only_list" ]; then
        for s in ${only_list//,/ }; do
            case "$valid_steps" in *" $s "*) ;; *) echo "Unknown step: $s (steps:${valid_steps% })" >&2; exit 2 ;; esac
        done
    fi

    image_id=$(sed -n 's/^IMAGE_ID="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "${OCTARINE_OS_RELEASE:-/etc/os-release}" 2>/dev/null | head -n1)
    has_vendor() { # hex id
        local v
        for v in "$drm"/card*/device/vendor; do
            [ -r "$v" ] && [ "$(cat "$v" 2>/dev/null)" = "$1" ] && return 0
        done
        return 1
    }
    box_exists() { distrobox list 2>/dev/null | awk -F'|' -v b="$1" 'NR > 1 { x = $2; gsub(/ /, "", x); if (x == b) f = 1 } END { exit !f }'; }
    amdgpu_mod=${HW_AMDGPU_MODULE:-/sys/module/amdgpu}
    nvidia_mod=${HW_NVIDIA_MODULE:-/sys/module/nvidia}
    pstate=${GAMING_SETUP_PSTATE_STATUS:-/sys/devices/system/cpu/amd_pstate/status}
    tpm_dev=${OCTARINE_TPM_DEVICE:-/dev/tpmrm0}
    efi_dir=${HW_EFI:-/sys/firmware/efi}
    sb_key=${HW_SB_KEY:-/etc/pki/akmods/certs/akmods-ublue.der}
    dev_just=${HW_DEV_JUST:-/usr/share/ublue-os/just/70-octarine-dev.just}
    kvm_dev=${HW_KVM:-/dev/kvm}
    kfd_dev=${HW_KFD:-/dev/kfd}
    export_dir=${HW_EXPORT_DIR:-$HOME/.local/bin}
    rocm_bins=(hipcc rocminfo rocm-smi)
    cuda_bins=(nvcc)
    modload_dir=${OCTARINE_MODULES_LOAD_DIR:-/etc/modules-load.d}
    u2f_file=${HW_U2F_KEYS:-${XDG_CONFIG_HOME:-$HOME/.config}/Yubico/u2f_keys}
    lact_app=io.github.ilya_zlobintsev.LACT
    ppfm_param=${HW_PPFEATUREMASK:-/sys/module/amdgpu/parameters/ppfeaturemask}
    cmdline_file=${HW_CMDLINE:-/proc/cmdline}
    gm_ini="${XDG_CONFIG_HOME:-$HOME/.config}/gamemode.ini"

    step_ids=(sensors amd-gpu amd-kargs amd-cpu-gaming rocm rocm-export nvidia cuda cuda-export secure-boot tpm-luks fido-key iommu wake-on-lan)
    declare -A text=(
        [sensors]="Fan and temperature chip driver (sensors-detect; sudo)"
        [amd-gpu]="AMD GPU: LACT Flatpak and its daemon lactd"
        [amd-kargs]="AMD GPU: kernel argument amdgpu.ppfeaturemask for overclocking (optional; sudo, reboot)"
        [amd-cpu-gaming]="AMD CPU: GameMode tuning for amd-pstate"
        [rocm]="AMD GPU: ROCm compute tools in a rootless distrobox"
        [rocm-export]="ROCm: export hipcc, rocminfo and rocm-smi to ~/.local/bin (optional)"
        [nvidia]="NVIDIA: switch to the NVIDIA image"
        [cuda]="NVIDIA: CUDA toolkit in a rootless distrobox"
        [cuda-export]="CUDA: export nvcc to ~/.local/bin (optional)"
        [secure-boot]="Secure Boot: enroll the image key"
        [tpm-luks]="TPM2 auto-unlock for LUKS volumes (sudo)"
        [fido-key]="Security key: register it for sudo and polkit (touch)"
        [iommu]="Passthrough: kernel argument iommu=pt (optional; sudo, reboot)"
        [wake-on-lan]="Wake-on-LAN for the wired NIC (sudo)"
    )

    # Wake-on-LAN helpers: the physical NIC (the port when the default route is a bridge), its capability, the active profile
    wol_nic() {
        local n port
        n=$(ip -o route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
        if [ -n "$n" ] && [ -d "${WOL_NET_DIR:-/sys/class/net}/$n/bridge" ]; then port=$(ls "${WOL_NET_DIR:-/sys/class/net}/$n/brif" 2>/dev/null | head -n1); [ -n "$port" ] && n=$port; fi
        echo "$n"
    }
    wol_capable() {
        local n eo; n=$(wol_nic); [ -n "$n" ] || return 1
        if command -v ethtool >/dev/null 2>&1 && eo=$(ethtool "$n" 2>/dev/null) && [ -n "$eo" ]; then grep -E 'Supports Wake-on:' <<<"$eo" | grep -q g; return; fi
        [ -e "${WOL_NET_DIR:-/sys/class/net}/$n/device/power/wakeup" ]
    }
    wol_profile() { nmcli -g GENERAL.CONNECTION device show "$(wol_nic)" 2>/dev/null; }

    # reason_of <step>: prints why the step does not apply (nothing when it does)
    reason_of() {
        case "$1" in
            sensors)
                if systemd-detect-virt --quiet 2>/dev/null; then echo "this is a virtual machine"
                elif ! command -v sensors-detect >/dev/null 2>&1; then echo "sensors-detect (lm_sensors) is not installed"; fi ;;
            amd-gpu | amd-kargs)
                if ! has_vendor 0x1002; then echo "no AMD GPU"
                elif [ ! -d "$amdgpu_mod" ]; then echo "the amdgpu driver is not loaded"; fi ;;
            amd-cpu-gaming) [ "$(cat "$pstate" 2>/dev/null)" = active ] || echo "amd-pstate is not in active mode" ;;
            rocm | rocm-export)
                if ! has_vendor 0x1002; then echo "no AMD GPU"
                elif [ ! -e "$kfd_dev" ]; then echo "no /dev/kfd (the amdgpu compute interface)"
                elif ! command -v distrobox >/dev/null 2>&1; then echo "distrobox is not installed"
                elif [ "$1" = rocm-export ] && ! box_exists rocm; then echo "the rocm box does not exist yet"; fi ;;
            nvidia) has_vendor 0x10de || echo "no NVIDIA GPU" ;;
            cuda)
                if [ ! -d "$nvidia_mod" ]; then echo "the NVIDIA driver is not loaded"
                elif [ ! -f "$dev_just" ]; then echo "needs the dx image (ujust dev)"; fi ;;
            cuda-export) box_exists cuda || echo "the cuda box does not exist yet" ;;
            secure-boot)
                if [ ! -d "$efi_dir" ]; then echo "not booted with UEFI"
                elif ! command -v mokutil >/dev/null 2>&1; then echo "mokutil is not installed"
                elif ! mokutil --sb-state 2>/dev/null | grep -qi 'enabled'; then echo "Secure Boot is not enabled"
                elif [ ! -f "$sb_key" ]; then echo "the image key $sb_key is not present"; fi ;;
            tpm-luks)
                if [ ! -e "$tpm_dev" ]; then echo "no TPM 2.0 device"
                elif ! lsblk -rno FSTYPE 2>/dev/null | grep -qx crypto_LUKS; then echo "no LUKS volume"; fi ;;
            fido-key)
                if ! command -v pamu2fcfg >/dev/null 2>&1; then echo "pamu2fcfg (pam-u2f) is not installed"
                elif ! fido_present; then echo "no security key found"; fi ;;
            iommu)
                case "$image_id" in *-dx) ;; *) echo "needs the dx image (ujust virthost-setup)"; return ;; esac
                [ -n "$(ls -A "${HW_IOMMU_DIR:-/sys/class/iommu}" 2>/dev/null)" ] || echo "no IOMMU found (enable VT-d or AMD-Vi in the UEFI firmware)" ;;
            wake-on-lan)
                if ! wol_capable; then echo "no wired NIC that reports magic-packet wake"; fi ;;
        esac
    }
    fido_present() {
        local h
        if command -v lsusb >/dev/null 2>&1 && [ -n "$(lsusb -d 1050: 2>/dev/null)" ]; then return 0; fi
        for h in ${HW_HIDRAW_GLOB:-/dev/hidraw*}; do
            [ -e "$h" ] || continue
            udevadm info -q property -n "$h" 2>/dev/null | grep -qx 'ID_SECURITY_TOKEN=1' && return 0
        done
        return 1
    }
    # exports_done <box> <bin>...: every wrapper exists and is an export of that box
    exports_done() {
        local box=$1 b
        shift
        for b in "$@"; do
            grep -q '^# distrobox_binary' "$export_dir/$b" 2>/dev/null && grep -q "^# name: $box\$" "$export_dir/$b" 2>/dev/null || return 1
        done
    }
    # done_of <step>: already in place
    done_of() {
        case "$1" in
            sensors) [ -e "$modload_dir/octarine-sensors.conf" ] || [ -e "$modload_dir/nct6775.conf" ] ;;
            amd-gpu) [ "$(systemctl is-enabled lactd 2>/dev/null)" = enabled ] ;;
            amd-kargs) grep -q 'amdgpu.ppfeaturemask=' "$cmdline_file" 2>/dev/null || rpm-ostree kargs 2>/dev/null | grep -q 'amdgpu.ppfeaturemask=' ;;
            amd-cpu-gaming) grep -qs '^desiredgov=powersave' "$gm_ini" ;;
            rocm) box_exists rocm && distrobox enter rocm -- bash -lc 'command -v rocminfo' </dev/null >/dev/null 2>&1 ;;
            rocm-export) exports_done rocm "${rocm_bins[@]}" ;;
            cuda-export) exports_done cuda "${cuda_bins[@]}" ;;
            nvidia) [ -d "$nvidia_mod" ] ;;
            cuda) box_exists cuda ;;
            secure-boot) mokutil --test-key "$sb_key" 2>&1 | grep -qi 'already enrolled' ;;
            tpm-luks) return 1 ;;
            fido-key) [ -s "$u2f_file" ] ;;
            iommu) grep -qw 'iommu=pt' "$cmdline_file" 2>/dev/null || rpm-ostree kargs 2>/dev/null | grep -qw 'iommu=pt' ;;
            wake-on-lan) [ "$(nmcli -g 802-3-ethernet.wake-on-lan connection show "$(wol_profile)" 2>/dev/null | head -n1)" = magic ] ;;
        esac
    }
    default_of() { # 1 when ticked by default
        case "$1" in
            sensors | amd-gpu | amd-cpu-gaming | nvidia | tpm-luks | fido-key) echo 1 ;;
            iommu | wake-on-lan) echo 0 ;;
            rocm | rocm-export | cuda-export) echo 0 ;;
            secure-boot)
                case "$image_id" in *nvidia*) echo 1 ;; *) echo 0 ;; esac ;;
            *) echo 0 ;;
        esac
    }
    undo_of() {
        case "$1" in
            sensors) echo "sudo rm $modload_dir/octarine-sensors.conf; sudo systemctl disable --now lm_sensors.service" ;;
            amd-gpu) echo "flatpak uninstall $lact_app; sudo systemctl disable --now lactd" ;;
            amd-kargs) echo "sudo rpm-ostree kargs --delete-if-present=amdgpu.ppfeaturemask=<value> (the one shown) and reboot" ;;
            amd-cpu-gaming) echo "ujust gaming-setup reset" ;;
            rocm) echo "distrobox rm --force rocm (or ujust toolbox rocm --remove)" ;;
            rocm-export) echo "ujust hardware-setup --only rocm-export --unexport (or distrobox-export --bin <path> --export-path ~/.local/bin --unexport in the box, for each of ${rocm_bins[*]})" ;;
            cuda-export) echo "ujust hardware-setup --only cuda-export --unexport (or distrobox-export --bin <path> --export-path ~/.local/bin --unexport in the box, for ${cuda_bins[*]})" ;;
            nvidia) echo "sudo bootc rollback (or ujust switch-image default)" ;;
            cuda) echo "distrobox rm --force cuda" ;;
            secure-boot) echo "sudo mokutil --delete $sb_key" ;;
            tpm-luks) echo "ujust luks-tpm-unlock remove" ;;
            fido-key) echo "rm $u2f_file" ;;
            iommu) echo "sudo rpm-ostree kargs --delete-if-present=iommu=pt (and --delete-if-present=intel_iommu=on on Intel) and reboot" ;;
            wake-on-lan) echo "ujust wake-on-lan --off" ;;
        esac
    }
    ppfm_arg() { printf 'amdgpu.ppfeaturemask=0x%x' "$(($(cat "$ppfm_param") | 0x4000))"; }

    box_lib="${OCTARINE_BOX_EXPORT_LIB:-/usr/share/octarine-os/lib/box-export.sh}"
    # shellcheck source=/dev/null
    if [ -r "$box_lib" ]; then . "$box_lib"; else box_export() { echo "  FAILED: $box_lib is missing" >&2; return 1; }; fi
    run_export() { # box bins...  (honors --unexport)
        local box=$1
        shift
        if [ "$export_flag" = unexport ]; then box_export "$box" "$export_dir" unexport "$@"; else box_export "$box" "$export_dir" export "$@"; fi
    }
    retry() { "$@" || { echo "  failed; trying once more in 5 s" >&2; sleep "${HW_RETRY_WAIT:-5}"; "$@"; }; }
    # run_of <step>: do it; return code is the step's result (the called recipes keep their own messages)
    run_of() {
        local arg yes=()
        [ "$mode" = yes ] && yes=(--yes)
        case "$1" in
            sensors) "$ujust_cmd" sensors-setup "${yes[@]}" ;;
            amd-gpu)
                echo "Installs the verified LACT Flatpak from Flathub (system scope; polkit may ask for a touch), then asks it to set up its daemon lactd."
                retry flatpak install -y --system flathub "$lact_app" || return 1
                echo "Setting up lactd (LACT_UNATTENDED_SETUP=true; this unattended mode is taken from LACT's Flatpak notes and is not verified here)."
                if ! flatpak run --env=LACT_UNATTENDED_SETUP=true "$lact_app"; then
                    echo "The daemon setup did not finish. Open LACT once from the app grid and accept its offer to install the lactd service." >&2
                    return 1
                fi
                ;;
            amd-kargs)
                arg=$(ppfm_arg) || return 1
                echo "Run once with sudo (a touch; not retried): sudo rpm-ostree kargs --append-if-missing=$arg"
                sudo rpm-ostree kargs --append-if-missing="$arg" || return 1
                echo "Reboot to apply it. The argument is NOT shipped by default; it unlocks LACT's overclocking controls."
                ;;
            amd-cpu-gaming) "$ujust_cmd" gaming-setup gamemode "${yes[@]}" ;;
            rocm)
                echo "Creates a rootless distrobox named rocm from Fedora's toolbox image and installs the ROCm tools from Fedora's repositories inside it (large download). The GPU nodes are world-accessible through udev, so no group is needed. Whether this ROCm build supports your GPU (for example RDNA4 gfx1201) is not verified here."
                "$ujust_cmd" toolbox rocm || return 1
                echo "Check it:  distrobox enter rocm -- rocminfo   and   distrobox enter rocm -- rocm-smi"
                echo "Entering the box always works without exported commands; export them with: ujust hardware-setup --only rocm-export"
                ;;
            rocm-export) run_export rocm "${rocm_bins[@]}" ;;
            cuda-export) run_export cuda "${cuda_bins[@]}" ;;
            nvidia)
                case "$image_id" in *-dx) arg=nvidia-dx ;; *) arg=nvidia ;; esac
                "$ujust_cmd" switch-image "$arg" "${yes[@]}"
                ;;
            cuda) "$ujust_cmd" dev --only cuda "${yes[@]}" ;;
            secure-boot) "$ujust_cmd" enroll-secure-boot-key ;;
            tpm-luks) "$ujust_cmd" luks-tpm-unlock ;;
            fido-key)
                local dir tmp
                dir=$(dirname "$u2f_file")
                mkdir -p "$dir" || return 1
                tmp=$(mktemp "$dir/.u2f_keys.XXXXXX") || return 1
                echo "Touch your security key when it blinks."
                if pamu2fcfg -o pam://sudo -i pam://sudo >"$tmp" && [ -s "$tmp" ]; then
                    chmod 600 "$tmp"
                    mv -- "$tmp" "$u2f_file" || { rm -f "$tmp"; return 1; }
                    echo "Wrote $u2f_file. Check: sudo -k; sudo true (asks for the touch). A second key: see CONFIG-GUIDE.md."
                else
                    rm -f "$tmp"
                    echo "No key was registered (nothing written)." >&2
                    return 1
                fi
                ;;
            iommu) "$ujust_cmd" virthost-setup --only iommu "${yes[@]}" ;;
            wake-on-lan) "$ujust_cmd" wake-on-lan "${yes[@]}" ;;
        esac
    }

    avail=()
    declare -A why=() isdone=()
    for s in "${step_ids[@]}"; do
        why[$s]=$(reason_of "$s")
        if [ -z "${why[$s]}" ]; then
            avail+=("$s")
            if done_of "$s"; then isdone[$s]=1; else isdone[$s]=0; fi
        fi
    done
    state_of() { if [ -n "${why[$1]}" ]; then echo "not applicable (${why[$1]})"; elif [ "${isdone[$1]}" = 1 ]; then echo done; else echo available; fi; }

    if [ "$list" = 1 ]; then
        printf '%-16s %s\n' STEP STATE
        for s in "${step_ids[@]}"; do printf '%-16s %s\n' "$s" "$(state_of "$s")"; done
        exit 0
    fi

    names=()
    results=()
    undos=()
    failed=0
    record() { names+=("$1"); results+=("$2"); undos+=("${3:--}"); }

    chosen=()
    if [ -n "$only_list" ]; then
        for s in ${only_list//,/ }; do
            if [ -n "${why[$s]}" ]; then
                echo "not applicable: $s (${why[$s]})"
            else
                chosen+=("$s")
            fi
        done
        [ "${#chosen[@]}" -gt 0 ] || exit 0
    elif [ "${#avail[@]}" -eq 0 ]; then
        echo "No hardware-specific step applies to this machine."
        exit 0
    elif [ "$mode" = yes ]; then
        for s in "${avail[@]}"; do
            [ "${isdone[$s]}" = 1 ] && continue
            [ "$(default_of "$s")" = 1 ] && chosen+=("$s")
        done
    elif [ "$mode" = ask ] && menu_ready; then
        items=()
        for s in "${avail[@]}"; do
            sel=$(default_of "$s")
            label=${text[$s]}
            if [ "${isdone[$s]}" = 1 ]; then sel=0; label+=" (done)"; fi
            items+=("$s^$label^$sel")
        done
        menu_title "octarineOS hardware setup"
        menu_multi "Hardware setup: choose the steps (only what this machine has is listed)" "${items[@]}"
        if [ "${#MENU_RESULT[@]}" -eq 0 ]; then echo "Nothing selected; nothing changed. Run ujust hardware-setup --list to see the steps."; exit 0; fi
        chosen=("${MENU_RESULT[@]}")
        if ! menu_confirm "Run these steps: ${chosen[*]}?" y; then echo "Nothing changed."; exit 0; fi
    elif [ "$mode" = no ]; then
        chosen=("${avail[@]}")
    else
        # no terminal menu: ask one question per available step
        for s in "${avail[@]}"; do
            [ "${isdone[$s]}" = 1 ] && continue
            def=$(default_of "$s")
            hint="[y/N]"; [ "$def" = 1 ] && hint="[Y/n]"
            printf '%s %s ' "${text[$s]}?" "$hint"
            read -r reply || reply=""
            case "$reply" in [Yy]*) chosen+=("$s") ;; [Nn]*) ;; *) [ "$def" = 1 ] && chosen+=("$s") ;; esac
        done
    fi

    # --export adds the export step after rocm and cuda; --unexport turns them into their unexport steps
    if [ -n "$export_flag" ]; then
        expanded=()
        for s in "${chosen[@]}"; do
            case "$s:$export_flag" in
                rocm:export) expanded+=(rocm rocm-export) ;;
                cuda:export) expanded+=(cuda cuda-export) ;;
                rocm:unexport) expanded+=(rocm-export) ;;
                cuda:unexport) expanded+=(cuda-export) ;;
                *) expanded+=("$s") ;;
            esac
        done
        chosen=("${expanded[@]}")
    fi
    for s in "${chosen[@]}"; do
        echo
        echo "== $s: ${text[$s]}"
        if [ "$export_flag" = unexport ] && [[ "$s" == *-export ]]; then isdone[$s]=0; fi
        if [ "${isdone[$s]:-0}" = 1 ]; then
            echo "Already done."
            record "$s" "already done"
            continue
        fi
        if [ "$mode" = no ]; then
            echo "Plan: would run this step. Undo: $(undo_of "$s")"
            record "$s" planned
            continue
        fi
        if run_of "$s"; then
            record "$s" applied "$(undo_of "$s")"
        else
            echo "Failed: $s. Re-run: ujust hardware-setup --only $s" >&2
            failed=1
            record "$s" FAILED
        fi
    done
    if [ "${#names[@]}" -eq 0 ]; then echo "Nothing to do."; exit 0; fi
    echo
    echo "== Summary (mode: $mode)"
    printf '%-18s %s\n' STEP RESULT
    for k in "${!names[@]}"; do printf '%-18s %s\n' "${names[$k]}" "${results[$k]}"; done
    echo
    echo "To undo (per step):"
    for k in "${!names[@]}"; do [ "${undos[$k]}" != - ] && echo "  ${names[$k]}: ${undos[$k]}"; done
    exit "$failed"

# Choose a sched_ext CPU scheduler: at boot and while GameMode runs
[group('Setup')]
[positional-arguments]
scheduler *args:
    #!/usr/bin/env bash
    set -uo pipefail
    menu_lib="${OCTARINE_MENU_LIB:-/usr/share/octarine-os/lib/menu.sh}"
    # shellcheck source=/dev/null
    if [ -r "$menu_lib" ]; then . "$menu_lib"; fi
    if ! declare -F menu_ready_one >/dev/null; then menu_one() { return 3; }; menu_confirm() { return 1; }; menu_title() { printf '%s\n' "$1"; }; fi
    registry="${SCHEDULER_REGISTRY:-/usr/share/octarine-os/schedulers.d}"
    sysfs="${SCHEDULER_SYSFS:-/sys/kernel/sched_ext}"
    state_dir="${SCHEDULER_STATE_DIR:-/var/lib/octarine-os}"
    conf="${SCHEDULER_USER_CONF:-${XDG_CONFIG_HOME:-$HOME/.config}/octarine-os/scheduler.conf}"
    usage="Usage: ujust scheduler [--boot NAME|none] [--gamemode skip|none|NAME] [--restore] [--status] [--list] [--yes|--no] [-h|--help]"
    boot_want=""
    gm_want=""
    action=""
    mode=ask
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --boot) shift; if [ "$#" -eq 0 ]; then echo "--boot needs NAME or none" >&2; echo "$usage" >&2; exit 2; fi; boot_want=$1 ;;
            --boot=*) boot_want=${1#--boot=} ;;
            --gamemode) shift; if [ "$#" -eq 0 ]; then echo "--gamemode needs skip, none or NAME" >&2; echo "$usage" >&2; exit 2; fi; gm_want=$1 ;;
            --gamemode=*) gm_want=${1#--gamemode=} ;;
            --status) action=status ;;
            --restore) action=restore ;;
            --list) action=list ;;
            --yes) mode=yes ;;
            --no) mode=no ;;
            help | --help | -h) printf '%s\n' 'Choose the sched_ext CPU scheduler (BPF schedulers that replace the kernel'\''s default, EEVDF, while loaded). `ujust scheduler [--boot NAME|none] [--gamemode skip|none|NAME] [--restore] [--status] [--list] [--yes|--no]`. Everything ships off: no scheduler runs until you choose one. Step 1, at boot: none or one of the shipped schedulers; it is enabled as the system unit scx@NAME.service and started now (system setting, sudo once, a security-key touch; never retried, the exact command is printed when it fails). Step 2, while GameMode is active: skip (do not switch), none (the default scheduler during games) or a scheduler; stored in ~/.config/octarine-os/scheduler.conf as GAMEMODE_SCHED=..., no sudo; the GameMode hooks switch when a game starts and restore the boot choice when the last game ends (they need the GameMode file from `ujust gaming-setup gamemode`). Without options on a terminal both steps are asked, each option with its description. --status shows the sched_ext state, the active scheduler, the boot unit, the GameMode choice and any scheduler disabled after repeated load failures on this kernel; --list shows every shipped scheduler with its full description; --restore puts the machine back on the boot choice (start the enabled instance and stop any other one, or stop every running scheduler when none is enabled), for the case that gamemoded died during a game and the game-time scheduler stayed active; --no only prints the plan. NAME is the scheduler without the scx_ prefix (rusty, lavd, cake, bpfland, cosmos, flash, p2dq). Switching by hand needs no prompt: systemctl start scx@NAME.service. Undo: ujust scheduler --boot none --gamemode skip. Not applicable on a kernel without sched_ext. Whether a scheduler loads on your kernel and hardware is not verified in the image build: if one fails to load three times in a row it is disabled for that kernel (the marker is in /var/lib/octarine-os/scx-disabled) and the default scheduler stays.'; exit 0 ;;
            *) echo "Unknown option: $1" >&2; echo "$usage" >&2; exit 2 ;;
        esac
        shift
    done

    # the registry: one file per scheduler (instance name = file name without .conf)
    reg_get() { awk -v k="$2" 'index($0, k "=") == 1 { print substr($0, length(k) + 2); exit }' "$1"; }
    inst=()
    desc=()
    mink=()
    for f in "$registry"/*.conf; do
        [ -f "$f" ] || continue
        b=${f##*/}
        inst+=("${b%.conf}")
        desc+=("$(reg_get "$f" DESCRIPTION)")
        mink+=("$(reg_get "$f" MIN_KERNEL)")
    done
    if [ "${#inst[@]}" -eq 0 ]; then echo "No schedulers are registered in $registry (this image ships none)." >&2; exit 1; fi
    is_inst() { local x; for x in "${inst[@]}"; do [ "$x" = "$1" ] && return 0; done; return 1; }
    desc_of() { local k; for k in "${!inst[@]}"; do [ "${inst[$k]}" = "$1" ] && { printf '%s' "${desc[$k]}"; return; }; done; }
    short() { local t=$1 max=${2:-76}; if [ "${#t}" -gt "$max" ]; then t="${t:0:$((max - 1))}…"; fi; printf '%s' "$t"; }
    names_list="$(IFS=' '; echo "${inst[*]}")"

    if [ "$action" = list ]; then
        echo "Shipped schedulers (use the name on the left; --boot NAME, --gamemode NAME):"
        for k in "${!inst[@]}"; do
            printf '  %-9s scx_%-9s minimum kernel: %-4s %s\n' "${inst[$k]}" "${inst[$k]}" "${mink[$k]:-any}" "${desc[$k]}"
        done
        echo "  none      the kernel's default scheduler (EEVDF)"
        echo "  skip      (--gamemode only) do not switch when a game starts"
        exit 0
    fi
    if [ "$(id -u)" = 0 ]; then echo "Run this as your user, not as root: it writes your GameMode choice, and the boot step asks for sudo itself." >&2; exit 1; fi

    # validate names before anything else
    if [ -n "$boot_want" ] && [ "$boot_want" != none ] && ! is_inst "$boot_want"; then
        echo "Unknown scheduler for --boot: '$boot_want'. Known: none $names_list" >&2; exit 2
    fi
    if [ -n "$gm_want" ] && [ "$gm_want" != none ] && [ "$gm_want" != skip ] && ! is_inst "$gm_want"; then
        echo "Unknown choice for --gamemode: '$gm_want'. Known: skip none $names_list" >&2; exit 2
    fi

    if [ ! -d "$sysfs" ]; then
        echo "Not applicable: this kernel has no sched_ext ($sysfs is missing)."
        exit 0
    fi

    sched_state() { cat "$sysfs/state" 2>/dev/null || echo unknown; }
    active_sched() { local o; o=$(cat "$sysfs/root/ops" 2>/dev/null); if [ -n "$o" ] && is_inst "$o"; then echo "$o"; elif [ -n "$o" ]; then echo "$o (not one of ours)"; fi; }
    enabled_insts() { local i; for i in "${inst[@]}"; do [ "$(systemctl is-enabled "scx@$i.service" 2>/dev/null)" = enabled ] && echo "$i"; done; }
    gm_current() {
        local v=""
        if [ -r "$conf" ]; then v=$(awk -F= '$1 == "GAMEMODE_SCHED" { v = $2 } END { print v }' "$conf" | tr -d '[:space:]"'"'"); fi
        case "$v" in "" | skip) echo skip ;; none) echo none ;; *) if is_inst "$v"; then echo "$v"; else echo "skip"; fi ;; esac
    }

    if [ "$action" = status ]; then
        kern=$(uname -r)
        a=$(active_sched)
        e=$(enabled_insts | tr '\n' ' ')
        echo "sched_ext state:   $(sched_state)"
        a_txt=$a
        [ -n "$a_txt" ] || a_txt="none (the kernel default, EEVDF)"
        echo "active scheduler:  $a_txt"
        echo "boot choice:       ${e:-none} (the enabled scx@NAME.service)"
        echo "GameMode choice:   $(gm_current) ($conf)"
        dis=""
        for i in "${inst[@]}"; do
            m="$state_dir/scx-disabled/$i"
            if [ -f "$m" ]; then
                if [ "$(head -c 200 "$m")" = "$kern" ]; then dis="$dis $i (disabled for this kernel $kern after repeated load failures)"; else dis="$dis $i (marker for another kernel)"; fi
            fi
        done
        echo "disabled markers: ${dis:- none}"
        boot_first=$(enabled_insts | head -n1)
        a_inst=$(active_sched)
        if [ -n "$a_inst" ] && [ "$a_inst" != "$boot_first" ]; then
            echo "note: the running scheduler ($a_inst) differs from the boot choice (${boot_first:-none})."
            if command -v gamemoded >/dev/null 2>&1; then
                gms=$(timeout 2 gamemoded -s 2>&1 | head -n1)
                case "$gms" in
                    *"is active"* | *"are active"*) echo "      GameMode reports an active session: $gms" ;;
                    "") echo "      GameMode did not answer (gamemoded -s): the hint is skipped; run ujust scheduler --restore if no game is running." ;;
                    *) echo "      a game-time scheduler is active but no GameMode session is registered: run ujust scheduler --restore" ;;
                esac
            else
                echo "      GameMode state unknown (gamemoded -s is not available): if no game is running, run ujust scheduler --restore"
            fi
        fi
        exit 0
    fi

    if [ "$action" = restore ]; then
        boot_first=$(enabled_insts | head -n1)
        cmds=()
        if [ -n "$boot_first" ]; then
            if [ "$(active_sched)" != "$boot_first" ]; then cmds+=("systemctl start scx@$boot_first.service"); fi
            for i in "${inst[@]}"; do
                if [ "$i" != "$boot_first" ] && [ "$(systemctl is-active "scx@$i.service" 2>/dev/null)" = active ]; then cmds+=("systemctl stop scx@$i.service"); fi
            done
        else
            for i in "${inst[@]}"; do
                if [ "$(systemctl is-active "scx@$i.service" 2>/dev/null)" = active ]; then cmds+=("systemctl stop scx@$i.service"); fi
            done
            a=$(active_sched)
            if [ "${#cmds[@]}" -eq 0 ] && [ -n "$a" ] && is_inst "$a"; then cmds+=("systemctl stop scx@$a.service"); fi
        fi
        echo "== restore the boot choice (${boot_first:-none: the kernel default scheduler, EEVDF})"
        if [ "${#cmds[@]}" -eq 0 ]; then echo "Already consistent: nothing to do."; exit 0; fi
        printf '  %s\n' "${cmds[@]}"
        echo "Needs no prompt for the active wheel user (polkit rule); if that is refused the same command runs once through sudo (a security-key touch), never retried. Undo: ujust scheduler --gamemode NAME and start a game, or systemctl start scx@NAME.service"
        if [ "$mode" = no ]; then echo "Plan only."; exit 0; fi
        rc=0
        for c in "${cmds[@]}"; do
            if $c 2>/dev/null; then echo "Done: $c"; continue; fi
            echo "Refused without privileges; trying once through sudo: sudo $c"
            if ! sudo $c; then echo "Failed: sudo $c" >&2; echo "Run it yourself when ready." >&2; rc=1; break; fi
            echo "Done: sudo $c"
        done
        exit "$rc"
    fi

    boot_cur=$(enabled_insts | head -n1)
    gm_cur=$(gm_current)
    names=()
    results=()
    undos=()
    failed=0
    record() { names+=("$1"); results+=("$2"); undos+=("${3:--}"); }

    # interactive: ask both steps when nothing was named and this is a terminal
    if [ -z "$boot_want" ] && [ -z "$gm_want" ] && [ "$mode" = ask ]; then
        specs=()
        specs+=("none^$(short "None - the kernel's default scheduler (EEVDF)")")
        for k in "${!inst[@]}"; do specs+=("${inst[$k]}^$(short "${inst[$k]}: ${desc[$k]}")"); done
        # the current choice first (menu_one preselects the first item)
        ordered=()
        cur_id=${boot_cur:-none}
        for s in "${specs[@]}"; do [ "${s%%^*}" = "$cur_id" ] && ordered+=("$s"); done
        for s in "${specs[@]}"; do [ "${s%%^*}" = "$cur_id" ] || ordered+=("$s"); done
        menu_title "octarineOS scheduler"
        menu_one "Scheduler at boot (now: $cur_id; first entry = keep)" "${ordered[@]}"
        rc=$?
        if [ "$rc" -eq 3 ]; then
            echo "No terminal menu available: nothing changed. Name what you want:"
            echo "$usage"
            echo "Shipped: none $names_list (ujust scheduler --list shows the descriptions)"
            exit 0
        fi
        if [ "$rc" -eq 0 ]; then boot_want=$MENU_ONE; fi
        gspecs=()
        gspecs+=("skip^$(short "Skip - do not switch when a game starts")")
        gspecs+=("none^$(short "None - the kernel's default scheduler (EEVDF) during games")")
        for k in "${!inst[@]}"; do gspecs+=("${inst[$k]}^$(short "${inst[$k]}: ${desc[$k]}")"); done
        gordered=()
        for s in "${gspecs[@]}"; do [ "${s%%^*}" = "$gm_cur" ] && gordered+=("$s"); done
        for s in "${gspecs[@]}"; do [ "${s%%^*}" = "$gm_cur" ] || gordered+=("$s"); done
        menu_one "Scheduler while GameMode is active (now: $gm_cur; first entry = keep)" "${gordered[@]}"
        if [ $? -eq 0 ]; then gm_want=$MENU_ONE; fi
        if [ -z "$boot_want" ] && [ -z "$gm_want" ]; then echo "Nothing chosen; nothing changed."; exit 0; fi
        echo "Plan: boot ${boot_want:-unchanged}, GameMode ${gm_want:-unchanged}"
        if ! menu_confirm "Apply?" y; then echo "Nothing changed."; exit 0; fi
    elif [ -z "$boot_want" ] && [ -z "$gm_want" ]; then
        echo "Nothing to change. Now: boot ${boot_cur:-none}, GameMode $gm_cur. Name what you want:"
        echo "$usage"
        echo "Shipped: none $names_list (ujust scheduler --list shows the descriptions)"
        exit 0
    fi

    # step 1: the boot choice (system unit, sudo once)
    if [ -n "$boot_want" ]; then
        echo
        echo "== scheduler at boot"
        already=0
        if [ "$boot_want" = none ] && [ -z "$boot_cur" ]; then already=1; fi
        if [ "$boot_want" != none ] && [ "$boot_cur" = "$boot_want" ] && [ "$(enabled_insts | wc -l)" -eq 1 ]; then already=1; fi
        if [ "$already" = 1 ]; then
            echo "Already set: ${boot_want}."
            record "boot" "already done"
        else
            cmds=()
            for i in $(enabled_insts); do [ "$i" = "$boot_want" ] || cmds+=("sudo systemctl disable --now scx@$i.service"); done
            if [ "$boot_want" != none ]; then cmds+=("sudo systemctl enable --now scx@$boot_want.service"); fi
            echo "Sets $( [ "$boot_want" = none ] && echo 'the kernel default scheduler (EEVDF)' || echo "scx_$boot_want ($(short "$(desc_of "$boot_want")" 90))") at boot. System setting: uses sudo once (a security-key touch); never retried."
            for c in "${cmds[@]}"; do echo "  $c"; done
            if [ "$mode" = no ]; then
                record "boot" "plan only"
            else
                okc=1
                for c in "${cmds[@]}"; do
                    if ! $c; then okc=0; echo "Failed: $c" >&2; echo "Run the commands above yourself when ready." >&2; break; fi
                done
                if [ "$okc" = 1 ]; then
                    record "boot" applied "ujust scheduler --boot ${boot_cur:-none}"
                else
                    failed=1
                    record "boot" FAILED "run: ${cmds[*]}"
                fi
            fi
        fi
    fi

    # step 2: the GameMode choice (a user file, no sudo)
    if [ -n "$gm_want" ]; then
        echo
        echo "== scheduler while GameMode is active"
        if [ "$gm_want" = "$gm_cur" ] && [ -f "$conf" ]; then
            echo "Already set: ${gm_want}."
            record "gamemode" "already done"
        else
            echo "Writes GAMEMODE_SCHED=$gm_want to $conf (no sudo). The GameMode hooks read it when a game starts."
            if [ "$mode" = no ]; then
                record "gamemode" "plan only"
            else
                mkdir -p "$(dirname "$conf")" || true
                tmp=$(mktemp "$conf.XXXXXX" 2>/dev/null)
                if [ -n "$tmp" ]; then
                    if [ -f "$conf" ]; then grep -v '^GAMEMODE_SCHED=' "$conf" >"$tmp" || true; else
                        printf '%s\n' "# Written by ujust scheduler. GAMEMODE_SCHED=skip|none|<scheduler name> (see ujust scheduler --list); absent means skip." >"$tmp"
                    fi
                    printf 'GAMEMODE_SCHED=%s\n' "$gm_want" >>"$tmp"
                fi
                if [ -n "$tmp" ] && mv -f -- "$tmp" "$conf"; then
                    record "gamemode" applied "ujust scheduler --gamemode $gm_cur"
                else
                    rm -f -- "$tmp" 2>/dev/null
                    echo "Failed: could not write $conf" >&2
                    failed=1
                    record "gamemode" FAILED
                fi
            fi
        fi
    fi

    echo
    echo "== Summary"
    for k in "${!names[@]}"; do printf '  %-10s %s\n' "${names[$k]}" "${results[$k]}"; done
    echo "To undo:"
    for k in "${!names[@]}"; do [ "${undos[$k]}" != - ] && echo "  ${names[$k]}: ${undos[$k]}"; done
    exit "$failed"

# Turn on Wake-on-LAN (magic packet) for the wired NIC through NetworkManager
[group('Setup')]
[positional-arguments]
wake-on-lan *args:
    #!/usr/bin/env bash
    set -uo pipefail
    usage="Usage: ujust wake-on-lan [--yes|--no] [--status] [--off] [--nic IFACE] [-h]"
    mode=ask
    action=on
    nic_want=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --yes) mode=yes ;;
            --no) mode=no ;;
            --status) action=status ;;
            --off) action=off ;;
            --nic) shift; if [ "$#" -eq 0 ]; then echo "--nic needs an interface" >&2; exit 2; fi; nic_want=$1 ;;
            --nic=*) nic_want=${1#--nic=} ;;
            help | --help | -h) printf '%s\n' 'Wake-on-LAN for the wired NIC, set through NetworkManager so it persists: `ujust wake-on-lan [--yes|--no] [--status] [--off] [--nic IFACE]`. Finds the NIC with the default route (or --nic), reads whether it supports magic-packet wake (ethtool Wake-on contains g; without ethtool or without the right to read it, the sysfs power/wakeup file is used), takes the profile that is active on the PHYSICAL device (when the NIC is a bridge port that is the port profile, not the bridge), and runs `sudo nmcli connection modify "<profile>" 802-3-ethernet.wake-on-lan magic` and `sudo nmcli device reapply <iface>` (sudo, a security-key touch, never retried; the exact commands are printed when one fails). --off sets the value ignore. --status shows the setting and the MAC address. Undo: ujust wake-on-lan --off. This only configures the operating system: also enable Wake on LAN (often named Power On By PCI-E) in the BIOS or UEFI, and switch off ErP or EuP deep-sleep savings if the machine does not wake from a full shutdown (names vary). The real test is yours: shut down, then send a magic packet from another machine (wakeonlan MAC or etherwake MAC). Some drivers reset the setting at shutdown: not verified here. No tools are installed.'; exit 0 ;;
            *) echo "Unknown option: $1" >&2; echo "$usage" >&2; exit 2 ;;
        esac
        shift
    done
    if [ "$(id -u)" = 0 ]; then echo "Run this as your user, not as root: sudo is used for the one change." >&2; exit 1; fi
    net_dir="${WOL_NET_DIR:-/sys/class/net}"
    nic="$nic_want"
    if [ -z "$nic" ]; then nic=$(ip -o route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'); fi
    if [ -z "$nic" ]; then echo "No wired NIC found (no default route). Name one with --nic IFACE." >&2; exit 1; fi
    # a bridge is not the physical device: look for its port
    if [ -d "$net_dir/$nic/bridge" ]; then
        port=$(ls "$net_dir/$nic/brif" 2>/dev/null | head -n1)
        if [ -n "$port" ]; then echo "$nic is a bridge: the physical port is $port."; nic=$port; fi
    fi
    capable=0
    if command -v ethtool >/dev/null 2>&1 && eout=$(ethtool "$nic" 2>/dev/null) && [ -n "$eout" ]; then
        grep -E 'Supports Wake-on:' <<<"$eout" | grep -q 'g' && capable=1
    elif [ -e "$net_dir/$nic/device/power/wakeup" ]; then
        echo "(ethtool is missing or not readable as your user: using $net_dir/$nic/device/power/wakeup as the capability hint)"
        capable=1
    fi
    if [ "$capable" = 0 ]; then echo "$nic does not report magic-packet wake support: nothing to do." ; exit 0; fi
    prof=$(nmcli -g GENERAL.CONNECTION device show "$nic" 2>/dev/null)
    if [ -z "$prof" ] || [ "$prof" = "--" ]; then echo "No active NetworkManager profile on $nic." >&2; exit 1; fi
    cur=$(nmcli -g 802-3-ethernet.wake-on-lan connection show "$prof" 2>/dev/null | head -n1)
    mac=$(cat "$net_dir/$nic/address" 2>/dev/null)
    if [ "$action" = status ]; then
        echo "NIC $nic, profile '$prof', wake-on-lan setting: ${cur:-unknown}, MAC ${mac:-unknown}"
        exit 0
    fi
    want=magic; [ "$action" = off ] && want=ignore
    echo "NIC $nic (MAC ${mac:-unknown}), profile '$prof': wake-on-lan is '${cur:-unknown}', wanted '$want'."
    if [ "$cur" = "$want" ]; then echo "Already done."; exit 0; fi
    undo_val=ignore; [ "$action" = off ] && undo_val=magic
    echo "Undo: ujust wake-on-lan$([ "$action" = off ] || echo ' --off')"
    c1=(sudo nmcli connection modify "$prof" 802-3-ethernet.wake-on-lan "$want")
    c2=(sudo nmcli device reapply "$nic")
    echo "Commands (sudo, a security-key touch, never retried):"
    echo "  ${c1[*]}"
    echo "  ${c2[*]}"
    if [ "$mode" = no ]; then echo "Plan only."; exit 0; fi
    if [ "$mode" != yes ]; then
        menu_lib="${OCTARINE_MENU_LIB:-/usr/share/octarine-os/lib/menu.sh}"
        # shellcheck source=/dev/null
        if [ -r "$menu_lib" ]; then . "$menu_lib"; fi
        if ! declare -F menu_confirm >/dev/null || ! menu_confirm "Apply?" y; then echo "Nothing changed."; exit 0; fi
    fi
    if ! "${c1[@]}"; then echo "FAILED: ${c1[*]}" >&2; exit 1; fi
    if ! "${c2[@]}"; then echo "FAILED: ${c2[*]}" >&2; echo "The setting is saved in the profile; it applies at the next connection." >&2; exit 1; fi
    echo "Done. Check: nmcli -g 802-3-ethernet.wake-on-lan connection show '$prof'; ethtool $nic | grep Wake-on"
    if [ "$action" = on ]; then
        echo "Reminder: this is the operating-system side only. Enable Wake on LAN (Power On By PCI-E) in the BIOS or UEFI, and switch off ErP or EuP if the machine does not wake from a full shutdown."
        echo "Test it: shut down, then from another machine: wakeonlan ${mac:-<MAC>}  (or etherwake ${mac:-<MAC>})"
    fi
    exit 0

# Create and manage toolboxes (distrobox images with tools); no arguments opens a menu (--help for usage)
[group('Toolbox')]
[positional-arguments]
toolbox *args:
    #!/usr/bin/env bash
    set -euo pipefail
    menu_lib="${OCTARINE_MENU_LIB:-/usr/share/octarine-os/lib/menu.sh}"
    # shellcheck source=/dev/null
    if [ -r "$menu_lib" ]; then . "$menu_lib"; fi
    if ! declare -F menu_ready >/dev/null; then menu_ready() { return 1; }; menu_ready_one() { return 1; }; menu_tty() { return 1; }; menu_title() { printf '%s\n' "$1"; }; menu_confirm() { return 1; }; fi

    defs_dir="${TOOLBOX_DEFINITIONS:-/usr/share/ublue-os/distrobox}"
    image_override="${TOOLBOX_IMAGE:-}"
    conf_file="${UPM_CONF:-${XDG_CONFIG_HOME:-$HOME/.config}/distrobox/distrobox.conf}"
    brew_dir="${UPM_BREW_DIR:-/home/linuxbrew}"
    tty_in="${UPM_TTY:-/dev/tty}"
    export_dir="${UPM_EXPORT_DIR:-$HOME/.local/bin}"
    state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/ublue-os/toolbox"
    # Homes of toolboxes with ISOLATED_HOME=true live in <homes_dir>/<name>
    homes_dir="${TOOLBOX_HOMES_DIR:-$HOME/.local/share/toolbox-homes}"
    app_dir="${UPM_APPS_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/applications}"

    # Value of KEY in a sidecar file, read as data and never sourced. Values may only hold letters, digits,
    # space and . _ + - (a line with anything else is ignored with a warning).
    side_read() { # file, key
        local line v
        [ -r "$1" ] || return 0
        line=$({ grep -E "^[[:space:]]*$2=" "$1" || true; } | tail -n1)
        v=${line#*=}
        v=$(printf '%s' "$v" | tr -d "\"'")
        case "$v" in
            *[!A-Za-z0-9\ ._+-]*)
                echo "Ignoring $2 in $1: it holds characters other than letters, digits, space and . _ + -" >&2
                return 0
                ;;
        esac
        printf '%s\n' "$v"
    }

    conf_value() {
        [ -f "$conf_file" ] || return 0
        { grep -E '^[[:space:]]*container_name_default=' "$conf_file" || true; } | tail -1 | sed -E 's/^[^=]*=//' | tr -d "\"'"
    }

    # The toolbox name is the first word that is not an option (options take no values, except
    # --ide-custom, which ends the scan). The container is named like the toolbox.
    name=""
    for a in "$@"; do
        case "$a" in
            --ide-custom) break ;;
            -*) ;;
            *)
                name=$a
                break
                ;;
        esac
    done

    known_toolboxes() {
        local f
        for f in "$defs_dir"/*.ini; do
            [ -e "$f" ] || continue
            basename -- "$f" .ini
        done
    }

    # Image= line of a definition
    ini_image() { sed -n 's/^image=//p' "$1" 2>/dev/null | head -1 | tr -d "\"'"; }

    list_toolboxes() {
        local n st def listing img
        listing=""
        if command -v distrobox >/dev/null 2>&1; then listing=$(distrobox list 2>/dev/null || true); fi
        echo "Toolboxes defined in $defs_dir:"
        echo
        printf '%-12s %-9s %-8s %s\n' NAME BOX DEFAULT IMAGE
        while IFS= read -r n; do
            [ -n "$n" ] || continue
            st=missing
            if [ -n "$listing" ]; then
                st=$(awk -F'|' -v b="$n" 'NR > 1 { x = $2; gsub(/ /, "", x); if (x == b) { s = $3; gsub(/^ +| +$/, "", s); print (s ~ /^Up/) ? "running" : "stopped" } }' <<<"$listing")
                st=${st:-missing}
            elif ! command -v distrobox >/dev/null 2>&1; then
                st=unknown
            fi
            def=-
            if [ "$(conf_value)" = "$n" ]; then def=yes; fi
            img=$(ini_image "$defs_dir/$n.ini")
            printf '%-12s %-9s %-8s %s\n' "$n" "$st" "$def" "${img:-?}"
        done < <(known_toolboxes)
        local sf iso apps a ln hs st f
        while IFS= read -r n; do
            [ -n "$n" ] || continue
            sf="$defs_dir/$n.conf"
            iso=$(side_read "$sf" ISOLATED_HOME 2>/dev/null || true)
            apps=$(side_read "$sf" EXPORT_APPS 2>/dev/null || true)
            if [ "$iso" != true ] && [ -z "$apps" ]; then continue; fi
            if [ -z "${shown:-}" ]; then
                echo
                shown=1
            fi
            ln="  $n:"
            if [ "$iso" = true ]; then
                hs=missing
                if [ -d "$homes_dir/$n" ]; then hs=exists; fi
                ln+=" isolated home $homes_dir/$n ($hs);"
            fi
            for a in $apps; do
                f="$app_dir/$n-$a.desktop"
                st="not exported"
                if [ -e "$f" ] && grep -qxF -- "app $f" "$state_dir/$n" 2>/dev/null; then st=exported; fi
                ln+=" app $a ($st)"
            done
            echo "$ln"
        done < <(known_toolboxes)
        echo
        echo "Run: ujust toolbox <name>          create it and set it up"
        echo "     ujust toolbox <name> --list   tools, exports and state of one toolbox"
        echo "     ujust toolbox <name> --help   every option"
    }

    usage() {
        echo "Usage: ujust toolbox                       (list the toolboxes)"
        echo "       ujust toolbox <name> [--list] [--recreate] [--force] [tool ...]"
        echo "       ujust toolbox <name> --remove [--dry-run] [--purge-home]   (destroys the box and what this recipe recorded for it;"
        echo "                                                    an isolated home is kept unless --purge-home is given)"
        echo "       ujust toolbox <name> --upgrade [--check]    (pull the latest toolbox image and replace the box if it is newer)"
        echo "       ujust toolbox <name> --update               (package updates inside the existing box: distrobox upgrade)"
        echo "       ujust toolbox <name> --set-default          (make it the container_name_default of distrobox)"
        echo "       ujust toolbox <name> --ide [--list|--remove [--dry-run]] [ide ...]   (launchers that start an IDE inside the box)"
        echo "       ujust toolbox <name> --ide-custom NAME COMMAND [ICON]"
    }

    if [ -z "$name" ]; then
        for a in "$@"; do
            case "$a" in
                -h | --help)
                    usage
                    exit 0
                    ;;
                --list) ;;
                *)
                    echo "Give the name of a toolbox first: ujust toolbox <name> $a" >&2
                    echo >&2
                    list_toolboxes >&2
                    exit 2
                    ;;
            esac
        done
        list_toolboxes
        if [ "$#" -eq 0 ] && menu_ready_one; then
            specs=()
            while IFS= read -r n; do [ -n "$n" ] && specs+=("$n^$n"); done < <(known_toolboxes)
            if [ "${#specs[@]}" -gt 0 ] && menu_one "Choose a toolbox" "${specs[@]}"; then
                pick=$MENU_ONE
                if menu_one "What to do with $pick" "create^create or set up" "--list^show tools and state" "--recreate^recreate the box (home is kept)" \
                    "--upgrade^upgrade to the latest image" "--update^update packages inside the box" "--set-default^make it the default container" \
                    "--ide^create IDE launchers" "--remove^remove the box"; then
                    action=$MENU_ONE
                    if [ "$action" = create ]; then action=""; fi
                    if [ "$action" = --remove ]; then
                        menu_confirm "Remove $pick? (it asks you to type yes again)" n || exit 0
                    fi
                    exec ujust toolbox "$pick" $action
                fi
            fi
        fi
        exit 0
    fi

    # `dev` is the old name of dev-toolbox. If a state file of the old toolbox exists, `dev` still means that
    # old box, for --remove only (legacy=1); otherwise it is an alias for dev-toolbox.
    legacy=0
    src=$name
    if [ "$name" = dev ] && [ ! -r "$defs_dir/dev.ini" ]; then
        src=dev-toolbox
        if [ -f "$state_dir/dev" ]; then
            legacy=1
        else
            echo "Note: the toolbox 'dev' is now called dev-toolbox; using dev-toolbox."
            name=dev-toolbox
        fi
    fi
    if ! [[ "$name" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || [ ! -r "$defs_dir/$src.ini" ]; then
        echo "Unknown toolbox '$name'. Known toolboxes: $(known_toolboxes | tr '\n' ' ')" >&2
        exit 2
    fi
    box=$name
    def_file="$defs_dir/$src.ini"
    side_file="$defs_dir/$src.conf"
    state_file="$state_dir/$name"

    # The optional sidecar <name>.conf: plain KEY=value lines (see side_read)
    side_get() { side_read "$side_file" "$1"; }
    conf_tools=$(side_get TOOLS)
    conf_bins=$(side_get EXPORT_BINS)
    conf_ides=$(side_get IDES)
    # ISOLATED_HOME=true gives the container its own HOME; EXPORT_APPS lists apps whose launchers are exported
    conf_isohome=$(side_get ISOLATED_HOME)
    conf_apps=$(side_get EXPORT_APPS)
    isolated=0
    if [ "$conf_isohome" = true ]; then isolated=1; fi
    box_home="$homes_dir/$box"
    for t in $conf_apps; do
        if ! [[ "$t" =~ ^[A-Za-z0-9][A-Za-z0-9_.+-]*$ ]]; then
            echo "Invalid app name '$t' in EXPORT_APPS of $side_file" >&2
            exit 2
        fi
    done

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
    )

    # EXPORT_BINS of the sidecar becomes one group row: commands exported to the host when they exist in the box
    bin_exports=""
    bin_test=""
    for b in $conf_bins; do
        bin_exports+="cmd:$b "
        bin_test+="\${where[$b]:-}"
    done
    if [ -n "$conf_bins" ]; then
        rows+=("bins^Exported commands^group^^[ -n \"$bin_test\" ]^^^1^${bin_exports% }^")
    fi

    # TOOLS of the sidecar selects rows of the catalog above; without a sidecar a toolbox gets none
    tool_ids=()
    group_ids=()
    for r in "${rows[@]}"; do
        IFS='^' read -r id _ src _ <<<"$r"
        if [ "$src" = group ]; then
            group_ids+=("$id")
        elif [[ " $conf_tools " == *" $id "* ]]; then
            tool_ids+=("$id")
        fi
    done
    for t in $conf_tools; do
        if [[ " ${tool_ids[*]-} " != *" $t "* ]]; then echo "Ignoring unknown tool '$t' in $side_file" >&2; fi
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

    # A new conf record replaces this toolbox's older one
    drop_conf_records() {
        [ -f "$state_file" ] || return 0
        sed -i -e '/^conf /d' -e '/^conf-value /d' "$state_file"
    }

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

    # The image the box is made from: TOOLBOX_IMAGE, else the image= line of the definition
    def_image() {
        if [ -n "$image_override" ]; then
            printf '%s\n' "$image_override"
        else
            ini_image "$def_file"
        fi
    }

    undo_note() {
        [ -f "$state_file" ] || return 0
        echo
        echo "To undo: what this recipe created is listed in $state_file."
        echo "  - delete each 'export' path listed there (the files in $export_dir);"
        echo "  - 'conf' lines say how container_name_default in $conf_file was set (created, appended, or changed from an older value);"
        if [ "$isolated" = 1 ]; then
            echo "  - 'app' lines are launchers in $app_dir; 'home' lines the isolated home ($box_home), which --remove keeps;"
            echo "  - remove the box with: distrobox rm $box  (the isolated home stays)."
        else
            echo "  - remove the box with: distrobox rm $box  (your home is shared, so your files stay)."
        fi
    }

    list_all() {
        local t st ex cv f hs bs=missing
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
            echo "Brew mount:    missing (box made before the brew prefix existed; run --recreate)"
        fi
        if [ "$isolated" = 1 ]; then
            hs=missing
            if [ -d "$box_home" ]; then hs=exists; fi
            echo "Home:          $box_home ($hs, isolated; --remove keeps it)"
        fi
        if [ -n "$conf_apps" ]; then
            echo
            printf '%-10s %-13s %s\n' APP LAUNCHER PATH
            for t in $conf_apps; do
                f="$app_dir/$box-$t.desktop"
                if [ -e "$f" ]; then
                    if grep -qxF -- "app $f" "$state_file" 2>/dev/null; then st=exported; else st="foreign file"; fi
                else
                    st="not exported"
                fi
                printf '%-10s %-13s %s\n' "$t" "$st" "$f"
            done
        fi
        if [ "${#tool_ids[@]}" -gt 0 ] || [ "${#group_ids[@]}" -gt 0 ]; then echo; fi
        if [ "${#tool_ids[@]}" -gt 0 ] || [ "${#group_ids[@]}" -gt 0 ]; then printf '%-10s %-10s %-18s %-9s %s\n' TOOL STATE SOURCE EXPORTED LABEL; fi
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

    usage_lists() {
        usage
        echo "IDEs offered by $name: ${ide_ids[*]-none}"
        echo "Tools offered by $name: ${tool_ids[*]-none}"
        echo "With no tools named it shows a checklist (SPACE toggles, ENTER confirms, q skips)."
    }

    # IDE launchers (--ide): .desktop files that start an IDE inside the box. Detection only, nothing is installed.
    # One row per IDE, fields separated by ^ : id ^ name ^ kind (jetbrains or vscode) ^ launcher name ^ StartupWMClass ^ categories
    # jetbrains: the stable shell script JetBrains Toolbox generates (needs "Generate shell scripts" in the Toolbox settings,
    # default folder below); the icon is the name Toolbox registered in the user icon theme (jetbrains-<tool>-<uuid>), else the file in the bin/
    # directory of the app that script launches, so no versioned path or uuid is hardcoded.
    # vscode: a code found inside the box, or a tarball install under the home. The window classes are from memory, unverified.
    app_dir="${UPM_APPS_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/applications}"
    jb_scripts="${UPM_JB_SCRIPTS:-$HOME/.local/share/JetBrains/Toolbox/scripts}"
    jb_icons="${UPM_JB_ICONS:-${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/scalable/apps}"
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
    # IDES of the sidecar selects which launchers this toolbox offers (none without a sidecar)
    ide_ids=()
    for r in "${ide_rows[@]}"; do
        if [[ " $conf_ides " == *" ${r%%^*} "* ]]; then ide_ids+=("${r%%^*}"); fi
    done
    for t in $conf_ides; do
        if [[ " ${ide_ids[*]-} " != *" $t "* ]]; then echo "Ignoring unknown IDE '$t' in $side_file" >&2; fi
    done

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
        l=""
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
                # 1. the icon name Toolbox registered (jetbrains-<tool>-<uuid>.svg in the user hicolor theme): it follows
                #    Toolbox's own updates; the uuid is per install, so only the glob is written here. Newest file wins.
                for f in "$jb_icons"/jetbrains-"$icmd"-*.svg; do
                    if [ -f "$f" ] && { [ -z "$l" ] || [ "$f" -nt "$l" ]; }; then l=$f; fi
                done
                if [ -n "$l" ]; then
                    f=$(basename -- "$l")
                    idicon=${f%.svg}
                else
                    # 2. the file in the app's own bin/ directory: the script execs <apps>/<dir>/bin/<name> (the dir name can
                    #    differ from the script name, intellij-idea vs idea); else look in every <apps>/*/bin for <name>.svg
                    l=$(grep -oE '/[^" ]+/bin/[^" /]+' "$s" 2>/dev/null | head -1 || true)
                    for d in ${l:+"$(dirname -- "$l")"} "$(dirname -- "$jb_scripts")"/apps/*/bin; do
                        for f in "$d/$icmd.svg" "$d/$icmd.png"; do
                            if [ -f "$f" ]; then
                                idicon=$f
                                break 2
                            fi
                        done
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

    ide_file() { echo "$app_dir/$box-$1.desktop"; }

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
            printf 'Categories=%s\nX-Created-By=ujust toolbox\n' "${6:-Development;}"
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
                "$app_dir/$box"-*.desktop) ;;
                *) continue ;;
            esac
            c=${p##*/"$box"-}
            c=${c%.desktop}
            if [[ " ${ide_ids[*]} " != *" $c "* ]]; then printf '%-10s %-9s %-13s %s\n' "$c" "custom" "created" "$p"; fi
        done < <(sed -n 's/^launcher //p' "$state_file" 2>/dev/null)
        echo
        echo "Launchers run the IDE inside the box (distrobox enter -n $box -- ...). Remove them with: ujust toolbox $box --ide --remove"
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
    setdef=0
    purge=0
    named=0
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
                usage_lists
                exit 0
                ;;
            --force) force=1 ;;
            --recreate) recreate=1 ;;
            --remove) remove=1 ;;
            --dry-run) dry=1 ;;
            --upgrade) upgrade=1 ;;
            --check) check_only=1 ;;
            --set-default) setdef=1 ;;
            --purge-home) purge=1 ;;
            --update) update=1 ;;
            -*)
                echo "Unknown option $a" >&2
                usage >&2
                exit 2
                ;;
            *)
                # the first word is the toolbox name, the rest are tool or IDE names
                if [ "$named" = 0 ]; then named=1; else want+=("$a"); fi
                ;;
        esac
    done

    if [ "$ide" = 1 ] && [ "${#ide_ids[@]}" -eq 0 ]; then
        echo "The toolbox $name offers no IDE launchers (no IDES in $side_file)." >&2
        exit 1
    fi
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
    if [ "$purge" = 1 ] && [ "$remove" = 0 ]; then
        echo "--purge-home only goes with --remove" >&2
        exit 2
    fi
    if [ "$check_only" = 1 ] && [ "$upgrade" = 0 ]; then
        echo "--check only goes with --upgrade" >&2
        exit 2
    fi
    if [ "$ide" = 1 ]; then
        if [ $((upgrade + update + recreate + check_only + force + setdef)) -gt 0 ] || { [ "$remove" = 1 ] && [ "${#custom[@]}" -gt 0 ]; }; then
            echo "--ide only combines with --list, --remove, --dry-run and IDE names" >&2
            exit 2
        fi
    elif [ $((remove + upgrade + update + recreate + setdef)) -gt 1 ] || { [ $((remove + upgrade + update + setdef)) -gt 0 ] && [ "${#want[@]}" -gt 0 ]; }; then
        echo "--remove, --upgrade, --update, --set-default and --recreate cannot be combined with each other or with tool names" >&2
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
            echo "The box $box does not exist; create it first with: ujust toolbox $box" >&2
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

    # Isolated home: create the directory (no sudo) and say whether this recipe made it
    ensure_home() {
        local h=$box_home existed=0
        case "$h" in
            /*) ;;
            *)
                echo "   TOOLBOX_HOMES_DIR must be an absolute path (got $homes_dir)."
                return 1
                ;;
        esac
        case "$h" in
            *..* | *[!A-Za-z0-9/_.+@-]*)
                echo "   Refusing the home path $h: only letters, digits and / _ . + - @ are allowed, and no '..'."
                return 1
                ;;
        esac
        if [ -e "$h" ] || [ -L "$h" ]; then
            if [ ! -d "$h" ]; then
                echo "   $h exists but is not a directory; not continuing."
                return 1
            fi
            existed=1
        elif ! mkdir -p -- "$h" 2>/dev/null; then
            echo "   Could not create $h; not continuing."
            return 1
        fi
        if [ ! -w "$h" ]; then
            echo "   $h is not writable; not continuing."
            return 1
        fi
        if ! grep -q -- "^home $h " "$state_file" 2>/dev/null; then
            if [ "$existed" = 1 ]; then record "home $h existed"; else record "home $h created"; fi
        fi
        if [ "$existed" = 1 ]; then
            echo "   Isolated home: $h (already existed, kept as it is)"
        else
            echo "   Isolated home: $h (created)"
        fi
    }

    append_line() { # file, line
        if [ -s "$1" ] && [ -n "$(tail -c1 "$1")" ]; then printf '\n' >>"$1"; fi
        printf '%s\n' "$2" >>"$1"
    }

    # TOOLBOX_VOLUMES: space-separated src:dst[:opts] entries added as volume= lines. Absolute paths, an existing
    # source directory, no '..'; anything else is skipped and reported.
    add_volumes() { # definition file
        local v src dst opts extra
        for v in ${TOOLBOX_VOLUMES:-}; do
            IFS=: read -r src dst opts extra <<<"$v"
            if [ -n "$extra" ] || [ -z "$dst" ]; then
                echo "   Skipped volume '$v': use src:dst or src:dst:opts."
            elif [[ "$src$dst" == *..* ]] || [[ "$src$dst" == *[!A-Za-z0-9/_.+@-]* ]] || [[ "$src" != /* ]] || [[ "$dst" != /* ]] || [ "$dst" = / ]; then
                echo "   Skipped volume '$v': paths must be absolute, without '..' and only letters, digits and / _ . + - @."
            elif [ -n "$opts" ] && ! [[ "$opts" =~ ^[a-zA-Z,]+$ ]]; then
                echo "   Skipped volume '$v': invalid options '$opts'."
            elif [ ! -d "$src" ]; then
                echo "   Skipped volume '$v': $src is not an existing directory."
            else
                append_line "$1" "volume=\"$src:$dst${opts:+:$opts}\""
                echo "   Extra volume: $src -> $dst${opts:+ ($opts)}"
            fi
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
                    echo "   Run: ujust toolbox $box --recreate"
                fi
                return 0
            fi
            echo "== Recreating $box"
            if [ "$isolated" = 1 ]; then
                echo "   Its isolated home ($box_home) is kept; only the container's own filesystem"
                echo "   (packages installed inside it, anything outside that home) is replaced."
            else
                echo "   Your home is shared, so your files, ~/.cargo and caches survive; only the container's own"
                echo "   filesystem (packages installed inside it, anything outside your home) is replaced."
            fi
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
                while IFS= read -r p; do
                    case "$p" in
                        "$app_dir/$box"-*.desktop)
                            if [ -e "$p" ] || [ -L "$p" ]; then
                                rm -f -- "$p"
                                echo "   Removed old app launcher $p"
                            fi
                            ;;
                    esac
                done < <(sed -n 's/^app //p' "$state_file")
                sed -i '/^app /d' "$state_file"
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
        if ! grep -qx "\[$box\]" "$def_file"; then
            echo "   $def_file has no [$box] section, so the container would not be named $box."
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
            echo "   Once the prefix exists (the first-boot brew-setup.service creates it), run 'ujust toolbox $box --recreate' to add it."
        fi
        if [ "$isolated" = 1 ]; then
            ensure_home || {
                failed=1
                return 1
            }
            grep -v '^home=' "$tmpdef" >"$work/def.home" || true
            cat "$work/def.home" >"$tmpdef"
            append_line "$tmpdef" "home=$box_home"
        fi
        add_volumes "$tmpdef"
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

    # Step 2: offer to set the default container for `distrobox enter` (the container_name_default line of
    # distrobox.conf). Enter sets the toolbox's own name, another valid name sets that, a single dash leaves
    # the current value. Only that one line changes. Without answers to read (no terminal) nothing is changed
    # and the command to run later is printed.
    container_exists() {
        command -v distrobox >/dev/null 2>&1 &&
            distrobox list 2>/dev/null | awk -F'|' 'NR > 1 { gsub(/ /, "", $2); print $2 }' | grep -qx -- "$1"
    }
    # distrobox-enter reads container_name from distrobox.conf before container_name_default, so a
    # container_name= line there overrides the default. Comment such lines out (marked, and recorded in the
    # state file as 'conf-shadow <line>' so --remove can restore them).
    shadow_tag="# disabled by ujust toolbox: "
    disable_shadow() {
        local line tmp="$work/distrobox.shadow"
        [ -f "$conf_file" ] || return 0
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            awk -v t="$shadow_tag" '/^[[:space:]]*container_name=/ { print t $0; next } { print }' "$conf_file" >"$tmp"
            cat "$tmp" >"$conf_file"
            record "conf-shadow $line"
            echo "   Commented out '$line' in $conf_file: distrobox reads it before container_name_default."
        done < <(grep -E '^[[:space:]]*container_name=' "$conf_file" || true)
    }
    step_default() {
        local cur shown new line tmp
        cur=$(conf_value)
        if [ "$cur" = "$box" ]; then
            echo "== container_name_default is already $box (already set), nothing written"
            disable_shadow
            return 0
        fi
        shown=${cur:-none}
        if [ -n "$cur" ] && ! container_exists "$cur"; then shown="$cur, no such container"; fi
        echo "== Default container for 'distrobox enter' ($conf_file)"
        if menu_ready_one; then
            local specs=("$box^$box (this toolbox)" "-^Leave it as it is (${shown})")
            if menu_one "Default container for 'distrobox enter'" "${specs[@]}" && [ "$MENU_ONE" != "-" ]; then
                new=$MENU_ONE
            else
                echo "   Left as it was."
                return 0
            fi
        else
        while :; do
            printf "Default container for 'distrobox enter' (current: %s) [%s]: " "$shown" "$box"
            if ! IFS= read -r -u 3 line; then
                echo
                echo "   No terminal to read an answer from; the default is unchanged. To set it, run:"
                echo "   ujust toolbox $box --set-default"
                return 0
            fi
            case "$line" in
                "") new=$box ;;
                -)
                    echo "   Left as it was."
                    return 0
                    ;;
                *[!A-Za-z0-9_.-]*)
                    echo "   A container name may only use letters, digits, _, - and . ; try again."
                    continue
                    ;;
                *) new=$line ;;
            esac
            break
        done
        fi
        if [ "$new" = "$cur" ]; then
            echo "   $new is already set; nothing written."
            disable_shadow
            return 0
        fi
        mkdir -p -- "$(dirname -- "$conf_file")"
        if [ ! -f "$conf_file" ]; then
            printf 'container_name_default="%s"\n' "$new" >"$conf_file"
            drop_conf_records
            record "conf created"
        elif ! grep -qE '^[[:space:]]*container_name_default=' "$conf_file"; then
            if [ -s "$conf_file" ] && [ -n "$(tail -c1 "$conf_file")" ]; then printf '\n' >>"$conf_file"; fi
            printf 'container_name_default="%s"\n' "$new" >>"$conf_file"
            drop_conf_records
            record "conf appended"
        else
            tmp="$work/distrobox.conf"
            awk -v v="container_name_default=\"$new\"" '/^[[:space:]]*container_name_default=/ { print v; next } { print }' "$conf_file" >"$tmp"
            cat "$tmp" >"$conf_file"
            drop_conf_records
            record "conf changed $cur"
        fi
        if [ "$new" != "$box" ]; then record "conf-value $new"; fi
        disable_shadow
        echo "   distrobox enter now opens $new."
    }

    # dev-toolbox replaces the toolbox that used to be called dev: say how to remove the old container and state
    old_dev_note() {
        [ "$box" = dev-toolbox ] || return 0
        if [ -f "$state_dir/dev" ] || container_exists dev; then
            echo
            echo "An older toolbox named 'dev' is still around (it was renamed to dev-toolbox). To remove it:"
            if [ -f "$state_dir/dev" ]; then
                echo "  ujust toolbox dev --remove     (removes the container and what it recorded in $state_dir/dev)"
            else
                echo "  distrobox rm --force dev"
            fi
            echo "  Run it after checking that the exports in $export_dir now point at dev-toolbox (rerun this recipe if not)."
        fi
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

    # Export the launchers of EXPORT_APPS to the host (distrobox-export --app, run in the box). Never overwrites
    # a file this recipe did not create; every launcher it creates is recorded.
    do_apps() {
        local a dest already=0
        [ -n "$conf_apps" ] || return 0
        echo "== App launchers in $app_dir"
        mkdir -p -- "$app_dir"
        for a in $conf_apps; do
            dest="$app_dir/$box-$a.desktop"
            if [ -e "$dest" ] || [ -L "$dest" ]; then
                if grep -qxF -- "app $dest" "$state_file" 2>/dev/null; then
                    already=$((already + 1))
                else
                    echo "   Skipped $dest: a file is already there (not overwritten)."
                fi
                continue
            fi
            if ! distrobox enter "$box" -- distrobox-export --app "$a" </dev/null >/dev/null 2>&1 || [ ! -e "$dest" ]; then
                echo "   Could not export $a with distrobox-export (is it installed in the box?)."
                failed=1
                continue
            fi
            record "app $dest"
            echo "   Exported $dest"
        done
        if [ "$already" -gt 0 ]; then echo "   $already already exported."; fi
        refresh_apps
    }

    missing_package() {
        echo "   $label is not in the box. It comes with the toolbox image ($ref); the image is rebuilt weekly."
        echo "   Get the latest image and replace the box: ujust toolbox $box --upgrade"
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
            note_dirs rustup
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
                    # Remember that this toolbox uses the shared directory too, so removing another toolbox keeps it
                    note_dirs "$t"
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
        if menu_ready; then
            local specs=()
            for i in "${!tool_ids[@]}"; do
                if [ "${states[i]}" = missing ]; then
                    load "${tool_ids[i]}"
                    specs+=("${tool_ids[i]}^$label from $(if [ "$src" = image ]; then echo "image ($ref)"; else echo installer; fi)^${sel[i]}")
                fi
            done
            menu_multi "Tools to set up in the box" "${specs[@]}"
            want+=("${MENU_RESULT[@]}")
            if [ "${#MENU_RESULT[@]}" -eq 0 ]; then echo "Skipped the tool list."; fi
            return 0
        fi
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
    home_safe() { # absolute, no .., not / or $HOME, a real directory (no symlink) named like the box
        case "$1" in
            /*) ;;
            *) return 1 ;;
        esac
        case "$1" in
            *..*) return 1 ;;
        esac
        [ "$1" != / ] && [ "$1" != "$HOME" ] && [ ! -L "$1" ] && [ -d "$1" ] && [ "$(basename -- "$1")" = "$box" ]
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

    restore_shadow() { # put back the container_name= lines this recipe commented out
        local l orig tmp="$work/conf.shadow"
        [ -f "$state_file" ] || return 0
        while IFS= read -r l; do
            [ -n "$l" ] || continue
            orig=${l#conf-shadow }
            if [ -f "$conf_file" ]; then
                T="$shadow_tag" O="$orig" awk '$0 == ENVIRON["T"] ENVIRON["O"] { print ENVIRON["O"]; next } { print }' "$conf_file" >"$tmp"
                cat "$tmp" >"$conf_file"
            fi
            drop_state "$l"
            echo "Restored '$orig' in $conf_file"
        done < <(grep '^conf-shadow ' "$state_file" || true)
    }

    # Another toolbox whose state file lists this directory (a shared home directory such as ~/.cargo)
    other_owner() {
        local f
        for f in "$state_dir"/*; do
            [ -f "$f" ] || continue
            [ "$f" = "$state_file" ] && continue
            if grep -qF -- "dir $1 " "$f"; then
                basename -- "$f"
                return 0
            fi
        done
        return 0
    }

    # This toolbox created the directory but another one uses it: that one is the owner from now on, so
    # the last toolbox removed takes the directory with it
    hand_over() {
        local f
        for f in "$state_dir"/*; do
            [ -f "$f" ] || continue
            [ "$f" = "$state_file" ] && continue
            if grep -qxF -- "dir $1 existed" "$f"; then
                awk -v l="dir $1 existed" -v n="dir $1 created" '$0 == l { print n; next } { print }' "$f" >"$work/handover.new"
                cat "$work/handover.new" >"$f"
            fi
        done
    }

    do_remove() {
        local p kind rest cur wrote conf_line have_box=0 line other hline hp home_p="" home_kind="" purge_ok=0
        local exps=() dirs=() skipped=() lnch=() apps_l=() handover=()
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
                    "$app_dir/$box"-*.desktop) lnch+=("$p") ;;
                    *) skipped+=("$p (not a launcher path this recipe creates, left alone)") ;;
                esac
            fi
        done < <(sed -n 's/^launcher //p' "$state_file")
        while IFS= read -r p; do
            if [ -e "$p" ] || [ -L "$p" ]; then
                case "$p" in
                    "$app_dir/$box"-*.desktop) apps_l+=("$p") ;;
                    *) skipped+=("$p (not an app launcher path this recipe creates, left alone)") ;;
                esac
            fi
        done < <(sed -n 's/^app //p' "$state_file")
        hline=$(grep '^home ' "$state_file" | head -1 || true)
        if [ -n "$hline" ]; then
            hp=${hline#home }
            home_kind=${hp##* }
            hp=${hp% *}
            if [ -d "$hp" ]; then home_p=$hp; fi
        fi
        conf_line=$(grep -E '^conf (created|appended|changed)' "$state_file" | head -1 || true)
        if grep -qx "box $box" "$state_file" && box_exists; then have_box=1; fi
        while IFS= read -r line; do
            p=${line#dir }
            kind=${p##* }
            p=${p% *}
            if [ "$kind" = existed ]; then
                skipped+=("$p (already existed before this recipe, left alone)")
            elif [ -e "$p" ] && safe_dir "$p"; then
                other=$(other_owner "$p")
                if [ -n "$other" ]; then
                    skipped+=("$p (the toolbox $other also uses it, left alone; $other takes it over)")
                    handover+=("$p")
                else
                    dirs+=("$p")
                fi
            elif [ -e "$p" ]; then
                skipped+=("$p (not a safe path under your home, left alone)")
            fi
        done < <(grep '^dir ' "$state_file" || true)

        echo "This would remove, in this order:"
        for p in "${exps[@]}"; do echo "  export    $p  ($(size_of "$p"))"; done
        for p in "${lnch[@]}"; do echo "  launcher  $p  ($(size_of "$p"))"; done
        for p in "${apps_l[@]}"; do echo "  app       $p  ($(size_of "$p"))"; done
        if [ -n "$conf_line" ]; then
            cur=$(conf_value)
            wrote=$(grep '^conf-value ' "$state_file" | tail -1 | sed 's/^conf-value //' || true)
            if [ "$cur" = "${wrote:-$box}" ]; then
                echo "  setting   container_name_default in $conf_file (${conf_line#conf })"
            else
                skipped+=("container_name_default in $conf_file (now '$cur', not what this recipe wrote)")
                conf_line=""
            fi
        fi
        if grep -q '^conf-shadow ' "$state_file"; then
            echo "  restoring the container_name= line(s) in $conf_file that the recipe commented out"
        fi
        if [ "$have_box" = 1 ]; then echo "  container $box  (distrobox rm --force; size not shown)"; fi
        for p in "${dirs[@]}"; do echo "  directory $p  ($(size_of "$p"))"; done
        if [ -n "$home_p" ]; then
            if [ "$purge" = 1 ] && [ "$home_kind" = created ] && home_safe "$home_p"; then
                purge_ok=1
                echo "  home      $home_p  ($(size_of "$home_p"); isolated home, DELETED because of --purge-home)"
                echo "            It holds what the box keeps in its own home: the Steam library, Proton prefixes, saves, settings."
            elif [ "$purge" = 1 ]; then
                skipped+=("$home_p (the isolated home existed before this recipe or is not a safe path; delete it by hand if you want it gone)")
            else
                echo "  kept      $home_p  (isolated home; add --purge-home to delete it)"
            fi
        fi
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
        if [ "${#dirs[@]}" -gt 0 ]; then
            echo "Warning: ~/.cargo and ~/.sdkman can hold things you installed later (cargo install binaries,"
            echo "JDKs, Spark, Hadoop). They are lost with the directory."
        fi
        if [ "$purge_ok" = 1 ]; then
            echo "Warning: the isolated home cannot be recovered once deleted."
        fi
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
        for p in "${apps_l[@]}"; do
            rm -f -- "$p" || {
                echo "Could not remove $p; stopped. Run again to finish."
                return 1
            }
            drop_state "app $p"
            echo "Removed $p"
        done
        if [ "${#apps_l[@]}" -gt 0 ]; then refresh_apps; fi
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
        restore_shadow
        if [ "$have_box" = 1 ]; then
            distrobox rm --force "$box" </dev/null || {
                echo "Could not remove the container $box; stopped. Run again to finish."
                return 1
            }
            drop_state "box $box"
            drop_state "box-no-brew-mount"
            echo "Removed the container $box"
        fi
        for p in "${handover[@]}"; do
            hand_over "$p"
            drop_state "dir $p created"
        done
        for p in "${dirs[@]}"; do
            rm -rf -- "$p" || {
                echo "Could not remove $p; stopped. Run again to finish."
                return 1
            }
            drop_state "dir $p created"
            echo "Removed $p"
        done
        if [ "$purge_ok" = 1 ]; then
            rm -rf -- "$home_p" || {
                echo "Could not remove $home_p; stopped. Run again to finish."
                return 1
            }
            drop_state "home $home_p $home_kind"
            echo "Removed the isolated home $home_p"
        fi
        if [ -n "$home_p" ] && [ "$purge_ok" = 0 ] && [ "$home_kind" = created ]; then
            echo "The isolated home was kept: $home_p"
            echo "Delete it later with: ujust toolbox $box --remove --purge-home"
            grep '^home ' "$state_file" >"$work/state.home" || true
            cat "$work/state.home" >"$state_file"
            echo "Removed everything else; $state_file keeps only the home record. Done."
        else
            if [ -n "$home_p" ] && [ "$purge_ok" = 0 ]; then echo "The isolated home was kept: $home_p"; fi
            rm -f -- "$state_file"
            echo "Removed $state_file. Done."
        fi
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
            echo "No detected IDE still needs a launcher. 'ujust toolbox $box --ide --list' says why."
            return 0
        fi
        echo "IDE launchers (they start the IDE inside $box)"
        if menu_ready; then
            local specs=()
            for i in "${!ide_ids[@]}"; do
                if [ "${ist[i]}" = ready ]; then
                    ide_load "${ide_ids[i]}"
                    specs+=("${ide_ids[i]}^${iname}^${isel[i]}")
                fi
            done
            menu_multi "IDE launchers to create" "${specs[@]}"
            want+=("${MENU_RESULT[@]}")
            if [ "${#MENU_RESULT[@]}" -eq 0 ]; then echo "Skipped."; fi
            return 0
        fi
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

    # Re-detect the icon of a launcher this recipe created and rewrite its Icon= line when it differs. Never touches others.
    refresh_icon() { # file, ide id
        local f=$1 cur
        grep -qxF -- "launcher $f" "$state_file" 2>/dev/null || return 0
        if ! ide_detect "$2" || [ -z "$idicon" ]; then return 0; fi
        cur=$(sed -n 's/^Icon=//p' "$f" | head -1)
        if [ "$cur" = "$idicon" ]; then return 0; fi
        sed -i "s|^Icon=.*|Icon=${idicon//|/\\|}|" "$f"
        echo "   Refreshed the icon: ${cur:-none} -> $idicon"
    }

    install_ide() {
        local t=$1
        ide_load "$t"
        echo "== $iname"
        if [ -e "$(ide_file "$t")" ]; then
            make_launcher "$(ide_file "$t")" "$iname" "" "" "" ""
            refresh_icon "$(ide_file "$t")" "$t"
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
            echo "The box $box does not exist. Create it first with: ujust toolbox $box (this option never creates it)."
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
        echo "To undo: ujust toolbox $box --ide --remove (only launchers listed in $state_file are deleted)."
    }

    ide_remove() {
        local p t ok f files=()
        while IFS= read -r p; do
            case "$p" in
                "$app_dir/$box"-*.desktop) ;;
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

    if [ "$legacy" = 1 ] && [ "$remove" != 1 ]; then
        echo "The old toolbox 'dev' (state file $state_file) is now called dev-toolbox. Only" >&2
        echo "'ujust toolbox dev --remove' works on the old one; create the new one with: ujust toolbox dev-toolbox" >&2
        exit 2
    fi

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
            echo "The box $box does not exist; create it first with: ujust toolbox $box"
            return 1
        fi
        command -v podman >/dev/null 2>&1 || {
            echo "podman is not installed."
            return 1
        }
        image=$(def_image)
        if [ -z "$image" ]; then
            echo "No image= line in $def_file (and TOOLBOX_IMAGE is not set)."
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

    if [ "$setdef" = 1 ]; then
        step_default
        exit "$failed"
    fi

    if [ "$upgrade" = 1 ]; then
        do_upgrade || exit 1
        if [ "$recreate" = 0 ]; then exit 0; fi
    fi

    if [ "${#tool_ids[@]}" -gt 0 ]; then
        echo "Installers in the box are vendor scripts (SDKMAN, nvm). Each one is downloaded to a file, hashed and shown to you before it runs."
    fi
    step_box || {
        undo_note
        old_dev_note
        exit "$failed"
    }
    step_default
    resolve_all
    if [ "${#tool_ids[@]}" -gt 0 ] && [ "${#want[@]}" -eq 0 ] && [ "$no_checklist" = 0 ]; then checklist; fi
    for t in "${want[@]}"; do
        install_one "$t"
    done
    echo "== Exports to $export_dir"
    resolve_all
    for t in "${tool_ids[@]}" "${group_ids[@]}"; do
        if [ "$(state "$t")" = installed ]; then do_exports "$t"; fi
    done
    do_apps
    undo_note
    old_dev_note
    exit "$failed"
