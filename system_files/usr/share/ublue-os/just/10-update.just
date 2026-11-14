# vim: set ft=make :

# Wraps the base image's 10-update.just. build.sh keeps the base file as 10-update-base.just; this file imports it and
# defines `update` and `toggle-updates` itself (a recipe of the importing file beats the imported one, whereas between two
# imported files the FIRST import wins, so 60-custom.just could not override them). changelogs, update-firmware and the
# aliases (upgrade, changelog, auto-update) come from the base file unchanged.
import "10-update-base.just"

# Choose which automatic updates run: image, Flatpak, distrobox, Homebrew (a checklist; or enable|disable|status SOURCE...)
[group('Setup')]
[positional-arguments]
toggle-updates *args:
    #!/usr/bin/env bash
    set -uo pipefail
    menu_lib="${OCTARINE_MENU_LIB:-/usr/share/octarine-os/lib/menu.sh}"
    # shellcheck source=/dev/null
    if [ -r "$menu_lib" ]; then . "$menu_lib"; fi
    if ! declare -F menu_ready >/dev/null; then menu_ready() { return 1; }; menu_ready_one() { return 1; }; menu_tty() { return 1; }; menu_title() { printf '%s\n' "$1"; }; menu_confirm() { return 1; }; fi
    us_lib="${OCTARINE_UPDATE_LIB:-/usr/share/octarine-os/lib/update-services.sh}"
    # shellcheck source=/dev/null
    . "$us_lib" || { echo "Cannot read $us_lib" >&2; exit 1; }
    mode=ask
    action=""
    named=()
    for a in "$@"; do
        case "$a" in
            help | --help | -h) printf '%s\n' 'Turn the automatic updates on or off. `ujust toggle-updates [enable|disable|status] [SOURCE...] [--yes|--no]`. Sources: image (stages the next image), flatpak (system and user), distrobox (upgrades every container), brew-update (brew update), brew-upgrade (brew upgrade), or all. Without arguments it shows a checklist of the sources, ticked where the updates are on; what you tick is on afterwards. `ujust update` runs exactly the sources that are on. enable/disable without a source means all of them. --yes skips the question, --no only prints the plan. System timers use sudo; user timers do not.'; exit 0 ;;
            --yes) mode=yes ;;
            --no) mode=no ;;
            enable | disable | status) action=$a ;;
            all) named+=("${US_IDS[@]}") ;;
            -*) echo "Unknown option: $a (use --yes or --no)" >&2; exit 2 ;;
            *) if us_valid "$a"; then named+=("$a"); else echo "Unknown source: $a (use ${US_IDS[*]} or all)" >&2; exit 2; fi ;;
        esac
    done
    show_status() {
        local id st
        printf '%-14s %-12s %s\n' SOURCE STATE UPDATES
        for id in "${US_IDS[@]}"; do
            st=$(us_state "$id")
            printf '%-14s %-12s %s\n' "$id" "$st" "$(us_label "$id")"
        done
    }
    if [ "$action" = status ]; then show_status; exit 0; fi
    # want: the ids that should be on afterwards
    want=()
    if [ -n "$action" ]; then
        [ "${#named[@]}" -gt 0 ] || named=("${US_IDS[@]}")
        for id in "${US_IDS[@]}"; do
            if [ "$(us_state "$id")" = unavailable ]; then continue; fi
            on=0; us_on "$id" && on=1
            hit=0; for n in "${named[@]}"; do [ "$n" = "$id" ] && hit=1; done
            if [ "$action" = enable ]; then { [ "$on" = 1 ] || [ "$hit" = 1 ]; } && want+=("$id")
            else { [ "$on" = 1 ] && [ "$hit" = 0 ]; } && want+=("$id"); fi
        done
    elif [ "${#named[@]}" -gt 0 ]; then
        echo "Name an action with the sources: enable or disable (ujust toggle-updates --help)" >&2
        exit 2
    elif menu_ready; then
        items=()
        for id in "${US_IDS[@]}"; do
            if [ "$(us_state "$id")" = unavailable ]; then continue; fi
            sel=0; us_on "$id" && sel=1
            items+=("$id^$(us_label "$id")^$sel")
        done
        menu_multi "Automatic updates: tick the ones that should run" "${items[@]}"
        want=("${MENU_RESULT[@]}")
        if [ "${#want[@]}" -eq 0 ]; then
            any=0; for id in "${US_IDS[@]}"; do us_on "$id" && any=1; done
            if [ "$any" = 1 ]; then
                menu_confirm "Nothing ticked: turn off all automatic updates?" n || { echo "Left as it is."; exit 0; }
            fi
        fi
    else
        show_status
        echo "Run it in a terminal for the checklist, or: ujust toggle-updates enable|disable SOURCE..."
        exit 0
    fi
    in_list() { local x=$1; shift; local y; for y in "$@"; do [ "$x" = "$y" ] && return 0; done; return 1; }
    sys_on=(); sys_off=(); usr_on=(); usr_off=(); plan=()
    for id in "${US_IDS[@]}"; do
        if [ "$(us_state "$id")" = unavailable ]; then continue; fi
        on=0; us_on "$id" && on=1
        sel=0; in_list "$id" "${want[@]}" && sel=1
        # a half-enabled source (some of its timers on, some off) is not "on": turning it on completes it
        half=0; [ "$on" = 1 ] && ! us_full "$id" && half=1
        if [ "$on" = "$sel" ] && [ "$half" = 0 ]; then continue; fi
        if [ "$sel" = 1 ] && [ "$half" = 1 ]; then plan+=("turn on   $id (completes it: only some of its timers were on)")
        elif [ "$sel" = 1 ]; then plan+=("turn on   $id"); else plan+=("turn off  $id"); fi
        while read -r scope unit; do
            [ -n "$unit" ] || continue
            if [ "$sel" = 1 ]; then
                if [ "$scope" = user ]; then usr_on+=("$unit"); else sys_on+=("$unit"); fi
            else
                if [ "$scope" = user ]; then usr_off+=("$unit"); else sys_off+=("$unit"); fi
            fi
        done < <(us_units "$id")
    done
    if [ "${#plan[@]}" -eq 0 ]; then
        echo "Nothing to change."
        show_status
        exit 0
    fi
    printf '%s\n' "${plan[@]}"
    if [ "$mode" = no ]; then exit 0; fi
    if [ "$mode" = ask ]; then
        menu_confirm "Apply?" y || { echo "Left as it is."; exit 0; }
    fi
    failed=0
    if [ "${#sys_on[@]}" -gt 0 ]; then sudo systemctl enable --now "${sys_on[@]}" || failed=1; fi
    if [ "${#sys_off[@]}" -gt 0 ]; then sudo systemctl disable --now "${sys_off[@]}" || failed=1; fi
    if [ "${#usr_on[@]}" -gt 0 ]; then systemctl --user enable --now "${usr_on[@]}" || failed=1; fi
    if [ "${#usr_off[@]}" -gt 0 ]; then systemctl --user disable --now "${usr_off[@]}" || failed=1; fi
    show_status
    exit "$failed"

# Update what ujust toggle-updates has switched on: image, Flatpak, distrobox, Homebrew (--all, --only, --no)
[group('Setup')]
[positional-arguments]
update *args:
    #!/usr/bin/env bash
    set -uo pipefail
    us_lib="${OCTARINE_UPDATE_LIB:-/usr/share/octarine-os/lib/update-services.sh}"
    # shellcheck source=/dev/null
    . "$us_lib" || { echo "Cannot read $us_lib" >&2; exit 1; }
    mode=run
    all=0
    only=()
    for a in "$@"; do
        case "$a" in
            help | --help | -h) printf '%s\n' 'Update now, but only the sources that `ujust toggle-updates` has switched on. `ujust update [SOURCE...] [--all] [--no]`. Sources: image (sudo bootc upgrade, or rpm-ostree upgrade when packages are layered; stages the image, reboot to use it), flatpak (system and user), distrobox (every container), brew-update (brew update), brew-upgrade (brew upgrade). Naming sources updates just those, --all updates every source whatever is switched on, --no only prints the plan. A failing source does not stop the others.'; exit 0 ;;
            --all) all=1 ;;
            --no) mode=plan ;;
            -*) echo "Unknown option: $a (use --all or --no)" >&2; exit 2 ;;
            *) if us_valid "$a"; then only+=("$a"); else echo "Unknown source: $a (use ${US_IDS[*]})" >&2; exit 2; fi ;;
        esac
    done
    in_list() { local x=$1; shift; local y; for y in "$@"; do [ "$x" = "$y" ] && return 0; done; return 1; }
    run_list=()
    for id in "${US_IDS[@]}"; do
        if [ "${#only[@]}" -gt 0 ]; then in_list "$id" "${only[@]}" && run_list+=("$id")
        elif [ "$all" = 1 ]; then run_list+=("$id")
        elif us_on "$id"; then run_list+=("$id"); fi
    done
    if [ "$(us_state image)" = disabled ] && ! in_list image "${run_list[@]}"; then
        echo "Image updates are switched off (ujust toggle-updates turns them on); the image is not updated now."
    fi
    if [ "${#run_list[@]}" -eq 0 ]; then
        echo "No update source is switched on. Turn some on with 'ujust toggle-updates', or name one: ujust update flatpak"
        exit 0
    fi
    brew_bin=$(command -v brew || true)
    if [ -z "$brew_bin" ] && [ -x /home/linuxbrew/.linuxbrew/bin/brew ]; then brew_bin=/home/linuxbrew/.linuxbrew/bin/brew; fi
    image_cmd() {
        local layered
        layered=$(rpm-ostree status --json 2>/dev/null | jq -r '(.deployments[0]."requested-packages" // []) | length' 2>/dev/null || echo 0)
        if [ "${layered:-0}" -gt 0 ]; then echo "sudo rpm-ostree upgrade"; else echo "sudo bootc upgrade"; fi
    }
    cmd_of() {
        case "$1" in
            image) image_cmd ;;
            flatpak) echo "flatpak update -y --noninteractive" ;;
            distrobox) echo "distrobox upgrade --all" ;;
            brew-update) echo "${brew_bin:-brew} update" ;;
            brew-upgrade) echo "${brew_bin:-brew} upgrade" ;;
        esac
    }
    failed=()
    for id in "${run_list[@]}"; do
        c=$(cmd_of "$id")
        echo "== $(us_label "$id")"
        if [ "$mode" = plan ]; then echo "Would run: $c"; continue; fi
        echo "Running: $c"
        # shellcheck disable=SC2086
        if $c; then echo "Done: $id"; else echo "Failed: $id" >&2; failed+=("$id"); fi
    done
    if [ "$mode" = plan ]; then exit 0; fi
    if [ "${#failed[@]}" -gt 0 ]; then echo "Failed sources: ${failed[*]}" >&2; exit 1; fi
    case " ${run_list[*]} " in *" image "*) echo "A staged image needs a reboot to take effect (rpm-ostree status shows it)." ;; esac
    exit 0
