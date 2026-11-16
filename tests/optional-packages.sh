#!/usr/bin/env bash
# Tests the optional package groups of build_files/build.sh with a stub dnf5 (the functions are cut out of the script and run on their own): a group is retried once as a
# whole before the one-by-one fallback, a package that stays missing is listed, a missing session package (niri, noctalia) FAILS the build; and the label chain
# (just rechunk writes org.octarineos.optional-packages-missing, the daily skip check reads it). Run: tests/optional-packages.sh
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
root=$(mktemp -d)
trap 'rm -rf -- "${root:?}"' EXIT
pass=0; failn=0; rc=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { failn=$((failn + 1)); echo "FAIL $1"; sed 's/^/     /' "$root/run" 2> /dev/null; echo "     rc=$rc"; }
check() { local d=$1; shift; if "$@" > "$root/out" 2>&1; then ok "$d"; else bad "$d"; fi; }
# the optional install functions and the session check, cut out of build.sh
sed -n '/^# --- optional install functions/,/^# --- end optional install functions/p' "$here/build_files/build.sh" > "$root/loop.sh"
grep -q 'session package' "$root/loop.sh" || { echo "FAIL could not cut the loop out of build.sh"; exit 1; }
mkdir -p "$root/bin"
cat > "$root/bin/dnf5" <<'F'
#!/usr/bin/env bash
echo "dnf5 $*" >> "$CALLS"
[[ "$1" == install ]] || exit 0
shift; [[ "$1" == -y ]] && shift
# FAIL_PKGS lists packages that never install; FLAKY_ONCE=1 fails the first multi-package transaction only
for p in "$@"; do case " ${FAIL_PKGS:-} " in *" $p "*) exit 1 ;; esac; done
if [[ -n "${FLAKY_ONCE:-}" && $# -gt 1 ]]; then n=$(cat "$COUNT" 2> /dev/null || echo 0); echo $((n + 1)) > "$COUNT"; [[ "$n" -gt 0 ]] || exit 1; fi
exit 0
F
printf '#!/usr/bin/env bash\nexit 0\n' > "$root/bin/sleep"
chmod +x "$root/bin"/*
# blk <env assignments...> -- <group>...: runs the cut-out loop with those groups; rc in $rc, output in $root/run
blk() {
    local envs=()
    while [[ "$1" != -- ]]; do envs+=("$1"); shift; done; shift
    : > "$root/calls"; rm -f "$root/count"; : > "$root/missing"
    env "${envs[@]}" CALLS="$root/calls" COUNT="$root/count" LOOP="$root/loop.sh" MISSING="$root/missing" PATH="$root/bin:$PATH" \
        bash -c 'missing_file=$MISSING; . "$LOOP"; install_optional_groups Fedora "$@"; check_session_packages' _ "$@" > "$root/run" 2>&1
    rc=$?
}
G1="misc:fish niri noctalia gum"
blk X=1 -- "$G1" "cockpit:cockpit cockpit-podman"
check "everything installs: one transaction per group, nothing missing, exit 0" bash -c "[ $rc = 0 ] && [ \$(grep -c '^dnf5 install' '$root/calls') = 2 ] && [ ! -s '$root/missing' ]"
blk FLAKY_ONCE=1 -- "$G1"
check "a group that fails once is retried as a WHOLE (the same transaction twice), not installed one by one, and nothing is listed as missing" bash -c "[ $rc = 0 ] && [ \$(grep -c 'install -y fish niri noctalia gum' '$root/calls') = 2 ] && ! grep -q 'install -y fish\$' '$root/calls' && [ ! -s '$root/missing' ]"
blk FAIL_PKGS=gum -- "$G1"
check "a package that never installs is listed as missing, the others are installed one by one, a soft package does not fail the build" bash -c "[ $rc = 0 ] && grep -qx gum '$root/missing' && ! grep -qx niri '$root/missing' && grep -q 'install -y niri\$' '$root/calls'"
blk FAIL_PKGS=niri -- "$G1"
check "a missing session package (niri) FAILS the build with a clear message" bash -c "[ $rc = 1 ] && grep -q 'session package niri is missing' '$root/run'"
blk FAIL_PKGS=noctalia -- "$G1"
check "a missing noctalia fails it too" bash -c "[ $rc = 1 ] && grep -q 'session package noctalia is missing' '$root/run'"
echo; echo "passed: $pass, failed: $failn"
[ "$failn" = 0 ]
