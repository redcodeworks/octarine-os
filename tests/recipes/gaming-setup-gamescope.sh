#!/usr/bin/env bash
# Thin test for the `ujust gaming-setup gamescope-session` step (60-custom.just): writes SCREEN_WIDTH/SCREEN_HEIGHT/REFRESH_RATE of the detected (here: given)
# display mode into a marked block of ~/.config/environment.d/10-gamescope-session.conf; opt-in only, idempotent, never replaces hand edits without a yes
# (and a backup), reset removes the block. Nothing real changes: HOME is a temp dir, flatpak and rpm are fakes. Needs: bash, just.
# Run: tests/recipes/gaming-setup-gamescope.sh
set -uo pipefail

here=$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)
justfile="$here/system_files/usr/share/ublue-os/just/60-custom.just"
root=$(mktemp -d)
trap 'rm -rf -- "$root"' EXIT
pass=0; failn=0; rc=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { failn=$((failn + 1)); echo "FAIL $1"; sed 's/^/     /' "$root/out" 2>/dev/null; echo "     rc=$rc"; }
check() { local d=$1; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }
has() { grep -qF -- "$1" "$root/out"; }
export LOG="$root/log" HOME="$root/home" OCTARINE_MENU_LIB="$here/system_files/usr/share/octarine-os/lib/menu.sh" GAMING_SETUP_NATIVE_STEAM=1
unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME GAMING_SETUP_RES OCTARINE_MENU_FORCE_TTY
bin="$root/bin"; mkdir -p "$bin" "$HOME"
mk() { printf '#!/bin/bash\n%s\n' "$2" > "$bin/$1"; chmod +x "$bin/$1"; }
mk flatpak 'exit 1'
mk rpm 'exit 0'
src="$root/gamescope-session.conf"; echo "UPSCALER=fsr" > "$src"
dest="$HOME/.config/environment.d/10-gamescope-session.conf"
# run STDIN ARG...: the recipe with the fake gx defaults file and the display mode 5120x2160@119.88
run() { local in=$1; shift; : > "$LOG"; GAMING_SETUP_GAMESCOPE_SRC="${SRC:-$src}" GAMING_SETUP_RES="${RES:-5120x2160@119.88}" PATH="$bin:$PATH" just --justfile "$justfile" gaming-setup "$@" > "$root/out" 2>&1 <<<"$in"; rc=$?; }
baks() { ls "$dest".bak-* 2>/dev/null | wc -l; }

SRC="$root/missing" run "" gamescope-session --yes
check "not a gx image (no defaults file): skipped, nothing written, exit 0" bash -c "test $rc = 0 && ! test -e '$dest'" && has "skipped (not a gx image)"

run "" --yes
# (the exit status is not asserted: the other steps of a bare --yes run depend on the machine, for example the extest libraries)
check "--yes without naming the step: opt-in only, nothing written" bash -c "! test -e '$dest'" && has "gamescope-session            skipped (not applied)"

run "" gamescope-session --no
check "--no only prints the plan, nothing written" bash -c "test $rc = 0 && ! test -e '$dest'" && has "planned (would ask)"

run "" gamescope-session --yes
check "named step: the file is written, exit 0" bash -c "test $rc = 0 && test -f '$dest'"
check "...with the three keys, the refresh rate rounded, inside the marked block" bash -c "grep -qx 'SCREEN_WIDTH=5120' '$dest' && grep -qx 'SCREEN_HEIGHT=2160' '$dest' && grep -qx 'REFRESH_RATE=120' '$dest' && grep -q '^# >>> octarine-os' '$dest' && grep -q '^# <<< octarine-os' '$dest'"
check "...and no output name is invented" bash -c "! grep -q OUTPUT_CONNECTOR '$dest'"
has "applied" && has "To undo" && ok "...the summary says applied and how to undo it" || bad "summary"

cp -p "$dest" "$root/first"
run "" gamescope-session --yes
check "second run: already done, file identical, no backup" bash -c "test $rc = 0 && cmp -s '$root/first' '$dest' && test $(baks) = 0" && has "already done"

# a hand edit outside the block survives a changed display; the changed block needs a yes
printf 'MOUSE_SENSITIVITY=2\n' >> "$dest"; cp -p "$dest" "$root/edited"
RES=2560x1440@144 run "" gamescope-session
check "another display, answer empty (default no): the file is not changed" bash -c "test $rc = 0 && cmp -s '$root/edited' '$dest' && test $(baks) = 0" && has "differs"
RES=2560x1440@144 run "y" gamescope-session
check "answer yes: the block is replaced, the hand edit stays, a timestamped backup exists" bash -c "grep -qx 'SCREEN_WIDTH=2560' '$dest' && grep -qx 'REFRESH_RATE=144' '$dest' && ! grep -qx 'SCREEN_WIDTH=5120' '$dest' && grep -qx 'MOUSE_SENSITIVITY=2' '$dest' && test $(baks) = 1"

# a file that was never ours: appended only after a yes, with a backup
rm -f "$dest" "$dest".bak-*; printf 'SCREEN_WIDTH=1920\nMY=1' > "$dest"; cp -p "$dest" "$root/mine"
run "" gamescope-session
check "an existing file without the block is not touched on the default answer" bash -c "cmp -s '$root/mine' '$dest' && test $(baks) = 0" && has "appended at the end"
run "y" gamescope-session
check "answer yes: the block is appended, the user's lines stay, a backup of the original exists" bash -c "grep -qx 'SCREEN_WIDTH=1920' '$dest' && grep -qx 'MY=1' '$dest' && grep -qx 'SCREEN_WIDTH=5120' '$dest' && test $(baks) = 1 && cmp -s '$root/mine' \$(ls '$dest'.bak-*)"

# unbalanced markers: refuse
printf '# >>> octarine-os: ujust gaming-setup gamescope-session (managed lines; the command rewrites only this block, lines outside it are yours)\nSCREEN_WIDTH=1\n' > "$dest"; cp -p "$dest" "$root/broken"
run "y" gamescope-session
check "only one marker line: reported as FAILED (non-zero), file untouched" bash -c "test $rc != 0 && cmp -s '$root/broken' '$dest'" && has "FAILED"

# reset
rm -f "$dest" "$dest".bak-*; run "" gamescope-session --yes; run "" reset --yes
check "reset removes the file when only the block (and our header) was in it" bash -c "test $rc = 0 && ! test -e '$dest'" && has "reset: gamescope session"
run "" gamescope-session --yes; printf 'MOUSE_SENSITIVITY=3\n' >> "$dest"; run "" reset --yes
check "reset keeps the user's own lines and drops the block" bash -c "grep -qx 'MOUSE_SENSITIVITY=3' '$dest' && ! grep -q 'SCREEN_WIDTH' '$dest' && ! grep -q 'octarine-os: ujust' '$dest'"

# the checklist offers the step on the gx image and starts with nothing ticked
printf '#!/bin/bash\necho "gum $*" >>"$LOG"; exit 0\n' > "$bin/gum"; chmod +x "$bin/gum"
: > "$LOG"; OCTARINE_MENU_FORCE_TTY=1 GAMING_SETUP_GAMESCOPE_SRC="$src" PATH="$bin:$PATH" just --justfile "$justfile" gaming-setup > "$root/out" 2>&1 < /dev/null; rc=$?
check "the checklist lists gamescope-session, nothing pre-ticked" bash -c "grep -q 'Steam Big Picture session' '$LOG' && ! grep -q -- '--selected ' '$LOG'"
rm -f "$bin/gum"
check "the help text names the step" bash -c "PATH='$bin:$PATH' just --justfile '$justfile' gaming-setup --help | grep -q 'gamescope-session'"
echo; echo "$pass passed, $failn failed"; [ "$failn" = 0 ]
