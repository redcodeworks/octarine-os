#!/usr/bin/env bash
# Tests for the image's just files as one assembled justfile (how ujust sees them on the image): it parses, and every public recipe has a description
# (the comment line directly above it). Which recipes exist is not asserted. The base files that build.sh renames are stubs here. Needs: bash, just, jq.
# Run: tests/just-recipes.sh
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
justdir="$here/system_files/usr/share/ublue-os/just"
dxdir="$here/variants/dx/system_files/usr/share/ublue-os/just"
root=$(mktemp -d)
trap 'rm -rf -- "$root"' EXIT
pass=0
failn=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { failn=$((failn + 1)); echo "FAIL $1"; sed 's/^/     /' "$root/out" 2>/dev/null; }
check() { local d=$1; shift; if "$@" >"$root/out" 2>&1; then ok "$d"; else bad "$d"; fi; }

mkdir -p "$root/just" "$root/own"
cp -- "$justdir"/*.just "$root/just/"
# the wrappers import the own recipe files (motd.just, update.just) by their image path: rewritten to the temp copy
cp -- "$here"/system_files/usr/share/octarine-os/just/*.just "$root/own/"
sed -i "s|/usr/share/octarine-os/just|$root/own|" "$root/just/00-default.just" "$root/just/10-update.just"
cat >"$root/just/00-default-base.just" <<'EOF2'
# stub of the base file build.sh renames
# stub
toggle-user-motd:
    @true
EOF2
cat >"$root/just/10-update-base.just" <<'EOF2'
# stub of the base file build.sh renames
alias upgrade := update
alias changelog := changelogs
alias auto-update := toggle-updates

# stub
changelogs:
    @true
EOF2
cat >"$root/just/30-distrobox-base.just" <<'EOF2'
# stub of the base file build.sh renames

# stub
distrobox-assemble:
    @true

# stub
setup-distrobox-app CONTAINER="prompt":
    @true
EOF2
# the base package builds /usr/share/ublue-os/justfile from the file names it ships, with this header
{
    echo 'set allow-duplicate-recipes := true'
    for f in 00-default 10-update 15-luks 30-distrobox 40-nvidia 50-akmods; do echo "import \"$root/just/$f.just\""; done
    echo "import? \"$root/just/60-custom.just\""
} >"$root/Justfile"
cp -- "$root/Justfile" "$root/Assembled"

summary() { just --justfile "$root/Assembled" --summary 2>/dev/null | tr ' ' '\n'; }
check "the assembled justfile parses" just --justfile "$root/Assembled" --summary

# every public recipe has a description
nodoc=$(just --justfile "$root/Assembled" --dump --dump-format json | jq -r '.recipes[] | select((.private | not) and ((.doc // "") == "")) | .name')
printf '%s\n' "$nodoc" >"$root/out"
check "every public recipe of the assembled justfile has a description" test -z "$nodoc"
nodoc=$(for f in "$dxdir"/*.just; do just --justfile "$f" --dump --dump-format json | jq -r '.recipes[] | select((.private | not) and ((.doc // "") == "")) | .name'; done)
printf '%s\n' "$nodoc" >"$root/out"
check "every public recipe of the dx variant file has a description" test -z "$nodoc"

echo
echo "$pass passed, $failn failed"
[ "$failn" = 0 ]
