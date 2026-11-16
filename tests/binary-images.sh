#!/usr/bin/env bash
# Tests for the consumption side of the prebuilt binaries (built from binaries/ in this repository): the Containerfile wiring, the
# lookup of the hash-tagged image (.github/scripts/binaries-lookup.sh: published and signed, missing, bad signature), the gate of
# the image build (latest-ref.sh), the layout check of a built image (binaries-layout.sh), the installer
# (build_files/install-binaries.sh). Workflow, Containerfile and Justfile text is not asserted: a build shows those errors itself.
# All with fake skopeo and cosign; nothing is pulled, built or booted. The build side is tests/binaries-build.sh.
# Needs: bash, git, python3 with PyYAML, awk. Run: tests/binary-images.sh
set -uo pipefail
export RETRY_DELAY=0  # retry.sh must not slow the failing-verification cases

here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
keys_doc=$here/docs/signing-keys.md   # the one place that names the keys document
root=$(mktemp -d)
trap 'rm -rf -- "$root"' EXIT
pass=0
failn=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { failn=$((failn + 1)); echo "FAIL $1"; [ -f "$root/out" ] && sed 's/^/     /' "$root/out"; [ -f "$root/run" ] && sed 's/^/     run: /' "$root/run"; }
check() { local d=$1; shift; if "$@" >"$root/out" 2>&1; then ok "$d"; else bad "$d"; fi; }
cf="$here/Containerfile"

# ---- stubs
bin="$root/bin"; mkdir -p "$bin"
cat >"$bin/skopeo" <<'F'
#!/usr/bin/env bash
echo "skopeo $*" >>"$LOG"
case "$1" in
    inspect)
        [ "${SKOPEO_READ:-0}" = 1 ] && { echo "dial tcp: i/o timeout" >&2; exit 1; }
        [ "${SKOPEO_FAIL:-0}" = 1 ] && { echo "manifest unknown" >&2; exit 1; }
        [ "${SKOPEO_EMPTY:-0}" = 1 ] && exit 0
        printf 'manifest of %s' "${@: -1}" ;;
    manifest-digest) printf 'sha256:%s\n' "$(sha256sum "$2" | sed 's/ .*//')" ;;
esac
F
cat >"$bin/cosign" <<'F'
#!/usr/bin/env bash
echo "cosign $*" >>"$LOG"
[ "${COSIGN_READ:-0}" = 1 ] && { echo "Error: GET https://ghcr.io: TLS handshake timeout" >&2; exit 1; }
[ "${COSIGN_RC:-0}" != 0 ] && echo "Error: no signatures found" >&2
exit "${COSIGN_RC:-0}"
F
chmod +x "$bin"/*
export LOG="$root/log"
IMG=ghcr.io/redcodeworks/octarine-binaries
H40=$(printf 'a%.0s' {1..40})
dg() { printf 'manifest of docker://%s:%s' "$1" "$2" | sha256sum | sed 's/ .*//'; }
echo key >"$root/cosign.pub"

# ---- binaries-lookup.sh: the hash tag exists and is signed, or not
look() { : >"$LOG"; : >"$root/gho"; env "$@" PATH="$bin:$PATH" COSIGN_KEY_FILE="$root/cosign.pub" GITHUB_OUTPUT="$root/gho" bash "$here/.github/scripts/binaries-lookup.sh" "$IMG" "$H40" >"$root/run" 2>&1; rc=$?; }
look X=1
check "lookup: published and signed: usable=true with the digest of the tag, signature verified with the repo key" bash -c "[ $rc = 0 ] && grep -qx 'usable=true' '$root/gho' && grep -qx 'digest=sha256:$(dg $IMG $H40)' '$root/gho' && grep -q 'unchanged, nothing to build' '$root/run' && grep -qF 'cosign verify --key $root/cosign.pub $IMG@sha256:$(dg $IMG $H40)' '$LOG'"
look SKOPEO_FAIL=1
check "lookup: tag missing: usable=false (reason missing), exit 0, no cosign call" bash -c "[ $rc = 0 ] && grep -qx 'usable=false' '$root/gho' && grep -qx 'reason=missing' '$root/gho' && ! grep -q cosign '$LOG'"
look SKOPEO_EMPTY=1
check "lookup: an empty answer counts as missing" bash -c "[ $rc = 0 ] && grep -qx 'usable=false' '$root/gho'"
look SKOPEO_READ=1
check "lookup: a registry that cannot be read is reason=unreadable (a warning that says so), never 'missing'; exit 0, no cosign call, the leg builds" bash -c "[ $rc = 0 ] && grep -qx 'usable=false' '$root/gho' && grep -qx 'reason=unreadable' '$root/gho' && ! grep -qx 'reason=missing' '$root/gho' && ! grep -q cosign '$LOG' && grep -q 'registry read error' '$root/run'"
look COSIGN_READ=1
check "lookup: a cosign check that cannot complete is reason=unreadable, never 'badsignature'" bash -c "[ $rc = 0 ] && grep -qx 'reason=unreadable' '$root/gho' && ! grep -qx 'reason=badsignature' '$root/gho'"
look COSIGN_RC=1
check "lookup: the tag exists but the signature does not verify: usable=false (reason badsignature), a warning, rebuild" bash -c "[ $rc = 0 ] && grep -qx 'usable=false' '$root/gho' && grep -qx 'reason=badsignature' '$root/gho' && grep -q '::warning::' '$root/run'"
PATH="$bin:$PATH" bash "$here/.github/scripts/binaries-lookup.sh" "$IMG" 'Bad Tag!' >"$root/run" 2>&1
check "lookup: a tag that is not a content tag is refused" test "$?" != 0

# ---- latest-ref.sh: the gate of the image build (octarine-binaries and dev-packages float at latest)
use() { : >"$LOG"; : >"$root/genv"; env "$@" PATH="$bin:$PATH" GITHUB_ENV="$root/genv" bash "$here/.github/scripts/latest-ref.sh" "$IMG" "$root/cosign.pub" BINARIES_IMAGE >"$root/run" 2>&1; rc=$?; }
D=sha256:$(dg "$IMG" latest)
use X=1
check "use: latest is resolved to a digest, verified with the key and exported as BINARIES_IMAGE=<image>@<digest>" bash -c "[ $rc = 0 ] && grep -qx 'BINARIES_IMAGE=$IMG@$D' '$root/genv' && grep -q 'cosign verify --key $root/cosign.pub $IMG@$D' '$LOG'"
use COSIGN_RC=1
check "use: a digest that does not verify fails the build and exports nothing" bash -c "[ $rc != 0 ] && [ ! -s '$root/genv' ]"
use SKOPEO_FAIL=1
check "use: a missing latest fails and exports nothing" bash -c "[ $rc != 0 ] && [ ! -s '$root/genv' ] && ! grep -q cosign '$LOG'"
use SKOPEO_READ=1
check "use: an unreadable registry fails and exports nothing" bash -c "[ $rc != 0 ] && [ ! -s '$root/genv' ]"

# ---- binaries-layout.sh: the listing of a built image against the manifest, per component
lay="$root/lay"; mkdir -p "$lay"
tsvf="$here/binaries/scx/schedulers.tsv"
{ for n in $(grep -vE '^[[:space:]]*(#|$)' "$tsvf" | cut -f1); do echo "scx/bin/$n"; done
  printf '%s\n' scx/schedulers.tsv extest/lib/libextest.so extest/lib64/libextest.so scx/SOURCE scx/BUILDINFO extest/SOURCE extest/BUILDINFO scx/LICENSES/scx-LICENSE extest/LICENSES/extest-LICENSE; } >"$lay/comps"
{ cat "$lay/comps"; printf '%s\n' SOURCE BUILDINFO COMPONENTS LICENSES/scx-LICENSE; } >"$lay/full"
L="$here/.github/scripts/binaries-layout.sh"
lt() { bash "$L" "$@" >"$root/run" 2>&1; rc=$?; }
lt "$lay/comps" "$tsvf" scx extest
check "layout: complete component directories pass, for all seven schedulers of the real manifest" test "$rc" = 0
grep -v '^extest/' "$lay/comps" >"$lay/scxonly"
lt "$lay/scxonly" "$tsvf" scx
check "layout: a single component image (what a component build exports) passes with its own name" test "$rc" = 0
lt "$lay/scxonly" "$tsvf" scx extest
check "layout: naming a component the image does not hold fails" test "$rc" != 0
lt --assembled "$lay/full" "$tsvf" scx extest
check "layout: the assembled image passes with top-level SOURCE, BUILDINFO, LICENSES and COMPONENTS" test "$rc" = 0
grep -v '^COMPONENTS$' "$lay/full" >"$lay/nocomp"
lt --assembled "$lay/nocomp" "$tsvf" scx extest
check "layout: the assembled image without COMPONENTS fails" test "$rc" != 0
{ cat "$lay/full"; echo ghostty/bin/ghostty; } >"$lay/surplus"
lt --assembled "$lay/surplus" "$tsvf" scx extest
check "layout: an assembled image with an unexpected top-level directory fails and names it" bash -c "[ $rc != 0 ] && grep -q 'unexpected top-level entries: ghostty' '$root/run'"
grep -v 'scx/bin/scx_cake' "$lay/comps" >"$lay/nocake"
lt "$lay/nocake" "$tsvf" scx extest
check "layout: a scheduler of the manifest missing from the image fails and is named" bash -c "[ $rc != 0 ] && grep -q 'lacks scx/bin/scx_cake' '$root/run'"
grep -v 'extest/lib/libextest.so' "$lay/comps" >"$lay/no32"
lt "$lay/no32" "$tsvf" scx extest
check "layout: a missing 32-bit library fails" test "$rc" != 0
grep -vE '^(extest/SOURCE|scx/BUILDINFO)' "$lay/comps" >"$lay/norec"
lt "$lay/norec" "$tsvf" scx extest
check "layout: missing SOURCE or BUILDINFO of a component fails" test "$rc" != 0
sed 's#^#./#' "$lay/comps" >"$lay/dotted"
lt "$lay/dotted" "$tsvf" scx extest
check "layout: tar listings with a leading ./ are accepted" test "$rc" = 0
{ printf '%s\n' ghostty/root/usr/bin/ghostty ghostty/root/usr/share/applications/com.mitchellh.ghostty.desktop ghostty/FILES ghostty/SOURCE ghostty/BUILDINFO ghostty/LICENSES/ghostty-LICENSE; for i in $(seq 1 6000); do echo "ghostty/root/usr/share/ghostty/themes/theme-$i"; done; } >"$lay/big"
lt "$lay/big" "$tsvf" ghostty
check "layout: a long listing (6000 files, the needed ones first) passes: no SIGPIPE of the normalizing sed under pipefail makes a present file look missing" test "$rc" = 0
grep -v 'ghostty/FILES' "$lay/big" >"$lay/bigmiss"
lt "$lay/bigmiss" "$tsvf" ghostty
check "layout: in a long listing a really missing file is still reported" bash -c "[ $rc != 0 ] && grep -q 'lacks ghostty/FILES' '$root/run'"
lt "$lay/comps" "$tsvf" nosuch
check "layout: an unknown component name is refused" test "$rc" != 0




# ---- install-binaries.sh against a fake binaries image
mk_images() { # dir
    rm -rf "$1"; mkdir -p "$1/scx/bin" "$1/scx/LICENSES" "$1/extest/lib" "$1/extest/lib64" "$1/extest/LICENSES"
    for n in scx_rusty scx_cake; do printf '#!/bin/sh\necho %s 1.1.4\n' "$n" >"$1/scx/bin/$n"; done
    # the third field (minimum kernel) is empty on purpose
    printf 'scx_rusty\tbin/scx_rusty\t\tHybrid scheduler\nscx_cake\tbin/scx_cake\t\tGaming scheduler\n' >"$1/scx/schedulers.tsv"
    printf '                    GNU GENERAL PUBLIC LICENSE\n' >"$1/scx/LICENSES/scx-LICENSE"
    printf 'MIT License\n' >"$1/extest/LICENSES/extest-LICENSE"
    echo 32 >"$1/extest/lib/libextest.so"; echo 64 >"$1/extest/lib64/libextest.so"
    for i in scx extest; do echo src >"$1/$i/SOURCE"; echo build >"$1/$i/BUILDINFO"; done
    mkdir -p "$1/ghostty/root/usr/bin" "$1/ghostty/LICENSES"; printf '#!/bin/sh\n' >"$1/ghostty/root/usr/bin/ghostty"; chmod +x "$1/ghostty/root/usr/bin/ghostty"
    echo usr/bin/ghostty >"$1/ghostty/FILES"; echo MIT >"$1/ghostty/LICENSES/ghostty-LICENSE"; echo src >"$1/ghostty/SOURCE"; echo build >"$1/ghostty/BUILDINFO"
    printf 'scx\t%s\tbuilt\tsha256:%s\nextest\t%s\treused\tsha256:%s\nghostty\t%s\tbuilt\tsha256:%s\n' "$H40" "$(printf 'a%.0s' {1..64})" "$H40" "$(printf 'b%.0s' {1..64})" "$H40" "$(printf 'c%.0s' {1..64})" >"$1/COMPONENTS"
}
imgs="$root/imgs"; dest="$root/dest"
inst() { rm -rf "$dest"; (BINARIES_ROOT="$imgs" DESTDIR="$dest" bash "$here/build_files/install-binaries.sh") >"$root/run" 2>&1; rc=$?; }
mk_images "$imgs"; inst
check "install: schedulers in /usr/bin, executable" bash -c "[ $rc = 0 ] && test -x '$dest/usr/bin/scx_rusty' && test -x '$dest/usr/bin/scx_cake'"
check "install: manifest at /usr/share/octarine-os/schedulers.tsv, unchanged" cmp "$imgs/scx/schedulers.tsv" "$dest/usr/share/octarine-os/schedulers.tsv"
check "install: extest libraries under /usr/lib/extest/lib and lib64, executable, not swapped" bash -c "[ \"\$(cat '$dest/usr/lib/extest/lib/libextest.so')\" = 32 ] && [ \"\$(cat '$dest/usr/lib/extest/lib64/libextest.so')\" = 64 ] && test -x '$dest/usr/lib/extest/lib/libextest.so'"
check "install: licenses, source and build info under /usr/share/licenses/octarine-binaries/<name>" bash -c "d='$dest/usr/share/licenses/octarine-binaries'; test -s \$d/scx/scx-LICENSE && test -s \$d/scx/SOURCE && test -s \$d/scx/BUILDINFO && test -s \$d/extest/extest-LICENSE && test -s \$d/extest/SOURCE && test -s \$d/extest/BUILDINFO"
check "install: nothing under systemd paths" bash -c "! find '$dest' -path '*systemd*' | grep -q ."
mk_images "$imgs"; rm "$imgs/scx/bin/scx_cake"; inst
check "install: a scheduler listed but missing fails" bash -c "[ $rc != 0 ] && grep -q 'scx_cake is listed in schedulers.tsv but missing' '$root/run'"
mk_images "$imgs"; echo '#!/bin/sh' >"$imgs/scx/bin/scx_extra"; inst
check "install: a binary that is not in the manifest fails" bash -c "[ $rc != 0 ] && grep -q 'scx_extra is not listed' '$root/run'"
mk_images "$imgs"; printf 'scx_rusty\tbin/scx_rusty\tHybrid scheduler\n' >"$imgs/scx/schedulers.tsv"; inst
check "install: a manifest line with three fields (the empty one collapsed) fails" bash -c "[ $rc != 0 ] && grep -q 'must be name, bin/name' '$root/run'"
mk_images "$imgs"; rm "$imgs/scx/LICENSES/scx-LICENSE"; inst
check "install: no GPL text fails" bash -c "[ $rc != 0 ] && grep -q 'no GPL text' '$root/run'"
mk_images "$imgs"; rm "$imgs/extest/LICENSES/extest-LICENSE"; inst
check "install: no MIT text fails" bash -c "[ $rc != 0 ] && grep -q 'no MIT text' '$root/run'"
mk_images "$imgs"; rm "$imgs/extest/lib/libextest.so"; inst
check "install: a missing 32-bit library fails" test "$rc" != 0


echo
echo "passed: $pass, failed: $failn"
[ "$failn" = 0 ]
