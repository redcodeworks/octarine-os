#!/usr/bin/env bash
# Runs the REAL build_files/install-binaries.sh against a small fixture in the documented octarine-bins layout. The writer of that layout is another
# repository (octarine-bins builds the image; the contract is mirrored in its CLAUDE.md, section "The image layout"): /binaries/<name>/ per component,
# COMPONENTS (names, one per line), LICENSES/, SOURCE and BUILDINFO, scx/schedulers.tsv (four tab separated fields), ghostty/FILES. The fixture lives here,
# so a layout change in octarine-bins must be accepted by the installer first (reader first) and this fixture then follows it.
# Needs: bash, awk, tar. Run: tests/install-binaries.sh
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
root=$(mktemp -d)
trap 'rm -rf -- "${root:?}"' EXIT
pass=0; failn=0; rc=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { failn=$((failn + 1)); echo "FAIL $1"; sed 's/^/     /' "$root/run" 2> /dev/null; echo "     rc=$rc"; }
check() { local d=$1; shift; if "$@" > "$root/out" 2>&1; then ok "$d"; else bad "$d"; fi; }

mk_image() { # dir
    rm -rf "${1:?}"; mkdir -p "$1/scx/bin" "$1/scx/LICENSES" "$1/extest/lib" "$1/extest/lib64" "$1/extest/LICENSES" "$1/ghostty/root/usr/bin" "$1/ghostty/root/usr/share/terminfo/x" "$1/ghostty/LICENSES" "$1/LICENSES"
    for n in scx_rusty scx_cake; do printf '#!/bin/sh\necho %s\n' "$n" > "$1/scx/bin/$n"; done
    printf 'scx_rusty\tbin/scx_rusty\t\tHybrid scheduler\nscx_cake\tbin/scx_cake\t\tGaming scheduler\n' > "$1/scx/schedulers.tsv"   # minimum kernel empty on purpose
    printf '                    GNU GENERAL PUBLIC LICENSE\n' > "$1/scx/LICENSES/scx-LICENSE"
    printf 'MIT License\n' > "$1/extest/LICENSES/extest-LICENSE"
    echo 32 > "$1/extest/lib/libextest.so"; echo 64 > "$1/extest/lib64/libextest.so"
    printf '#!/bin/sh\n' > "$1/ghostty/root/usr/bin/ghostty"; chmod +x "$1/ghostty/root/usr/bin/ghostty"
    echo term > "$1/ghostty/root/usr/share/terminfo/x/xterm-ghostty"
    printf 'usr/bin/ghostty\nusr/share/terminfo/x/xterm-ghostty\n' > "$1/ghostty/FILES"; echo MIT > "$1/ghostty/LICENSES/ghostty-LICENSE"
    for c in scx extest ghostty; do echo src > "$1/$c/SOURCE"; echo build > "$1/$c/BUILDINFO"; done
    printf 'scx\nextest\nghostty\n' > "$1/COMPONENTS"; cp "$1/scx/LICENSES/scx-LICENSE" "$1/LICENSES/"; echo src > "$1/SOURCE"; echo build > "$1/BUILDINFO"
}
img="$root/img"; dest="$root/dest"
inst() { rm -rf "$dest"; mkdir -p "$dest/usr/share/terminfo/x"; echo base > "$dest/usr/share/terminfo/x/xterm-ghostty"; (BINARIES_ROOT="$img" DESTDIR="$dest" bash "$here/build_files/install-binaries.sh") > "$root/run" 2>&1; rc=$?; }

mk_image "$img"; inst
check "the documented layout installs: schedulers in /usr/bin, the manifest, extest, ghostty, the license texts" bash -c "[ $rc = 0 ] && test -x '$dest/usr/bin/scx_rusty' && test -x '$dest/usr/bin/scx_cake' && test -s '$dest/usr/share/octarine-os/schedulers.tsv' && test -f '$dest/usr/lib/extest/lib64/libextest.so' && test -x '$dest/usr/bin/ghostty' && grep -rqF 'GNU GENERAL PUBLIC LICENSE' '$dest/usr/share/licenses/octarine-binaries/scx' && grep -rqF 'MIT License' '$dest/usr/share/licenses/octarine-binaries/extest'"
check "the image's own terminfo file is kept, not overwritten" grep -qx base "$dest/usr/share/terminfo/x/xterm-ghostty"
mk_image "$img"; printf 'scx_rusty\tbin/scx_rusty\tHybrid scheduler\n' > "$img/scx/schedulers.tsv"; inst
check "a manifest line with three fields fails" bash -c "[ $rc != 0 ] && grep -q 'must be name, bin/name' '$root/run'"
mk_image "$img"; printf 'scx\nextest\n' > "$img/COMPONENTS"; inst
check "a required component missing from COMPONENTS fails" bash -c "[ $rc != 0 ]"
mk_image "$img"; printf 'scx\nextest\nghostty\nnewthing\n' > "$img/COMPONENTS"; mkdir "$img/newthing"; inst
check "a component the installer does not know fails (reader first)" bash -c "[ $rc != 0 ] && grep -q 'does not know' '$root/run'"
mk_image "$img"; mkdir -p "$dest"; echo x > "$img/scx/bin/scx_unlisted"; inst
check "a scheduler file the manifest does not list fails" bash -c "[ $rc != 0 ] && grep -q 'not listed' '$root/run'"
mk_image "$img"; echo usr/bin/bash >> "$img/ghostty/FILES"; mkdir -p "$img/ghostty/root/usr/bin"; echo x > "$img/ghostty/root/usr/bin/bash"
rm -rf "$dest"; mkdir -p "$dest/usr/bin"; echo base > "$dest/usr/bin/bash"; (BINARIES_ROOT="$img" DESTDIR="$dest" bash "$here/build_files/install-binaries.sh") > "$root/run" 2>&1; rc=$?
check "a ghostty file that would overwrite a file of the image fails" bash -c "[ $rc != 0 ] && grep -q 'would overwrite' '$root/run'"

echo; echo "passed: $pass, failed: $failn"
[ "$failn" = 0 ]
