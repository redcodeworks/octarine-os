# vim: set ft=make :

# Developer setup (dx image only): libvirt, Homebrew tools, VS Code, JetBrains, Rust, Java, Node, Python (--help)
[group('Developer')]
[positional-arguments]
dev *args:
    #!/usr/bin/env bash
    set -uo pipefail
    menu_lib="${OCTARINE_MENU_LIB:-/usr/share/octarine-os/lib/menu.sh}"
    # shellcheck source=/dev/null
    if [ -r "$menu_lib" ]; then . "$menu_lib"; fi
    if ! declare -F menu_ready >/dev/null; then menu_ready() { return 1; }; menu_ready_one() { return 1; }; menu_tty() { return 1; }; menu_title() { printf '%s\n' "$1"; }; menu_confirm() { return 1; }; fi
    mode=ask
    only_list=""
    valid_steps=" libvirt tools vscode jetbrains rust java node python "
    args=("$@")
    i=0
    while [ "$i" -lt "${#args[@]}" ]; do
        a=${args[$i]}
        case "$a" in
            help | --help | -h)
                cat <<'HELP'
    Developer setup for the octarineOS dx image, a checklist of steps. `ujust dev [--yes|--no] [--only STEP[,STEP...]]`.
    On a terminal, `ujust dev` alone opens a checklist; nothing runs that you did not tick.
    Steps, in order:
      libvirt    use the system libvirt: join the libvirt group (sudo, once; takes effect at your next login), default URI
                 qemu:///system in ~/.config/libvirt/libvirt.conf, the modular daemon sockets enabled, the default network
                 set to autostart
      tools      Homebrew developer tools, in groups you pick: Editor (helix), Python (ruff, ty, sqlfluff), Web (prettier,
                 typescript-language-server, vscode-langservers-extracted, yaml-language-server, marksman), Java (jdtls,
                 google-java-format), Lua (lua-language-server, stylua), TOML (taplo), SQL (sql-language-server), GitHub (gh)
      vscode     Visual Studio Code from Flathub (a community-maintained build, not verified on Flathub)
      jetbrains  the official Homebrew cask jetbrains-toolbox, plus a launcher and icon; replaces the older
                 jetbrains-toolbox-linux cask when installed (the Toolbox's own state in your home is kept)
      rust       rustup with the default profile (cargo, rustc, clippy, rustfmt, rust-docs) plus rust-analyzer and rust-src
      java       SDKMAN from the official Homebrew tap (candidates stay in ~/.sdkman/candidates), then Azul Zulu 8, 11, 17,
                 21 and 25 with 21 as the default
      node       fnm from Homebrew, the latest Node LTS as the default, and cached shell integration files
      python     uv-managed Python 3.12, 3.13 and 3.14 (never the system Python)
    --yes takes every default without asking (the libvirt step needs sudo, so it runs under --yes only when named with
    --only libvirt), --no only prints the plan, --only runs the named steps. Every step prints how to undo it. Existing
    files that differ are never replaced silently: you see a diff, the default is keep, and a replacement saves
    FILE.bak-YYYYMMDD-HHMMSS first. Network downloads are retried; a failed step is reported with its re-run command.
    HELP
                exit 0
                ;;
            --yes) mode=yes ;;
            --no) mode=no ;;
            --only)
                i=$((i + 1))
                only_list=${args[$i]:-}
                [ -n "$only_list" ] || { echo "--only needs a step list" >&2; exit 2; }
                ;;
            --only=*) only_list=${a#--only=} ;;
            -*) echo "Unknown option: $a (use --yes, --no or --only STEP[,STEP...])" >&2; exit 2 ;;
            *) echo "Unexpected argument: $a (steps are given with --only STEP[,STEP...])" >&2; exit 2 ;;
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
    if [ "$(id -u)" = 0 ]; then echo "Run this as your own user, not as root." >&2; exit 1; fi

    cfg="${XDG_CONFIG_HOME:-$HOME/.config}"
    data="${XDG_DATA_HOME:-$HOME/.local/share}"
    cache="${XDG_CACHE_HOME:-$HOME/.cache}"
    sdk_wrapper="${OCTARINE_SDK_WRAPPER:-/usr/bin/sdk}"
    work=$(mktemp -d)
    trap 'rm -rf -- "$work"' EXIT
    export HOMEBREW_NO_ENV_HINTS=1
    names=()
    results=()
    undos=()
    notes=()
    failed=0
    kept_any=0
    preconfirmed=0

    record() { names+=("$1"); results+=("$2"); undos+=("${3:--}"); }
    fail_step() { failed=1; record "$1" FAILED; }
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
    # gate <step> <undo-unused>: the "Apply?" question of a step that has work to do. Returns 0 to go on; otherwise it has
    # recorded planned or skipped.
    gate() {
        if [ "$mode" = no ]; then record "$1" "planned"; return 1; fi
        if [ "$preconfirmed" = 1 ]; then return 0; fi
        ask y "Apply?"
        if [ "$answer" != y ]; then record "$1" "skipped (not applied)"; return 1; fi
        return 0
    }
    # retry <command...>: up to three attempts for transient network failures (DEV_RETRIES, DEV_RETRY_WAIT seconds)
    retry() {
        local n=0 max=${DEV_RETRIES:-3}
        while :; do
            "$@" && return 0
            n=$((n + 1))
            [ "$n" -ge "$max" ] && return 1
            echo "  Failed (attempt $n of $max); retrying in ${DEV_RETRY_WAIT:-5} s ..." >&2
            sleep "${DEV_RETRY_WAIT:-5}"
        done
    }
    need_brew() {
        if command -v brew >/dev/null 2>&1; then return 0; fi
        echo "FAILED: Homebrew (brew) is not on PATH. Open a new login shell (the image puts brew on PATH) or check /home/linuxbrew/.linuxbrew." >&2
        fail_step "$1"
        return 1
    }
    brew_prefix() { brew --prefix 2>/dev/null || echo /home/linuxbrew/.linuxbrew; }
    formula_installed() { brew list --formula "$1" >/dev/null 2>&1; }
    cask_installed() { brew list --cask "$1" >/dev/null 2>&1; }
    in_session_group() { local g; for g in $(id -nG); do [ "$g" = "$1" ] && return 0; done; return 1; }

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
    # Fold the per-file results (file_results) of a step part into $fold: failed, applied, planned, kept or already.
    fold_results() {
        local r
        fold=already
        [ "${#file_results[@]}" -eq 0 ] && return
        for r in "${file_results[@]}"; do [ "$r" = failed ] && { fold=failed; return; }; done
        for r in "${file_results[@]}"; do [ "$r" = applied ] && { fold=applied; return; }; done
        for r in "${file_results[@]}"; do [ "$r" = planned ] && { fold=planned; return; }; done
        for r in "${file_results[@]}"; do [ "$r" = kept ] && { kept_any=1; fold=kept; return; }; done
    }
    # offer_rc_line <rc file> <line>: append one guarded source line to an rc file the user already has. Diff, backup,
    # default keep (so --yes never edits an rc file); a missing rc file is only mentioned.
    offer_rc_line() {
        local rc=$1 line=$2 backup n
        if [ ! -f "$rc" ]; then return 0; fi
        if grep -qF -- "$line" "$rc"; then echo "  $rc already has the line (already done)."; return 0; fi
        echo "  Appending this line to $rc:"
        if [ -s "$rc" ] && [ -n "$(tail -c1 "$rc")" ]; then
            diff -u "$rc" <(cat "$rc"; printf '\n%s\n' "$line") | sed 's/^/    /'
        else
            diff -u "$rc" <(cat "$rc"; printf '%s\n' "$line") | sed 's/^/    /'
        fi
        if [ "$mode" = no ]; then echo "  Plan: would ask before appending it (default keep; a timestamped backup is saved first)."; return 0; fi
        ask n "  Append it to $rc?"
        if [ "$answer" != y ]; then echo "  Kept $rc unchanged; add the line yourself when you want it."; return 0; fi
        backup="$rc.bak-$(date +%Y%m%d-%H%M%S)"
        n=0
        while [ -e "$backup" ]; do n=$((n + 1)); backup="$rc.bak-$(date +%Y%m%d-%H%M%S)-$n"; done
        if cp -p -- "$rc" "$backup"; then
            if [ -s "$rc" ] && [ -n "$(tail -c1 "$rc")" ]; then printf '\n' >>"$rc"; fi
            printf '%s\n' "$line" >>"$rc"
            echo "  Appended to $rc (backup: $backup)."
            rc_appended=1
        else
            echo "  Could not back up $rc; nothing appended." >&2
        fi
    }

    # ---- step: libvirt
    step_libvirt() {
        local user grp_ok=0 grp_cfg=0 s missing_socks=() root_cmds=() root_script="" net_out net_rc conf_src conf_state=new needs_work=0 sudo_ok=1 undo parts=()
        local etc_group="${DEV_ETC_GROUP:-/etc/group}" usr_group="${DEV_USR_GROUP:-/usr/lib/group}" conf="$cfg/libvirt/libvirt.conf"
        local net_xml="${DEV_LIBVIRT_NET_XML:-/usr/share/libvirt/networks/default.xml}"
        echo
        echo "== libvirt"
        echo "Uses the SYSTEM libvirt (qemu:///system): group libvirt for your user, the default URI in ${conf}, the modular daemon sockets (virtqemud, virtnetworkd, virtstoraged) enabled and the default network on autostart. The only sudo use of this recipe is one command here (a security-key touch); it is never retried."
        user=$(id -un)
        if ! [[ "$user" =~ ^[a-z_][a-z0-9_-]*$ ]]; then echo "  '$user' is not a plain user name; stopping." >&2; fail_step libvirt; return; fi
        in_session_group libvirt && grp_ok=1
        case ",$(getent group libvirt 2>/dev/null | cut -d: -f4)," in *",$user,"*) grp_cfg=1 ;; esac
        for s in virtqemud virtnetworkd virtstoraged; do
            systemctl is-enabled --quiet "$s.socket" 2>/dev/null || missing_socks+=("$s.socket")
        done
        if [ "$grp_cfg" = 0 ] && [ "$grp_ok" = 0 ]; then
            if ! grep -q '^libvirt:' "$etc_group" 2>/dev/null; then
                root_cmds+=("grep '^libvirt:' $usr_group >> $etc_group")
            fi
            root_cmds+=("usermod -aG libvirt $user")
        fi
        if [ "${#missing_socks[@]}" -gt 0 ]; then root_cmds+=("systemctl enable --now ${missing_socks[*]}"); fi
        conf_src="$work/libvirt.conf"
        printf '# octarineOS (ujust dev): use the system libvirt by default, so virsh and virt-manager see the same VMs.\nuri_default = "qemu:///system"\n' >"$conf_src"
        if [ -f "$conf" ] && grep -Eq '^[[:space:]]*uri_default[[:space:]]*=[[:space:]]*"qemu:///system"' "$conf"; then
            echo "  libvirt.conf: $conf already sets uri_default to qemu:///system (already done)."
            conf_state=already
        fi
        if [ "${#root_cmds[@]}" -gt 0 ] || [ "$conf_state" != already ]; then needs_work=1; fi
        if [ "$needs_work" = 1 ]; then
            if [ "${#root_cmds[@]}" -gt 0 ]; then
                root_script=$(printf '%s && ' "${root_cmds[@]}")
                root_script=${root_script% && }
                # under --yes the sudo command only runs when this step was named with --only
                if [ "$mode" = yes ]; then
                    case ",$only_list," in
                        *",libvirt,"*) ;;
                        *)
                            echo "  This step needs sudo, so --yes alone does not run it. Run: ujust dev --only libvirt --yes"
                            record libvirt "skipped (needs sudo; name it with --only libvirt)"
                            return
                            ;;
                    esac
                fi
                echo "  Needs root (one command):  sudo sh -c '$root_script'"
            fi
            if [ "$mode" = no ]; then
                [ "$conf_state" != already ] && { file_results=(); place libvirt.conf "$conf_src" "$conf"; }
                echo "  Plan: the root command above (when shown), the user file, then the default network check."
                record libvirt planned
                return
            fi
            gate libvirt || return
            if [ "${#root_cmds[@]}" -gt 0 ]; then
                if sudo sh -c "$root_script"; then
                    echo "  Done: ${root_cmds[*]}"
                    parts+=(applied)
                    if [ "$grp_cfg" = 0 ] && [ "$grp_ok" = 0 ]; then echo "  Log out and back in for the libvirt group to take effect."; fi
                else
                    echo "  FAILED: the sudo command did not succeed (it is not retried). Run it yourself:  sudo sh -c '$root_script'" >&2
                    parts+=(failed)
                    sudo_ok=0
                fi
            fi
            if [ "$conf_state" != already ]; then
                file_results=()
                place libvirt.conf "$conf_src" "$conf"
                file_results+=("$place_result")
                fold_results
                case "$fold" in failed) parts+=(failed) ;; applied) parts+=(applied) ;; kept) parts+=(kept) ;; esac
            fi
        fi
        # the default network, once the group is in effect (virsh talks to qemu:///system)
        if [ "$sudo_ok" = 1 ] && command -v virsh >/dev/null 2>&1; then
            if ! in_session_group libvirt; then
                notes+=("libvirt: log out and back in, then run 'ujust dev --only libvirt' again to check the default network")
                parts+=(pending)
            else
                net_out=$(virsh -c qemu:///system net-info default 2>&1); net_rc=$?
                if [ "$net_rc" = 0 ]; then
                    if grep -Eq '^Autostart:[[:space:]]+yes' <<<"$net_out"; then
                        echo "  default network: exists and autostarts (already done)."
                    elif [ "$mode" = no ]; then
                        echo "  Plan: virsh -c qemu:///system net-autostart default"
                        parts+=(planned)
                    elif virsh -c qemu:///system net-autostart default; then
                        echo "  default network: autostart switched on."
                        parts+=(applied)
                    else
                        echo "  FAILED: virsh -c qemu:///system net-autostart default" >&2
                        parts+=(failed)
                    fi
                elif grep -qi 'not found' <<<"$net_out" && [ -r "$net_xml" ]; then
                    if [ "$mode" = no ]; then
                        echo "  Plan: define the default network from $net_xml, autostart and start it."
                        parts+=(planned)
                    else
                        echo "  default network: missing; defining it from $net_xml."
                        if virsh -c qemu:///system net-define "$net_xml" && virsh -c qemu:///system net-autostart default && virsh -c qemu:///system net-start default; then
                            parts+=(applied)
                        else
                            echo "  FAILED: could not define, autostart and start the default network. Re-run: ujust dev --only libvirt" >&2
                            parts+=(failed)
                        fi
                    fi
                else
                    echo "  default network: could not be checked (${net_out%%$'\n'*})." >&2
                    notes+=("libvirt: the default network was not checked; run 'ujust dev --only libvirt' again once libvirtd answers")
                fi
            fi
        elif [ "$sudo_ok" = 1 ]; then
            echo "  virsh is not installed; the default network was not checked." >&2
        fi
        undo="sudo gpasswd -d $user libvirt; delete $conf; sudo systemctl disable --now virtqemud.socket virtnetworkd.socket virtstoraged.socket; virsh -c qemu:///system net-autostart --disable default"
        if [[ " ${parts[*]-} " == *" failed "* ]]; then fail_step libvirt
        elif [[ " ${parts[*]-} " == *" applied "* ]]; then record libvirt applied "$undo"
        elif [[ " ${parts[*]-} " == *" planned "* ]]; then record libvirt planned
        elif [[ " ${parts[*]-} " == *" pending "* ]]; then record libvirt "pending (log in again, then re-run)"
        elif [[ " ${parts[*]-} " == *" kept "* ]]; then record libvirt "skipped (kept your different file)"
        else record libvirt "already done"
        fi
    }

    # ---- step: tools
    tool_groups=(
        "editor^Editor^helix"
        "python^Python^ruff ty sqlfluff"
        "web^Web^prettier typescript-language-server vscode-langservers-extracted yaml-language-server marksman"
        "java^Java^jdtls google-java-format"
        "lua^Lua^lua-language-server stylua"
        "toml^TOML^taplo"
        "sql^SQL^sql-language-server"
        "github^GitHub^gh"
    )
    step_tools() {
        local g id label pkgs chosen=() todo=() p failed_pkgs=() done_pkgs=() items=() undo
        echo
        echo "== tools"
        echo "Installs Homebrew developer tools in groups: Editor (helix), Python (ruff, ty, sqlfluff), Web (prettier, typescript-language-server, vscode-langservers-extracted, yaml-language-server, marksman), Java (jdtls, google-java-format), Lua (lua-language-server, stylua), TOML (taplo), SQL (sql-language-server), GitHub (gh: installed only, no login). Debuggers are not added: gdb is part of the image and the IDEs bring their own."
        need_brew tools || return
        for g in "${tool_groups[@]}"; do
            IFS='^' read -r id label pkgs <<<"$g"
            items+=("$id^$label ($pkgs)^1")
        done
        if [ "$mode" = ask ]; then
            if menu_ready; then
                menu_multi "Tools: choose the groups to install with Homebrew" "${items[@]}"
                if [ "${#MENU_RESULT[@]}" -eq 0 ]; then echo "Nothing ticked; no tools installed."; record tools "skipped (nothing ticked)"; return; fi
                chosen=("${MENU_RESULT[@]}")
            else
                for g in "${tool_groups[@]}"; do
                    IFS='^' read -r id label pkgs <<<"$g"
                    ask y "Install $label ($pkgs)?"
                    [ "$answer" = y ] && chosen+=("$id")
                done
                if [ "${#chosen[@]}" -eq 0 ]; then record tools "skipped (nothing chosen)"; return; fi
            fi
        else
            for g in "${tool_groups[@]}"; do chosen+=("${g%%^*}"); done
        fi
        for g in "${tool_groups[@]}"; do
            IFS='^' read -r id label pkgs <<<"$g"
            case " ${chosen[*]} " in *" $id "*) ;; *) continue ;; esac
            for p in $pkgs; do
                if formula_installed "$p"; then echo "  $p: already installed."; else todo+=("$p"); fi
            done
        done
        if [ "${#todo[@]}" -eq 0 ]; then echo "  Everything chosen is already installed."; record tools "already done"; return; fi
        echo "  To install: ${todo[*]}"
        if [ "$mode" = no ]; then echo "  Plan: brew install each of them (retried on network failures)."; record tools planned; return; fi
        # a group picked in the checklist was confirmed there; plain prompts asked per group already
        for p in "${todo[@]}"; do
            echo "  brew install $p"
            if retry brew install "$p"; then done_pkgs+=("$p"); else echo "  FAILED: brew install $p" >&2; failed_pkgs+=("$p"); fi
        done
        undo="brew uninstall ${done_pkgs[*]-}"
        if [ "${#failed_pkgs[@]}" -gt 0 ]; then
            echo "  Not installed: ${failed_pkgs[*]}. Re-run: ujust dev --only tools (installed ones are skipped)" >&2
            failed=1
            if [ "${#done_pkgs[@]}" -gt 0 ]; then record tools "FAILED for ${failed_pkgs[*]} (others installed)" "$undo"; else record tools FAILED; fi
        else
            record tools applied "$undo"
        fi
    }

    # ---- step: vscode
    step_vscode() {
        local app=com.visualstudio.code
        echo
        echo "== vscode"
        echo "Installs Visual Studio Code from Flathub into your user Flatpak installation (flatpak install --user -y flathub $app). Note: this is a community-maintained build, not verified on Flathub (Microsoft is only listed as the developer)."
        if ! command -v flatpak >/dev/null 2>&1; then echo "FAILED: flatpak is not installed." >&2; fail_step vscode; return; fi
        if flatpak info "$app" >/dev/null 2>&1; then echo "  $app is already installed (already done)."; record vscode "already done"; return; fi
        if [ "$mode" = no ]; then echo "  Plan: add the flathub remote to your user installation when missing, then install $app."; record vscode planned; return; fi
        gate vscode || return
        flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo >/dev/null 2>&1
        if retry flatpak install --user -y flathub "$app"; then
            record vscode applied "flatpak uninstall $app (add --delete-data to remove its settings too)"
        else
            echo "FAILED: flatpak install $app. Re-run: ujust dev --only vscode" >&2
            fail_step vscode
        fi
    }

    # ---- step: jetbrains
    step_jetbrains() {
        local old=jetbrains-toolbox-linux cask=jetbrains-toolbox prefix desk icon_dir icon found="" f src undo replace=0 parts=() desk_src
        echo
        echo "== jetbrains"
        echo "Installs the OFFICIAL Homebrew cask $cask (not the older ublue tap cask $old) and writes a launcher and an icon in your home, because the cask only links the binary. The Toolbox updates itself (the cask is marked auto_updates), so brew upgrade does not touch it."
        need_brew jetbrains || return
        prefix=$(brew_prefix)
        desk="$data/applications/jetbrains-toolbox.desktop"
        icon_dir="$data/icons/hicolor/256x256/apps"
        icon="$icon_dir/jetbrains-toolbox.png"
        if cask_installed "$old"; then
            echo "  The older cask $old is installed. It is replaced by the official one (brew uninstall --cask $old, then install); the Toolbox state in your home (IDEs, settings) is kept."
            replace=1
        fi
        desk_src="$work/jetbrains-toolbox.desktop"
        cat >"$desk_src" <<DESK
    [Desktop Entry]
    Type=Application
    Name=JetBrains Toolbox
    Comment=Install and manage JetBrains IDEs
    Exec=$prefix/bin/jetbrains-toolbox %u
    Icon=jetbrains-toolbox
    Terminal=false
    Categories=Development;IDE;
    StartupWMClass=jetbrains-toolbox
    MimeType=x-scheme-handler/jetbrains;
    X-Octarine-Generated=ujust dev
    DESK
        if cask_installed "$cask" && [ "$replace" = 0 ] && [ -f "$desk" ] && cmp -s "$desk_src" "$desk" && [ -f "$icon" ]; then
            echo "  $cask, the launcher and the icon are in place (already done)."
            record jetbrains "already done"
            return
        fi
        if [ "$mode" = no ]; then
            [ "$replace" = 1 ] && echo "  Plan: brew uninstall --cask $old"
            cask_installed "$cask" || echo "  Plan: brew install --cask $cask"
            echo "  Plan: write $desk (Exec=$prefix/bin/jetbrains-toolbox %u) and copy the icon to $icon."
            record jetbrains planned
            return
        fi
        gate jetbrains || return
        if [ "$replace" = 1 ]; then
            if brew uninstall --cask "$old"; then echo "  Removed the cask $old."; else echo "FAILED: brew uninstall --cask $old" >&2; fail_step jetbrains; return; fi
        fi
        if ! cask_installed "$cask"; then
            if retry brew install --cask "$cask"; then parts+=(applied); else echo "FAILED: brew install --cask $cask. Re-run: ujust dev --only jetbrains" >&2; fail_step jetbrains; return; fi
        fi
        file_results=()
        place launcher "$desk_src" "$desk"
        file_results+=("$place_result")
        if [ -f "$desk" ] && command -v desktop-file-validate >/dev/null 2>&1; then
            if desktop-file-validate "$desk"; then echo "  desktop-file-validate: $desk is valid."; else echo "  Warning: desktop-file-validate reported problems with $desk" >&2; fi
        fi
        if [ -f "$icon" ]; then
            echo "  icon: $icon is already there (already done)."
            file_results+=(already)
        else
            # the cask unpacks the JetBrains tarball under the Caskroom; use a PNG from it when there is one
            for f in "$prefix"/Caskroom/"$cask"/*/*/*.png "$prefix"/Caskroom/"$cask"/*/*.png "$prefix"/Caskroom/"$cask"/*/*/*/*.png; do
                case "$(basename "$f")" in *toolbox*) [ -f "$f" ] && { found=$f; break; } ;; esac
            done
            if [ -n "$found" ] && mkdir -p -- "$icon_dir" && cp -- "$found" "$icon"; then
                echo "  icon: copied $found to $icon."
                file_results+=(applied)
            else
                echo "  icon: no toolbox PNG found in the cask; the launcher uses the generic icon (put a PNG at $icon to add one)."
                notes+=("jetbrains: no icon found in the cask; copy one to $icon")
            fi
        fi
        fold_results
        undo="brew uninstall --cask $cask; rm $desk $icon"
        case "$fold" in
            failed) fail_step jetbrains ;;
            kept) record jetbrains "skipped (kept your different launcher)" ;;
            *)
                if [ "$fold" = applied ] || [ "${#parts[@]}" -gt 0 ]; then record jetbrains applied "$undo"; else record jetbrains "already done"; fi
                ;;
        esac
    }

    # ---- step: rust
    step_rust() {
        local cargo_home="${CARGO_HOME:-$HOME/.cargo}" rustup_bin missing=() c installed_list undo parts=()
        rustup_bin="$cargo_home/bin/rustup"
        echo
        echo "== rust"
        echo "Sets up rustup in your home with the default profile (cargo, rustc, rust-std, rust-docs, rustfmt, clippy) and adds rust-analyzer and rust-src. rustup never edits your rc files here (--no-modify-path): the image puts ~/.cargo/bin on PATH for bash, zsh and fish when the directory exists."
        undo="rustup component remove rust-analyzer rust-src; to remove rustup itself: rustup self uninstall"
        if [ -x "$rustup_bin" ]; then
            echo "  rustup is already set up. Active toolchain: $("$rustup_bin" show active-toolchain 2>&1 | head -n1)"
        else
            if ! command -v rustup-init >/dev/null 2>&1; then echo "FAILED: rustup-init is not installed (it ships with the dx image)." >&2; fail_step rust; return; fi
            if [ "$mode" = no ]; then echo "  Plan: rustup-init -y --profile default --no-modify-path, then rustup component add rust-analyzer rust-src."; record rust planned; return; fi
            gate rust || return
            echo "  rustup-init -y --profile default --no-modify-path"
            if retry rustup-init -y --profile default --no-modify-path; then parts+=(applied); else echo "FAILED: rustup-init. Re-run: ujust dev --only rust" >&2; fail_step rust; return; fi
        fi
        installed_list=$("$rustup_bin" component list --installed 2>/dev/null)
        for c in rust-analyzer rust-src; do
            grep -q "^$c" <<<"$installed_list" || missing+=("$c")
        done
        if [ "${#missing[@]}" -eq 0 ]; then
            echo "  rust-analyzer and rust-src are installed."
            if [ "${#parts[@]}" -gt 0 ]; then record rust applied "$undo"; else record rust "already done"; fi
            return
        fi
        if [ "$mode" = no ]; then echo "  Plan: rustup component add ${missing[*]}"; record rust planned; return; fi
        if [ "${#parts[@]}" -eq 0 ]; then gate rust || return; fi
        echo "  rustup component add ${missing[*]}"
        if retry "$rustup_bin" component add "${missing[@]}"; then
            record rust applied "$undo"
        else
            echo "FAILED: rustup component add ${missing[*]}. Is a toolchain installed? Try: rustup default stable, then ujust dev --only rust" >&2
            fail_step rust
        fi
    }

    # ---- step: java (SDKMAN from the official Homebrew tap, Azul Zulu LTS)
    sdk_install_java() { printf 'n\n' | "$sdk_wrapper" install java "$1"; }
    step_java() {
        local home_init="$HOME/.sdkman/bin/sdkman-init.sh" tap=sdkman/tap/sdkman-cli major id listing ids todo=() installed_ids done_ids=() failed_ids=() parts=() cur default_id undo have_sdkman=0 java_dir="$HOME/.sdkman/candidates/java" cur_ok=0
        echo
        echo "== java"
        echo "Sets up SDKMAN and installs Azul Zulu for the LTS majors 8, 11, 17, 21 and 25, with 21 as the default. SDKMAN comes from the official Homebrew tap formula ($tap); the JDKs live in ~/.sdkman/candidates (a symlink keeps them out of the Homebrew keg, so a brew upgrade cannot lose them) and the formula is pinned (unpin with: brew unpin $tap)."
        undo="sdk uninstall java <version> for each JDK; brew unpin $tap; brew uninstall $tap (the JDKs in ~/.sdkman/candidates stay until you delete that directory)"
        if [ ! -x "$sdk_wrapper" ]; then echo "FAILED: the sdk wrapper $sdk_wrapper is missing (it ships with the dx image)." >&2; fail_step java; return; fi
        if [ -r "$home_init" ]; then
            echo "  SDKMAN is already installed (script install in ~/.sdkman); nothing to install, and it is not migrated."
            have_sdkman=1
        elif command -v brew >/dev/null 2>&1 && formula_installed sdkman-cli; then
            echo "  SDKMAN is already installed (Homebrew tap formula)."
            have_sdkman=1
        fi
        installed_ids=$(ls "$java_dir" 2>/dev/null)
        cur=$(basename "$(readlink "$java_dir/current" 2>/dev/null)" 2>/dev/null)
        grep -Eq '^21[.+-].*-zulu$' <<<"$cur" && cur_ok=1
        for major in 8 11 17 21 25; do
            grep -Eq "^${major}[.+-].*-zulu\$" <<<"$installed_ids" && echo "  Zulu $major: already installed ($(grep -E "^${major}[.+-].*-zulu\$" <<<"$installed_ids" | sort -V | tail -n1))." || todo+=("$major")
        done
        if [ "$have_sdkman" = 1 ] && [ "${#todo[@]}" -eq 0 ] && [ "$cur_ok" = 1 ]; then
            echo "  All Zulu LTS versions are installed and 21 is the default (already done)."
            record java "already done"
            return
        fi
        if [ "$mode" = no ]; then
            [ "$have_sdkman" = 0 ] && echo "  Plan: brew install $tap and brew pin $tap"
            echo "  Plan: link the candidates, then sdk install java for Zulu ${todo[*]:-(none missing)} and set 21 as the default."
            record java planned
            return
        fi
        if [ "$have_sdkman" = 0 ]; then
            need_brew java || return
            gate java || return
            echo "  brew install $tap"
            if retry brew install "$tap"; then
                parts+=(applied)
                if brew pin "$tap"; then echo "  Pinned $tap (brew upgrade skips it; unpin with: brew unpin $tap)."; else echo "  Warning: brew pin $tap failed; a brew upgrade could replace the keg." >&2; fi
            else
                echo "FAILED: brew install $tap (network?). Re-run: ujust dev --only java" >&2
                fail_step java
                return
            fi
        else
            gate java || return
            if command -v brew >/dev/null 2>&1 && formula_installed sdkman-cli && ! [ -r "$home_init" ] && [ -z "$(brew list --pinned 2>/dev/null | grep -x sdkman-cli)" ]; then
                brew pin "$tap" >/dev/null 2>&1 && echo "  Pinned $tap."
            fi
        fi
        # the candidates symlink (tap install) and the SDKMAN directory the wrapper picks
        if ! "$sdk_wrapper" --octarine-relink >"$work/relink.out" 2>"$work/relink.err"; then
            echo "FAILED: $(cat "$work/relink.err")" >&2
            fail_step java
            return
        fi
        if [ -s "$work/relink.err" ]; then sed 's/^/  /' "$work/relink.err" >&2; fi
        echo "  $(cat "$work/relink.out")"
        if [ "${#todo[@]}" -gt 0 ]; then
            listing=$(retry "$sdk_wrapper" list java 2>"$work/list.err" | sed $'s/\x1b\\[[0-9;]*[A-Za-z]//g')
            ids=$(awk -F'|' 'NF >= 6 { id = $NF; gsub(/[[:space:]]/, "", id); if (id ~ /^[0-9][0-9A-Za-z.+_]*-zulu$/ && id !~ /(crac|\.fx)/) print id }' <<<"$listing")
            if [ -z "$ids" ]; then
                echo "FAILED: could not read the Java list from SDKMAN (network? $(head -c 200 "$work/list.err" 2>/dev/null)). Re-run: ujust dev --only java" >&2
                fail_step java
                return
            fi
            for major in "${todo[@]}"; do
                id=$(grep -E "^${major}[.+-]" <<<"$ids" | sort -V | tail -n1)
                if [ -z "$id" ]; then echo "  Zulu $major: not listed by SDKMAN." >&2; failed_ids+=("zulu-$major"); continue; fi
                echo "  sdk install java $id"
                if retry sdk_install_java "$id"; then done_ids+=("$id"); else echo "  FAILED: sdk install java $id" >&2; failed_ids+=("$id"); fi
            done
        fi
        default_id=$(ls "$java_dir" 2>/dev/null | grep -E '^21[.+-].*-zulu$' | sort -V | tail -n1)
        if [ -z "$default_id" ]; then
            echo "  FAILED: no Zulu 21 to set as the default." >&2
            failed_ids+=("default")
        elif [ "$cur_ok" = 1 ]; then
            echo "  Default java is already $cur."
        elif "$sdk_wrapper" default java "$default_id"; then
            echo "  Default java: $default_id."
            done_ids+=("default")
        else
            echo "  FAILED: sdk default java $default_id" >&2
            failed_ids+=("default")
        fi
        if [ "${#failed_ids[@]}" -gt 0 ]; then
            echo "  Not done: ${failed_ids[*]}. Re-run: ujust dev --only java (finished versions are skipped)" >&2
            failed=1
            if [ "${#done_ids[@]}" -gt 0 ] || [ "${#parts[@]}" -gt 0 ]; then record java "FAILED for ${failed_ids[*]} (others done)" "$undo"; else record java FAILED; fi
        else
            record java applied "$undo"
        fi
    }

    # ---- step: node (fnm)
    step_node() {
        local fnm_bin="" fnm_have=0 default_ok=0 shsrc="$work/fnm.sh" fishsrc="$work/fnm.fish" dir="$cfg/octarine-os" parts=() undo offer=1 fold=already sh_line fish_line rc_appended=0
        echo
        echo "== node"
        echo "Installs fnm (Fast Node Manager, a single Rust binary from Homebrew), the latest Node LTS as the default (fnm install --lts, fnm default lts-latest) and two small shell files, $dir/fnm.sh (bash and zsh) and $dir/fnm.fish (fish), that cache the output of 'fnm env' so a shell starts in milliseconds. Your rc files are only changed if you say yes to one appended line each."
        undo="brew uninstall fnm; delete $dir/fnm.sh, $dir/fnm.fish and the cache $cache/octarine-os/shell/; remove the source line from your rc files; Node versions live in ~/.local/share/fnm"
        need_brew node || return
        cat >"$shsrc" <<'FNMSH'
    # octarineOS (ujust dev --only node): fnm shell integration for bash and zsh. The output of `fnm env` is cached and
    # regenerated only when the fnm binary is newer than the cache, so a shell start costs one file read. To turn it off,
    # remove the line that sources this file from your rc file.
    if command -v fnm >/dev/null 2>&1; then
        _oct_fnm_shell=bash
        [ -n "${ZSH_VERSION:-}" ] && _oct_fnm_shell=zsh
        _oct_fnm_cache="${XDG_CACHE_HOME:-$HOME/.cache}/octarine-os/shell/fnm.$_oct_fnm_shell"
        _oct_fnm_refresh() {
            mkdir -p "${_oct_fnm_cache%/*}" && fnm env --use-on-cd --shell "$_oct_fnm_shell" >"$_oct_fnm_cache.tmp" 2>/dev/null && mv -f "$_oct_fnm_cache.tmp" "$_oct_fnm_cache"
        }
        if [ ! -s "$_oct_fnm_cache" ] || [ "$(command -v fnm)" -nt "$_oct_fnm_cache" ]; then
            _oct_fnm_refresh
        fi
        [ -s "$_oct_fnm_cache" ] && . "$_oct_fnm_cache"
        # fnm keeps a per-shell directory that can vanish (for example a tmpfs cleaned at reboot): refresh once
        if [ -n "${FNM_MULTISHELL_PATH:-}" ] && [ ! -e "$FNM_MULTISHELL_PATH" ]; then
            _oct_fnm_refresh && . "$_oct_fnm_cache"
        fi
        unset _oct_fnm_shell _oct_fnm_cache
        unset -f _oct_fnm_refresh
    fi
    FNMSH
        cat >"$fishsrc" <<'FNMFISH'
    # octarineOS (ujust dev --only node): fnm shell integration for fish. The output of `fnm env` is cached and
    # regenerated only when the fnm binary is newer than the cache. To turn it off, remove the line that sources this
    # file from your config.fish.
    if command -q fnm
        set -l _oct_cache (set -q XDG_CACHE_HOME; and echo $XDG_CACHE_HOME; or echo $HOME/.cache)/octarine-os/shell/fnm.fish
        if not test -s $_oct_cache; or test (command -s fnm) -nt $_oct_cache
            mkdir -p (path dirname $_oct_cache); and fnm env --use-on-cd --shell fish >$_oct_cache.tmp 2>/dev/null; and mv -f $_oct_cache.tmp $_oct_cache
        end
        test -s $_oct_cache; and source $_oct_cache
        if set -q FNM_MULTISHELL_PATH; and not test -e $FNM_MULTISHELL_PATH
            fnm env --use-on-cd --shell fish >$_oct_cache.tmp 2>/dev/null; and mv -f $_oct_cache.tmp $_oct_cache; and source $_oct_cache
        end
    end
    FNMFISH
        if command -v fnm >/dev/null 2>&1; then fnm_bin=$(command -v fnm); fnm_have=1
        elif command -v brew >/dev/null 2>&1 && formula_installed fnm; then fnm_bin="$(brew_prefix)/bin/fnm"; [ -x "$fnm_bin" ] && fnm_have=1; fi
        if [ "$fnm_have" = 1 ] && "$fnm_bin" list 2>/dev/null | grep -q 'default'; then default_ok=1; fi
        if [ "$fnm_have" = 1 ] && [ "$default_ok" = 1 ] && [ -f "$dir/fnm.sh" ] && [ -f "$dir/fnm.fish" ] && cmp -s "$shsrc" "$dir/fnm.sh" && cmp -s "$fishsrc" "$dir/fnm.fish"; then
            echo "  fnm is installed, a Node default is set and the shell files are in place (already done)."
            record node "already done"
            offer=0
        else
            if [ "$mode" = no ]; then
                [ "$fnm_have" = 0 ] && echo "  Plan: brew install fnm"
                [ "$default_ok" = 0 ] && echo "  Plan: fnm install --lts, fnm default lts-latest"
                place fnm.sh "$shsrc" "$dir/fnm.sh"
                place fnm.fish "$fishsrc" "$dir/fnm.fish"
                record node planned
                return
            fi
            gate node || return
            if [ "$fnm_have" = 0 ]; then
                echo "  brew install fnm"
                if retry brew install fnm; then
                    parts+=(applied)
                    fnm_bin=$(command -v fnm || echo "$(brew_prefix)/bin/fnm")
                else
                    echo "FAILED: brew install fnm. Re-run: ujust dev --only node" >&2
                    fail_step node
                    return
                fi
            fi
            if [ "$default_ok" = 0 ]; then
                echo "  fnm install --lts, then fnm default lts-latest"
                if retry "$fnm_bin" install --lts && "$fnm_bin" default lts-latest; then
                    echo "  Node LTS is installed and set as the default."
                    parts+=(applied)
                else
                    echo "FAILED: fnm install --lts / fnm default lts-latest. Re-run: ujust dev --only node" >&2
                    fail_step node
                    return
                fi
            fi
            file_results=()
            place fnm.sh "$shsrc" "$dir/fnm.sh"; file_results+=("$place_result")
            place fnm.fish "$fishsrc" "$dir/fnm.fish"; file_results+=("$place_result")
            fold_results
            [ "$fold" = applied ] && parts+=(applied)
            if [ "$fold" = failed ]; then fail_step node; return; fi
        fi
        sh_line='[ -r "$HOME/.config/octarine-os/fnm.sh" ] && . "$HOME/.config/octarine-os/fnm.sh"'
        fish_line='test -r $HOME/.config/octarine-os/fnm.fish; and source $HOME/.config/octarine-os/fnm.fish'
        echo "  Shell integration. Add ONE line to your rc file:"
        echo "    bash (~/.bashrc) and zsh (~/.zshrc):  $sh_line"
        echo "    fish (~/.config/fish/config.fish):    $fish_line"
        if [ "$offer" = 1 ]; then
            offer_rc_line "$HOME/.zshrc" "$sh_line"
            offer_rc_line "$HOME/.bashrc" "$sh_line"
            offer_rc_line "$cfg/fish/config.fish" "$fish_line"
        fi
        echo "  Notes: fnm keeps its own Node versions in ~/.local/share/fnm; an existing ~/.nvm is left alone and its versions are separate; .nvmrc files work with fnm (fnm use reads them)."
        if [ "${fold:-already}" = kept ] && [ "${#parts[@]}" -eq 0 ]; then record node "skipped (kept your different file)"
        elif [ "${#parts[@]}" -gt 0 ]; then record node applied "$undo"
        elif [ "$offer" = 1 ]; then record node "already done"
        fi
    }

    # ---- step: python
    step_python() {
        local v listing dir todo=() undo
        echo
        echo "== python"
        echo "Installs uv-managed Python 3.12, 3.13 and 3.14 (uv's own CPython builds under ~/.local/share/uv/python, never the system Python). It does not make any of them the default."
        undo="uv python uninstall ${DEV_PYTHONS:-3.12 3.13 3.14}"
        if ! command -v uv >/dev/null 2>&1; then echo "FAILED: uv is not installed (it ships with the dx image)." >&2; fail_step python; return; fi
        dir="${UV_PYTHON_INSTALL_DIR:-$data/uv/python}"
        listing=$(uv python list --only-installed 2>/dev/null)
        for v in ${DEV_PYTHONS:-3.12 3.13 3.14}; do
            if awk -v v="$v" -v d="$dir" '$1 ~ ("^cpython-" v "[.-]") && index($0, d) { f = 1 } END { exit !f }' <<<"$listing"; then
                echo "  Python $v: already installed."
            else
                todo+=("$v")
            fi
        done
        if [ "${#todo[@]}" -eq 0 ]; then
            echo "  All requested versions are installed."
            uv python list --only-installed
            record python "already done"
            return
        fi
        if [ "$mode" = no ]; then echo "  Plan: uv python install ${todo[*]}"; record python planned; return; fi
        gate python || return
        echo "  uv python install ${todo[*]}"
        if retry uv python install "${todo[@]}"; then
            uv python list --only-installed
            record python applied "$undo"
        else
            echo "FAILED: uv python install ${todo[*]}. Re-run: ujust dev --only python" >&2
            fail_step python
        fi
    }

    # Terminal with gum: a checklist of steps up front (nothing is ticked: you choose); the chosen steps are not asked
    # "Apply?" again, but replacing a different existing file is still its own question (default keep).
    if [ "$mode" = ask ] && [ -z "$only_list" ] && menu_ready; then
        menu_title "octarineOS developer setup"
        menu_multi "Developer setup: choose the steps (only libvirt uses sudo; nothing existing is replaced without asking)" \
            "libvirt^System libvirt: group access and default network (sudo)^0" \
            "tools^Homebrew developer tools in groups you pick^0" \
            "vscode^Visual Studio Code Flatpak (community build, not verified)^0" \
            "jetbrains^JetBrains Toolbox, the official Homebrew cask, with a launcher^0" \
            "rust^Rust: rustup with rust-analyzer and rust-src^0" \
            "java^Java: SDKMAN from the Homebrew tap and Zulu 8 to 25^0" \
            "node^Node: fnm and the latest LTS with cached shell integration^0" \
            "python^Python 3.12 to 3.14 from uv^0"
        if [ "${#MENU_RESULT[@]}" -eq 0 ]; then echo "Nothing selected; nothing changed."; exit 0; fi
        echo "Selected steps: ${MENU_RESULT[*]}"
        if ! menu_confirm "Run these steps?" y; then echo "Nothing changed."; exit 0; fi
        only_list=$(IFS=,; echo "${MENU_RESULT[*]}")
        preconfirmed=1
    fi

    sel libvirt && step_libvirt
    sel tools && step_tools
    sel vscode && step_vscode
    sel jetbrains && step_jetbrains
    sel rust && step_rust
    sel java && step_java
    sel node && step_node
    sel python && step_python

    echo
    echo "== Summary (mode: $mode)"
    printf '%-12s %s\n' "STEP" "RESULT"
    for i in "${!names[@]}"; do
        printf '%-12s %s\n' "${names[$i]}" "${results[$i]}"
    done
    any=0
    for i in "${!names[@]}"; do
        case "${results[$i]}" in
            applied* | FAILED*)
                if [ "${undos[$i]}" != "-" ]; then
                    [ "$any" = 0 ] && { echo; echo "To undo (per step):"; any=1; }
                    echo "  ${names[$i]}: ${undos[$i]}"
                fi
                ;;
        esac
    done
    for n in "${notes[@]-}"; do [ -n "$n" ] && echo "Note: $n"; done
    for i in "${!names[@]}"; do
        case "${results[$i]}" in
            FAILED*) echo "Re-run the failed step: ujust dev --only ${names[$i]}" ;;
        esac
    done
    [ "$kept_any" = 1 ] && echo "Files you already had were kept. Re-run and answer y to a replace question to take the shipped file (your file is backed up first)."
    exit "$failed"
