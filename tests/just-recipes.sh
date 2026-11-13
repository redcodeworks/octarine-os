#!/usr/bin/env bash
# Tests for the image's just files as one assembled justfile (how ujust sees them on the image): every public recipe has a
# description (the comment line directly above it), the new recipes are listed, and the base recipes the image removes or
# hides (toggle-nvk, the two LUKS names, setup-distrobox-app, configure-broadcom-wl) are not. The base files that build.sh
# renames (10-update-base, 30-distrobox-base) are stubs here. Needs: bash, just, jq. Run: tests/just-recipes.sh
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

mkdir -p "$root/just"
cp -- "$justdir"/*.just "$root/just/"
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
    for f in 10-update 15-luks 30-distrobox 40-nvidia 50-akmods; do echo "import \"$root/just/$f.just\""; done
    echo "import? \"$root/just/60-custom.just\""
} >"$root/Justfile"
cp -- "$root/Justfile" "$root/Assembled"

summary() { just --justfile "$root/Assembled" --summary 2>/dev/null | tr ' ' '\n'; }
check "the assembled justfile parses" just --justfile "$root/Assembled" --summary
for r in switch-image toggle-updates update luks-tpm-unlock toolbox user-setup niri-setup gaming-setup gnome-candy flatpak-preinstall; do
    check "$r is listed" bash -c "$(declare -f summary); root='$root'; summary | grep -qx '$r'"
done
for r in toggle-nvk setup-luks-tpm-unlock remove-luks-tpm-unlock setup-distrobox-app configure-broadcom-wl broadcom-wl; do
    check "$r is not listed" bash -c "$(declare -f summary); root='$root'; ! summary | grep -qx '$r'"
done
check "our 40-nvidia.just, 15-luks.just and 50-akmods.just define no recipe or alias (they only replace the base files)" bash -c "! grep -qE '^(alias |[a-z@\\[])' '$justdir/40-nvidia.just' '$justdir/15-luks.just' '$justdir/50-akmods.just'"
check "the base's toggle-nvk cannot return: no recipe of that name in any file we ship" bash -c "! grep -rqE '^toggle-nvk' '$justdir' '$dxdir'"
for f in 15-luks 40-nvidia 50-akmods; do
    check "$f.just keeps the base file name (build.sh's copy overwrites the base file)" test -f "$justdir/$f.just"
done

# every public recipe has a description
nodoc=$(just --justfile "$root/Assembled" --dump --dump-format json | jq -r '.recipes[] | select((.private | not) and ((.doc // "") == "")) | .name')
printf '%s\n' "$nodoc" >"$root/out"
check "every public recipe of the assembled justfile has a description" test -z "$nodoc"
nodoc=$(just --justfile "$dxdir/70-octarine-dev.just" --dump --dump-format json | jq -r '.recipes[] | select((.private | not) and ((.doc // "") == "")) | .name')
printf '%s\n' "$nodoc" >"$root/out"
check "every public recipe of the dx variant file has a description" test -z "$nodoc"
check "toolbox keeps its description" bash -c "just --justfile '$root/Assembled' --list 2>&1 | grep -E '^ +toolbox ' | grep -q 'Create and manage toolboxes'"

echo
echo "$pass passed, $failn failed"
[ "$failn" = 0 ]
