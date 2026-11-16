#!/usr/bin/env bash
# Tests system_files/usr/share/octarine-os/lib/emoji.sh: the emoji mapping, the plain switches, and that captured output is untouched.
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
lib="$here/system_files/usr/share/octarine-os/lib/emoji.sh"
pass=0; failn=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { failn=$((failn + 1)); echo "FAIL $1"; }
# run <env assignments...> -- <echo args...>: prints what the helper's echo outputs, captured (not a terminal)
out() { env -u NO_EMOJI -u OCTARINE_PLAIN -u OCTARINE_FORCE_EMOJI TERM=xterm "$@" bash -c '. "$0"; echo "$@"' "$lib" "${ECHO_ARGS[@]}"; }
want() { # desc expected text...
    local d=$1 e=$2; shift 2; ECHO_ARGS=("$@")
    local got; got=$(out OCTARINE_FORCE_EMOJI=1)
    if [[ "$got" == "$e" ]]; then ok "$d"; else bad "$d (got: $got)"; fi
}
want "error" "❌ ERROR: x" "ERROR: x"
want "refused" "❌ Refused: x" "Refused: x"
want "warning" "🟡 WARNING: x" "WARNING: x"
want "needs" "❗ Needs: x" "Needs: x"
want "restart to apply" "🔁 Reboot to apply" "Reboot to apply"
want "done" "✅ Done." "Done."
want "removed" "🧹 Removed x" "Removed x"
want "updated" "🔄 Updated x" "Updated x"
want "setting" "🎨 motd is now on" "motd is now on"
want "data line unchanged" "key=value" "key=value"
want "indented line unchanged" "  Done." "  Done."
want "path unchanged" "/usr/bin/x" "/usr/bin/x"
want "Doneness is not Done" "Donegal" "Donegal"
want "option passes through (echo -n of nothing prints nothing)" "" -n
ECHO_ARGS=("Done."); got=$(out)
[[ "$got" == "Done." ]] && ok "captured output (not a terminal) is untouched" || bad "captured: $got"
for v in "NO_EMOJI=1" "OCTARINE_PLAIN=1" "TERM=dumb" "TERM="; do
    ECHO_ARGS=("Done."); got=$(out OCTARINE_FORCE_EMOJI=1 "$v")
    [[ "$got" == "Done." ]] && ok "$v turns emoji off" || bad "$v: $got"
done
ECHO_ARGS=("Done."); got=$(out OCTARINE_FORCE_EMOJI=1 NO_EMOJI=)
[[ "$got" == "✅ Done." ]] && ok "empty NO_EMOJI does nothing" || bad "empty NO_EMOJI: $got"
ECHO_ARGS=("Done."); got=$(out OCTARINE_FORCE_EMOJI=1 OCTARINE_PLAIN=0)
[[ "$got" == "✅ Done." ]] && ok "OCTARINE_PLAIN=0 does nothing" || bad "PLAIN=0: $got"
if command -v script > /dev/null 2>&1; then
    got=$(env -u NO_EMOJI -u OCTARINE_PLAIN TERM=xterm script -qec "bash -c '. \"$lib\"; echo Done.'" /dev/null | tr -d '\r')
    [[ "$got" == "✅ Done." ]] && ok "a pty run gets the emoji" || bad "pty: $got"
fi
echo "emoji tests: $pass passed, $failn failed"
[[ $failn -eq 0 ]]
