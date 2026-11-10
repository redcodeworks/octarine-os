# shellcheck shell=bash
# The automatic update sources of octarineOS, shared by `ujust toggle-updates` and `ujust update`. Source this file; it is
# never run on its own:
#
#   us_lib="${OCTARINE_UPDATE_LIB:-/usr/share/octarine-os/lib/update-services.sh}"
#   . "$us_lib"
#
# One source = one row of the toggle checklist = one step of `ujust update`. A source is enabled when any of its timers is
# enabled (flatpak has a system and a user timer), so `ujust update` follows exactly what `ujust toggle-updates` shows.
#
#   US_IDS              the source ids in the order `ujust update` runs them
#   us_label ID         the text of the checklist row
#   us_units ID         "scope unit" lines (scope: system or user)
#   us_state ID         enabled | disabled | unavailable (a timer is missing from this image)
#   us_on ID            true when the source is enabled
US_IDS=(image flatpak distrobox brew-update brew-upgrade)

us_label() {
    case "$1" in
        image) echo "Image: stage the next image (bootc upgrade)" ;;
        flatpak) echo "Flatpak: apps and runtimes, system and user" ;;
        distrobox) echo "Distrobox: upgrade every container" ;;
        brew-update) echo "Homebrew: refresh formulae (brew update)" ;;
        brew-upgrade) echo "Homebrew: upgrade installed formulae (brew upgrade)" ;;
    esac
}

us_units() {
    case "$1" in
        image) echo "system rpm-ostreed-automatic.timer" ;;
        flatpak) printf '%s\n' "system flatpak-system-update.timer" "user flatpak-user-update.timer" ;;
        distrobox) echo "user octarine-distrobox-upgrade.timer" ;;
        brew-update) echo "system brew-update.timer" ;;
        brew-upgrade) echo "system brew-upgrade.timer" ;;
    esac
}

# us_unit_state SCOPE UNIT -> enabled | disabled | missing
us_unit_state() {
    local scope=$1 unit=$2 out
    if [ "$scope" = user ]; then out=$(systemctl --user is-enabled "$unit" 2>&1); else out=$(systemctl is-enabled "$unit" 2>&1); fi
    case "$out" in
        enabled | enabled-runtime) echo enabled ;;
        *"not-found"* | *"No such file"* | *"does not exist"*) echo missing ;;
        *) echo disabled ;;
    esac
}

us_state() {
    local scope unit s any_enabled=0 any_present=0
    while read -r scope unit; do
        [ -n "$unit" ] || continue
        s=$(us_unit_state "$scope" "$unit")
        [ "$s" = missing ] || any_present=1
        [ "$s" = enabled ] && any_enabled=1
    done < <(us_units "$1")
    if [ "$any_enabled" = 1 ]; then echo enabled; elif [ "$any_present" = 1 ]; then echo disabled; else echo unavailable; fi
}

us_on() { [ "$(us_state "$1")" = enabled ]; }

us_valid() { local i; for i in "${US_IDS[@]}"; do [ "$i" = "$1" ] && return 0; done; return 1; }
