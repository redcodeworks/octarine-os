#!/usr/bin/env bash
# Behavior of the DX_IMAGE_ID part of variants/dx/dx.sh (one shared dx layer, two image ids: the block is cut out and run on a scratch os-release).
# The workflow shape, the CDI text and the input lists are not asserted (a wrong one fails the build). Run: tests/nvidia-dx-image.sh
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
root=$(mktemp -d)
trap 'rm -rf -- "$root"' EXIT
pass=0
failn=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { failn=$((failn + 1)); echo "FAIL $1"; [ -f "$root/out" ] && sed 's/^/     /' "$root/out" | tail -20; }
check() { local d=$1; shift; if "$@" >"$root/out" 2>&1; then ok "$d"; else bad "$d"; fi; }

# ---- the os-release identity part of dx.sh (the same layer, two IMAGE_IDs)
idblock="$root/idblock.sh"
{
    echo 'set -euo pipefail'
    sed -n '/^set_os_release_field() {/,/^}/p' "$here/variants/dx/dx.sh"
    sed -n '/^: "\${IMAGE_VERSION/,/IMAGE_ID_EXPECTED=/p' "$here/variants/dx/dx.sh" | sed "s#/usr/lib/os-release#$root/os-release#"
} >"$idblock"
mkid() { printf 'ID=fedora\nIMAGE_ID="octarine-os"\nIMAGE_VERSION="old"\n' >"$root/os-release"; }
mkid; IMAGE_VERSION=20261110-abc1234 OS_RELEASE_FILE="$root/os-release" bash "$idblock" >"$root/out" 2>&1; rc=$?
check "dx.sh: without DX_IMAGE_ID the image id is octarine-os-dx" bash -c "[ $rc = 0 ] && grep -qx 'IMAGE_ID=\"octarine-os-dx\"' '$root/os-release' && grep -qx 'IMAGE_VERSION=\"20261110-abc1234\"' '$root/os-release'"
mkid; DX_IMAGE_ID=octarine-os-nvidia-dx IMAGE_VERSION=20261110-abc1234 OS_RELEASE_FILE="$root/os-release" bash "$idblock" >"$root/out" 2>&1; rc=$?
check "dx.sh: DX_IMAGE_ID=octarine-os-nvidia-dx sets that image id" bash -c "[ $rc = 0 ] && grep -qx 'IMAGE_ID=\"octarine-os-nvidia-dx\"' '$root/os-release'"
mkid; DX_IMAGE_ID='octarine-os' IMAGE_VERSION=20261110-abc1234 OS_RELEASE_FILE="$root/os-release" bash "$idblock" >"$root/id.out" 2>&1; rc=$?
check "dx.sh: any other DX_IMAGE_ID is refused" bash -c "[ $rc != 0 ] && grep -q 'is not octarine-os-dx or octarine-os-nvidia-dx' '$root/id.out'"

# ---- the NVIDIA variant brings what a container needs for CDI (unverified on a real build; failing is a warning)

# ---- the dx-only inputs

echo
echo "passed: $pass, failed: $failn"
[ "$failn" -eq 0 ]
