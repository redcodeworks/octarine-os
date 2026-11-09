# shellcheck shell=bash
# Shared menu helpers for the octarineOS ujust recipes. Source this file; it is never run on its own:
#
#   menu_lib="${OCTARINE_MENU_LIB:-/usr/share/octarine-os/lib/menu.sh}"
#   [ -r "$menu_lib" ] && . "$menu_lib"
#
# Items are strings "id^text^selected": id is what the caller gets back, text is what the user sees, selected is 1 to
# preselect (checklists only). An item with an EMPTY id is a section heading ("^── Group ───^0"): it is shown and
# never returned. Text must not contain "^"; commas in text are shown as ";" (gum splits --selected on commas).
#
# Functions (all keep stdout for the caller's own output; results come back in variables):
#   menu_tty            true on a terminal (stdin and stdout), or when OCTARINE_MENU_FORCE_TTY is set (tests)
#   menu_ready          true when menu_multi/menu_confirm can use real gum (a terminal and gum on PATH)
#   menu_ready_one      true when menu_one can use ugum choose (a terminal and ugum on PATH)
#   menu_title TEXT     a styled title with gum, plain text otherwise
#   menu_multi HEADER ITEM...   checklist (gum choose --no-limit, Bluefin's devmode look); fills MENU_RESULT (array of
#                       ids). Returns 0 (MENU_RESULT may be empty: nothing chosen, Esc or Ctrl-C), 3 when no handler is
#                       available (the caller falls back to its built-in picker)
#   menu_one HEADER ITEM...     single choice through `ugum choose` (it has no flags in its fzf fallback, so none are
#                       passed; the first item is the default); sets MENU_ONE to the id. Returns 0, 1 when cancelled
#                       or empty, 3 when no handler is available
#   menu_confirm QUESTION [y|n] yes/no, default n. Real `gum confirm` when gum is on PATH, otherwise a plain prompt on
#                       a terminal or stdin. Esc, Ctrl-C, an empty answer and end of input are NO unless the default is
#                       y and the answer is empty. Returns 0 for yes, 1 for no. It never uses `ugum confirm`: its
#                       fallback treats Esc as YES.

menu_tty() { [ -n "${OCTARINE_MENU_FORCE_TTY:-}" ] || { [ -t 0 ] && [ -t 1 ]; }; }
menu_ready() { menu_tty && command -v gum >/dev/null 2>&1; }
menu_ready_one() { menu_tty && command -v ugum >/dev/null 2>&1; }

menu_title() {
    if menu_ready; then gum style --bold --foreground 212 "$1"; else printf '%s\n' "$1"; fi
}

menu_multi() {
    local header=$1 spec id text sel line out rows h n
    shift
    MENU_RESULT=()
    menu_ready || return 3
    local -A id_of=()
    local items=() selected=() args
    for spec in "$@"; do
        IFS='^' read -r id text sel <<<"$spec"
        text=${text//,/;}
        items+=("$text")
        if [ -n "$id" ]; then
            id_of["$text"]=$id
            if [ "${sel:-0}" = 1 ]; then selected+=("$text"); fi
        fi
    done
    rows=${LINES:-$(tput lines 2>/dev/null || echo 24)}
    [[ "$rows" =~ ^[0-9]+$ ]] || rows=24
    h=$((rows - 4))
    n=${#items[@]}
    if [ "$n" -lt "$h" ]; then h=$n; fi
    if [ "$h" -lt 3 ]; then h=3; fi
    args=(choose --no-limit --height "$h" --selected-prefix "◉  " --unselected-prefix "○  " --cursor "▸  ")
    if [ -n "$header" ]; then args+=(--header "$header"); fi
    if [ "${#selected[@]}" -gt 0 ]; then args+=(--selected "$(IFS=,; echo "${selected[*]}")"); fi
    out=$(gum "${args[@]}" "${items[@]}") || true
    while IFS= read -r line; do
        if [ -n "$line" ] && [ -n "${id_of[$line]:-}" ]; then MENU_RESULT+=("${id_of[$line]}"); fi
    done <<<"$out"
    return 0
}

menu_one() {
    local header=$1 spec id text sel out
    shift
    MENU_ONE=""
    menu_ready_one || return 3
    local -A id_of=()
    local items=()
    for spec in "$@"; do
        IFS='^' read -r id text sel <<<"$spec"
        [ -n "$id" ] || continue
        items+=("$text")
        id_of["$text"]=$id
    done
    if [ -n "$header" ]; then printf '%s\n' "$header"; fi
    out=$(ugum choose "${items[@]}") || true
    out=${out%%$'\n'*}
    [ -n "$out" ] && [ -n "${id_of[$out]:-}" ] || return 1
    MENU_ONE=${id_of[$out]}
    return 0
}

menu_confirm() {
    local q=$1 def=${2:-n} reply
    if menu_ready; then
        if [ "$def" = y ]; then gum confirm "$q" && return 0; else gum confirm --default=false "$q" && return 0; fi
        return 1
    fi
    if [ "$def" = y ]; then printf '%s [Y/n] ' "$q"; else printf '%s [y/N] ' "$q"; fi
    IFS= read -r reply || return 1
    case "$reply" in
        [Yy]*) return 0 ;;
        "") [ "$def" = y ] && return 0 ;;
    esac
    return 1
}
