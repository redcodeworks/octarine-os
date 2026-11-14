#!/usr/bin/env bash
# Tests the one motd script (/usr/libexec/octarine-os/motd), the profile.d hook that calls it and the toggle recipes
# (00-default.just): silent without a terminal, with the flag, without $HOME; fastfetch when it exists, else a tip, else
# /etc/user-motd; never fails; interactive-only and double-source guards of the hook; ujust toggle-motd and toggle-user-motd flip the
# one flag and print the state. Stubs only (fastfetch, the tip files). Needs: bash, just, python3 (a pty for the interactive cases).
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
motd="$here/system_files/usr/libexec/octarine-os/motd"
hook="$here/system_files/etc/profile.d/user-motd.sh"
justdir="$here/system_files/usr/share/ublue-os/just"
root=$(mktemp -d)
trap 'rm -rf -- "$root"' EXIT
pass=0; failn=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { failn=$((failn + 1)); echo "FAIL $1"; sed "s/^/     /" "$root/check.out" "$root/out" 2>/dev/null; }
check() { local d=$1; shift; if "$@" >"$root/check.out" 2>&1; then ok "$d"; else bad "$d"; fi; }

mkdir -p "$root/bin" "$root/home/.config" "$root/tips"
for c in bash env cat grep sed head sort tr shuf printf dirname mkdir rm; do p=$(command -v "$c") && ln -sf "$p" "$root/bin/$c"; done
printf '*Need a container?* `ujust toolbox` can help.\n\n' >"$root/tips/10.md"
printf 'Static motd line\n' >"$root/user-motd"
cat >"$root/ff" <<'F'
#!/usr/bin/env bash
echo "fastfetch-ran"
F
chmod +x "$root/ff"
export HOME="$root/home" OCTARINE_MOTD_TIPS="$root/tips" OCTARINE_MOTD_FILE="$root/user-motd"
run() { PATH="$root/bin" OCTARINE_MOTD_FORCE_TTY=${TTY:-1} bash "$motd" >"$root/out" 2>&1; rc=$?; }
withff() { cp "$root/ff" "$root/bin/fastfetch"; }
noff() { rm -f "$root/bin/fastfetch"; }

noff; TTY=0 run
check "no terminal on stdout: silent, exit 0 (scripts, ssh host cmd, pipes)" bash -c "[ $rc = 0 ] && [ ! -s '$root/out' ]"
touch "$root/home/.config/no-show-user-motd"; withff; run
check "the flag ~/.config/no-show-user-motd: silent, fastfetch not run" bash -c "[ $rc = 0 ] && [ ! -s '$root/out' ]"
rm -f "$root/home/.config/no-show-user-motd"
HOME="$root/missing" run
check "no \$HOME directory: silent, exit 0" bash -c "[ $rc = 0 ] && [ ! -s '$root/out' ]"
(unset HOME; PATH="$root/bin" OCTARINE_MOTD_FORCE_TTY=1 bash "$motd" >"$root/out" 2>&1); rc=$?
check "HOME unset: silent, exit 0" bash -c "[ $rc = 0 ] && [ ! -s '$root/out' ]"
OCTARINE_MOTD_SHOWN=1 run
check "OCTARINE_MOTD_SHOWN set: silent (the caller already showed it)" bash -c "[ ! -s '$root/out' ]"
withff; run
check "fastfetch on PATH: it runs, with no tip and no static text next to it" bash -c "[ $rc = 0 ] && grep -qx fastfetch-ran '$root/out' && ! grep -q 'Tip:' '$root/out' && ! grep -q Static '$root/out'"
printf '#!/usr/bin/env bash\nexit 1\n' >"$root/bin/fastfetch"; run
check "a failing fastfetch never fails the shell (exit 0)" test "$rc" = 0
noff; run
check "no fastfetch: one tip from the base tip files, markdown emphasis and code quotes removed" bash -c "[ $rc = 0 ] && grep -qx 'Tip: Need a container? ujust toolbox can help.' '$root/out'"
OCTARINE_MOTD_TIPS="$root/none" run
check "no fastfetch and no tip files: /etc/user-motd is printed" bash -c "[ $rc = 0 ] && grep -qx 'Static motd line' '$root/out'"
OCTARINE_MOTD_TIPS="$root/none" OCTARINE_MOTD_FILE="$root/none2" run
check "nothing to show: silent, exit 0" bash -c "[ $rc = 0 ] && [ ! -s '$root/out' ]"
check "the script passes no --config to fastfetch (it reads ~/.config/fastfetch then /etc/xdg/fastfetch)" bash -c "! grep -n -- '--config' '$motd' | grep -v '^[0-9]*:#'"
check "the script is executable and bash -n clean" bash -c "[ -x '$motd' ] && bash -n '$motd'"
if command -v shellcheck >/dev/null 2>&1; then check "shellcheck is clean for the motd script" shellcheck "$motd"; else echo "skip shellcheck (not installed here; the CI container has it)"; fi

# ---- the profile.d hook: interactive shells with a terminal only, once
mkdir -p "$root/hook"
cat >"$root/hook/motd-stub" <<F
#!/usr/bin/env bash
echo called >>"$root/hook/log"
F
chmod +x "$root/hook/motd-stub"
sed "s#/usr/libexec/octarine-os/motd#$root/hook/motd-stub#g" "$hook" >"$root/hook/user-motd.sh"
pty() { # shell args... : run under a pseudo terminal, so stdout is a tty
    : >"$root/hook/log"
    HOME="$root/home" python3 -I - "$@" >/dev/null 2>&1 <<'PY'
import os, pty, sys
os.environ["USERMOTDSOURCED"] = ""
os.environ.pop("USERMOTDSOURCED")
pty.spawn(sys.argv[1:])
PY
}
pty bash --norc -i -c ". $root/hook/user-motd.sh"
check "interactive shell on a terminal: the script is called" bash -c "[ \$(wc -l < '$root/hook/log') = 1 ]"
pty bash --norc -i -c ". $root/hook/user-motd.sh; . $root/hook/user-motd.sh"
check "sourced twice (USERMOTDSOURCED guard): called once" bash -c "[ \$(wc -l < '$root/hook/log') = 1 ]"
pty bash --norc -c ". $root/hook/user-motd.sh"
check "non-interactive shell (bash -lc, scripts) even on a terminal: not called" bash -c "[ ! -s '$root/hook/log' ]"
: >"$root/hook/log"; HOME="$root/home" bash --norc -i -c ". $root/hook/user-motd.sh" >/dev/null 2>&1 </dev/null
check "interactive shell with stdout not a terminal: not called" bash -c "[ ! -s '$root/hook/log' ]"
check "the hook ships as /etc/profile.d/user-motd.sh (same name as the base file, so it replaces it) and calls only our script" bash -c "grep -qF /usr/libexec/octarine-os/motd '$hook' && ! grep -q ublue-motd '$hook' && ! grep -q 'cat /etc/user-motd' '$hook'"

# ---- the recipes: ours import the base file and win; one flag, state printed
jd="$root/just"; mkdir -p "$jd"
cp "$justdir/00-default.just" "$jd/00-default.just"
cat >"$jd/00-default-base.just" <<'EOF2'
# stub of the base file build.sh renames
toggle-user-motd:
    @echo BASE RAN
# stub
enroll-secure-boot-key:
    @true
EOF2
{ echo 'set allow-duplicate-recipes := true'; echo "import \"$jd/00-default.just\""; } >"$root/Assembled"
J() { just --justfile "$root/Assembled" "$@"; }
check "the assembled justfile lists toggle-motd and toggle-user-motd (once each) and keeps the base's other recipes" bash -c "s=\$(just --justfile '$root/Assembled' --summary | tr ' ' '\n'); [ \$(grep -cx toggle-motd <<<\"\$s\") = 1 ] && [ \$(grep -cx toggle-user-motd <<<\"\$s\") = 1 ] && grep -qx enroll-secure-boot-key <<<\"\$s\""
check "toggle-motd has the description 'Toggle the motd (fastfetch summary or tips) in every shell'" bash -c "just --justfile '$root/Assembled' --list | grep -q 'Toggle the motd (fastfetch summary or tips) in every shell'"
rm -f "$root/home/.config/no-show-user-motd"
J toggle-motd >"$root/out" 2>&1
check "toggle-motd (motd on): creates the flag and says it is now off" bash -c "[ -e '$root/home/.config/no-show-user-motd' ] && grep -q 'motd is now off' '$root/out'"
J toggle-motd >"$root/out" 2>&1
check "toggle-motd again: removes the flag and says it is now on" bash -c "[ ! -e '$root/home/.config/no-show-user-motd' ] && grep -q 'motd is now on' '$root/out'"
J toggle-user-motd >"$root/out" 2>&1
check "toggle-user-motd runs OUR recipe (the base stub does not run) and flips the same flag" bash -c "[ -e '$root/home/.config/no-show-user-motd' ] && ! grep -q 'BASE RAN' '$root/out' && grep -q 'motd is now off' '$root/out'"
rm -f "$root/home/.config/no-show-user-motd"
check "build.sh keeps the base 00-default.just as 00-default-base.just (the rename list)" bash -c "grep -q 'for f in 00-default 10-update 30-distrobox' '$here/build_files/build.sh'"
check "the image's justfiles define toggle-user-motd once, in our file only (the base copy is the renamed one)" bash -c "[ \$(grep -rlE '^toggle-user-motd' '$justdir' | wc -l) = 1 ]"
echo; echo "passed: $pass, failed: $failn"
[ "$failn" = 0 ]
