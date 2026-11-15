# shellcheck shell=bash
# One emoji at the start of selected message lines of the octarineOS recipes, so output is easier to scan. Source this file (menu.sh does, which every big
# recipe already sources); it never runs on its own, needs no launcher helper and works under any launcher that runs the recipes.
#
# It redefines `echo` for the script that sources it: a line is changed ONLY when
#   - it goes to a terminal (stdout `[ -t 1 ]`, which is the stderr terminal for `echo x >&2`), so piped, captured, file and $(...) output stays byte for byte
#     what it is without this file (all tests capture output); OCTARINE_FORCE_EMOJI=1 skips ONLY that terminal test (tests);
#   - emoji are not switched off: NO_EMOJI set to a NON-EMPTY value (the NO_COLOR convention: an empty NO_EMOJI= does nothing), OCTARINE_PLAIN non-empty and not 0,
#     or TERM empty or dumb;
#   - echo has no options (-n, -e, -E pass through unchanged), the line does not start with a space (indented continuation and table rows stay plain), and its text
#     starts with one of the message words below. Data lines (paths, versions, key=value, list rows), `--help` text (printed with printf) and menus and pickers
#     (gum, the numbered prompts) never match. The text after the emoji and the one space is exactly the original text; one emoji per line.
# Mapping (all East Asian Width W, no variation selector): ❌ errors (ERROR, Refused, Could not, Cannot, Failed, Unknown, Usage), 🟡 warnings and notes (WARNING,
# Note, Skipped, Not applied, Kept, Left ... alone), ❗ asks the user to act (Needs:, Next:, Log out, Reboot needed, Touch), 🔁 restart or reboot to apply, ✅ success
# (Done, Installed, Applied, Enabled, Added, Created, Wrote), 🧹 removal (Removed, Cleaned, Deleted, Disabled, Reset), 🔄 changes (Updated, Replaced, Edited, Switched,
# Changed), 🎨 a reported setting change ("... is now ...").
oe_emoji_enabled() {
    [[ -z "${NO_EMOJI:-}" ]] || return 1
    [[ -z "${OCTARINE_PLAIN:-}" || "${OCTARINE_PLAIN}" == 0 ]] || return 1
    [[ -n "${TERM:-}" && "${TERM}" != dumb ]] || return 1
    [[ "${OCTARINE_FORCE_EMOJI:-}" == 1 ]] || [[ -t 1 ]]
}
# oe_emoji_pick <text>: sets OE_EMOJI (empty for no emoji)
oe_emoji_pick() {
    local t=$1
    OE_EMOJI=""
    if [[ "${t}" =~ ^(ERROR|Error|Refused|Refusing|Could\ not|Cannot|Can\'t|Failed|FAILED|Unknown\ |Usage:|usage:) ]]; then OE_EMOJI="❌"
    elif [[ "${t}" =~ ^(WARNING|Warning|warning|Note:|Notice:|Skipped|skipped|Not\ applied|Not\ changed|Kept|Left\ .*\ alone) ]]; then OE_EMOJI="🟡"
    elif [[ "${t}" =~ ^(Restart|Reboot|Log\ out\ and\ back\ in).*(apply|take\ effect|effect) ]]; then OE_EMOJI="🔁"
    elif [[ "${t}" =~ ^(Needs:|Next:|Log\ out|Logout|Reboot\ (is\ )?needed|Touch\ ) ]]; then OE_EMOJI="❗"
    elif [[ "${t}" =~ ^(Done|done|Installed|installed|Applied|applied|Enabled|Added|Created|Wrote|wrote)([^[:alnum:]]|$) ]]; then OE_EMOJI="✅"
    elif [[ "${t}" =~ ^(Removed|Cleaned|Deleted|Disabled|Reset)([^[:alnum:]]|$) ]]; then OE_EMOJI="🧹"
    elif [[ "${t}" =~ ^(Updated|Replaced|Edited|Switched|Changed)([^[:alnum:]]|$) ]]; then OE_EMOJI="🔄"
    elif [[ "${t}" =~ ^[^[:space:]].*\ is\ now\  ]]; then OE_EMOJI="🎨"
    fi
}
echo() {
    local text
    if [[ $# -eq 0 || "$1" == -* ]]; then builtin echo "$@"; return; fi
    text="$*"
    if [[ "${text}" != [[:space:]]* ]] && oe_emoji_enabled; then
        oe_emoji_pick "${text}"
        if [[ -n "${OE_EMOJI}" ]]; then builtin echo "${OE_EMOJI} ${text}"; return; fi
    fi
    builtin echo "$@"
}
