#!/usr/bin/env bash
# Tests for what the binaries pipeline decides without a fallback: the decision of one component (binaries-decide.sh), the decision of the
# assemble job (binaries-assemble.sh) and the content keys that make signed component images reusable (binaries-key.sh), the wiring in
# build.yml, the plan-skip rule for an image that left an optional component out, the installer's MISSING and REMOVED records and its
# runtime library check. Nothing is pulled or built. Run: tests/binaries-decide.sh
# Needs: bash, git, python3 with PyYAML, jq, tar, readelf.
# shellcheck disable=SC2016
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
root=$(mktemp -d)
trap 'rm -rf -- "$root"' EXIT
pass=0; failn=0; rc=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { failn=$((failn + 1)); echo "FAIL $1"; [ -f "$root/run" ] && sed 's/^/     run: /' "$root/run"; }
check() { local d=$1; shift; if "$@" >"$root/out" 2>&1; then ok "$d"; else bad "$d"; fi; }
H40=$(printf 'b%.0s' {1..40})
bin="$root/bin"; mkdir -p "$bin"

# ---- fixture: an exported component image that satisfies this tree's installer (real scheduler names from the real manifest)
mkfix() { # dir component
    local d=$1 c=$2 n
    rm -rf "$d"; mkdir -p "$d/$c/LICENSES"
    if [ "$c" = scx ]; then
        mkdir -p "$d/scx/bin"; : >"$d/scx/schedulers.tsv"
        for n in $(grep -vE '^[[:space:]]*(#|$)' "$here/binaries/scx/schedulers.tsv" | cut -f1); do
            printf '#!/bin/sh\n' >"$d/scx/bin/$n"; chmod +x "$d/scx/bin/$n"
            printf '%s\tbin/%s\t\tdescription\n' "$n" "$n" >>"$d/scx/schedulers.tsv"
        done
        printf '                    GNU GENERAL PUBLIC LICENSE\n' >"$d/scx/LICENSES/scx-LICENSE"
    else
        mkdir -p "$d/extest/lib" "$d/extest/lib64"
        printf 'MIT License\n' >"$d/extest/LICENSES/extest-LICENSE"
        echo 32 >"$d/extest/lib/libextest.so"; echo 64 >"$d/extest/lib64/libextest.so"
    fi
    echo src >"$d/$c/SOURCE"; echo build >"$d/$c/BUILDINFO"
}

# ---- the decision of ONE component: binaries-decide.sh, with each combination
dec() { rm -rf "$root/res"; : >"$root/gho"; : >"$root/sum"; env COMPONENT=scx OPTIONAL=false CHECK=success USABLE=false CHECK_DIGEST= KEY=$H40 BUILD=success BUILD_OK=true PUBLISHED=true SIGN=success SIGN_DIGEST=sha256:$(printf '5%.0s' {1..64}) KNOWN_FAIL= RESULT_DIR="$root/res" "$@" GITHUB_OUTPUT="$root/gho" GITHUB_STEP_SUMMARY="$root/sum" bash "$here/.github/scripts/binaries-decide.sh" >"$root/run" 2>&1; rc=$?; }
sgd=sha256:$(printf '5%.0s' {1..64})
dec
check "decision: built, published and signed: status built with the signed digest and the key" bash -c "[ $rc = 0 ] && grep -qx 'status=built' '$root/gho' && grep -qx 'digest=$sgd' '$root/gho' && grep -qx 'key=$H40' '$root/gho'"
dec USABLE=true CHECK_DIGEST=sha256:$(printf '1%.0s' {1..64}) BUILD=success BUILD_OK=
check "decision: a signed image of this key existed: status reused with its digest" bash -c "[ $rc = 0 ] && grep -qx 'status=reused' '$root/gho' && grep -qx 'digest=sha256:$(printf '1%.0s' {1..64})' '$root/gho'"
dec PUBLISHED=false SIGN=skipped
check "decision: built on a ref that cannot publish: status validated, no digest" bash -c "[ $rc = 0 ] && grep -qx 'status=validated' '$root/gho' && grep -qx 'digest=' '$root/gho'"
dec BUILD_OK=true SIGN=failure
check "decision: signing failed: fails" bash -c "[ $rc = 1 ] && grep -q 'signing the scx image failed' '$root/run' && grep -qP '\tfailed\t' '$root/res/scx.tsv'"
dec BUILD_OK=false SIGN=skipped
check "decision: a REQUIRED component whose build failed FAILS (no older image is used instead)" bash -c "[ $rc = 1 ] && grep -qx 'status=failed' '$root/gho' && grep -q 'component is required' '$root/run'"
dec BUILD_OK=false SIGN=skipped OPTIONAL=true COMPONENT=ghostty
check "decision: an OPTIONAL component whose build failed: status absent, exit 0 (left out of the image), a warning and a summary line" bash -c "[ $rc = 0 ] && grep -qx 'status=absent' '$root/gho' && grep -q '^::warning::OMITTED: optional component ghostty' '$root/run' && grep -q OMITTED '$root/sum'"
dec OPTIONAL=true KNOWN_FAIL=true BUILD=skipped COMPONENT=ghostty
check "decision: a known failure of this key (optional): absent, exit 0, a loud warning that names the key and says when it is tried again" bash -c "[ $rc = 0 ] && grep -qx 'status=absent' '$root/gho' && grep -q 'failed to build before' '$root/run' && grep -q 'daily run on main' '$root/run'"
dec CHECK=failure BUILD=skipped
check "decision: a failed lookup fails closed" bash -c "[ $rc = 1 ] && grep -q 'lookup of the scx image failed' '$root/run'"
dec BUILD=failure BUILD_OK=
check "decision: the build JOB itself failing (not just its steps) fails" bash -c "[ $rc = 1 ]"

# ---- the decision of the assemble job: binaries-assemble.sh and the keys
mkdir -p "$root/res2"
printf 'scx\trequired\nextest\trequired\nghostty\toptional\n' >"$root/comps.tsv"
D1=sha256:$(printf '1%.0s' {1..64}); D2=sha256:$(printf '2%.0s' {1..64}); D3=sha256:$(printf '3%.0s' {1..64})
K1=$(printf '1%.0s' {1..40}); K2=$(printf '2%.0s' {1..40}); K3=$(printf '3%.0s' {1..40})
res() { printf '%s\t%s\t%s\t%s\t\n' "$1" "$2" "$3" "$4" >"$root/res2/$1.tsv"; }
asm() { : >"$root/gho"; env GITHUB_OUTPUT="$root/gho" bash "$here/.github/scripts/binaries-assemble.sh" "$root/comps.tsv" "$root/res2" "$root/out2" >"$root/run" 2>&1; rc=$?; }
rm -f "$root/res2"/*; res scx built $D1 $K1 ""; res extest reused $D2 $K2 ""; res ghostty built $D3 $K3 ""
asm
check "assemble: every component built or reused: action assemble, three components, nothing degraded" bash -c "[ $rc = 0 ] && grep -qx 'action=assemble' '$root/gho' && grep -qx 'degraded=' '$root/gho' && [ \$(wc -l < '$root/out2/COMPONENTS') = 3 ]"
key3=$(grep '^key=' "$root/gho" | cut -d= -f2)
check "assemble: the assembled key is binaries-key.sh --assembled over the included name=key pairs, order independent, and differs when a key differs" bash -c "[ '$key3' = \"\$('$here/.github/scripts/binaries-key.sh' --assembled ghostty=$K3 scx=$K1 extest=$K2)\" ] && [ '$key3' != \"\$('$here/.github/scripts/binaries-key.sh' --assembled scx=$K1 extest=$K2 ghostty=$K1)\" ] && [[ '$key3' =~ ^[0-9a-f]{40}\$ ]]"
res ghostty absent "" "" ""; asm
check "assemble: an optional component left out: still assemble, degraded=ghostty:absent, no line for it in COMPONENTS, and a different key than with it" bash -c "[ $rc = 0 ] && grep -qx 'degraded=ghostty:absent' '$root/gho' && [ \$(wc -l < '$root/out2/COMPONENTS') = 2 ] && ! grep -q ghostty '$root/out2/COMPONENTS' && ! grep -qx 'key=$key3' '$root/gho'"
rm "$root/res2/ghostty.tsv"; asm
check "assemble: an optional component without any result line (its leg did not finish) counts as absent" bash -c "[ $rc = 0 ] && grep -qx 'degraded=ghostty:absent' '$root/gho'"
res scx failed "" "" ""; asm
check "assemble: a required component that failed: action failed, exit 1" bash -c "[ $rc = 1 ] && grep -qx 'action=failed' '$root/gho'"
res scx built $D1 $K1 ""; rm "$root/res2/extest.tsv"; asm
check "assemble: a required component without a result line fails" bash -c "[ $rc = 1 ] && grep -q 'extest (required) has no result line' '$root/run'"
res extest absent "" "" ""; asm
check "assemble: a required component that is absent fails" bash -c "[ $rc = 1 ]"
res extest reused $D2 $K2 ""; res ghostty validated "" "$K3" ""; asm
check "assemble: a component built only for validation: action validated (nothing is assembled or published), no key" bash -c "[ $rc = 0 ] && grep -qx 'action=validated' '$root/gho' && grep -qx 'key=' '$root/gho'"
res ghostty built "sha256:short" $K3 ""; asm
check "assemble: a result with a malformed digest is refused" bash -c "[ $rc = 1 ]"

# ---- binaries-key.sh in a scratch repository: only the changed component's key moves, lib/ and the builder move all
kr="$root/keyrepo"; mkdir -p "$kr/binaries/scx" "$kr/binaries/extest" "$kr/binaries/lib" "$kr/.github/scripts"
cp "$here/.github/scripts/binaries-key.sh" "$kr/.github/scripts/"
printf 'scx\trequired\nextest\trequired\n' >"$kr/binaries/components.tsv"
echo a >"$kr/binaries/scx/f"; echo b >"$kr/binaries/extest/f"; echo c >"$kr/binaries/lib/f"; echo BUILDER=x >"$kr/binaries/builder.env"
git -C "$kr" init -q -b main; git -C "$kr" add -A; git -C "$kr" -c user.name=t -c user.email=t@e.invalid commit -q -m 1
K() { REPO_ROOT="$kr" bash "$kr/.github/scripts/binaries-key.sh" "$@"; }
s0=$(K scx); e0=$(K extest); a0=$(K)
echo a2 >"$kr/binaries/scx/f"; git -C "$kr" add -A; git -C "$kr" -c user.name=t -c user.email=t@e.invalid commit -q -m 2
check "key: a change inside scx moves the key of scx and the assembled key, and NOT the key of extest" bash -c "[ '$(K scx)' != '$s0' ] && [ '$(K extest)' = '$e0' ] && [ '$(K)' != '$a0' ]"
s1=$(K scx); echo c2 >"$kr/binaries/lib/f"; git -C "$kr" add -A; git -C "$kr" -c user.name=t -c user.email=t@e.invalid commit -q -m 3
check "key: a change in lib/ moves the key of every component" bash -c "[ '$(K scx)' != '$s1' ] && [ '$(K extest)' != '$e0' ]"
s2=$(K scx); e2=$(K extest); echo BUILDER=y >"$kr/binaries/builder.env"; git -C "$kr" add -A; git -C "$kr" -c user.name=t -c user.email=t@e.invalid commit -q -m 4
check "key: a new builder pin moves the key of every component" bash -c "[ '$(K scx)' != '$s2' ] && [ '$(K extest)' != '$e2' ]"
check "key: keys are 40 hex, the components list is the manifest, a bad name is refused" bash -c "[[ '$(K scx)' =~ ^[0-9a-f]{40}\$ ]] && [ \"\$(REPO_ROOT='$kr' bash '$kr/.github/scripts/binaries-key.sh' --components | tr '\n' ' ')\" = 'scx extest ' ] && ! REPO_ROOT='$kr' bash '$kr/.github/scripts/binaries-key.sh' 'Bad Name' 2>/dev/null"

# ---- plan-skip: an image that left an optional component out is never kept
out1=$(env EVENT=schedule REF=refs/heads/main BASE_NOW=sha256:a LATEST_BASE=sha256:a REPO_SAME=true LATEST_CREATED="$(date -u +%Y-%m-%dT%H:%M:%SZ)" SIGNED=true LATEST_DEGRADED= bash "$here/.github/scripts/plan-skip.sh")
out2=$(env EVENT=schedule REF=refs/heads/main BASE_NOW=sha256:a LATEST_BASE=sha256:a REPO_SAME=true LATEST_CREATED="$(date -u +%Y-%m-%dT%H:%M:%SZ)" SIGNED=true LATEST_DEGRADED=ghostty:absent bash "$here/.github/scripts/plan-skip.sh")
check "plan-skip: unchanged inputs and no degraded label: skipped; with the degraded label: build (the next daily run tries the component again)" bash -c "[[ '$out1' == skipped* && '$out2' == build:*ghostty:absent* ]]"

# ---- the installer: COMPONENTS, MISSING for an absent optional component, the runtime library check
mkghostty() { # dir: a staged ghostty component (root/usr tree, FILES, LICENSES, SOURCE, BUILDINFO)
    local g=$1/ghostty
    mkdir -p "$g/root/usr/bin" "$g/root/usr/share/applications" "$g/root/usr/share/ghostty/themes" "$g/LICENSES"
    printf '#!/bin/sh\n' >"$g/root/usr/bin/ghostty"; chmod +x "$g/root/usr/bin/ghostty"
    printf '[Desktop Entry]\nExec=/usr/bin/ghostty\n' >"$g/root/usr/share/applications/com.mitchellh.ghostty.desktop"
    echo theme >"$g/root/usr/share/ghostty/themes/x"
    printf 'MIT License\n' >"$g/LICENSES/ghostty-LICENSE"; echo src >"$g/SOURCE"; echo build >"$g/BUILDINFO"
    (cd "$g/root" && find . -type f | sed 's#^\./##' | sort) >"$g/FILES"
}
mkimg() { # dir: both required components and (unless WITH_GHOSTTY=0) ghostty, with their COMPONENTS
    local d=$1; shift
    mkfix "$d.scx" scx; mkfix "$d.ext" extest; rm -rf "$d"; mkdir -p "$d/LICENSES"; cp -a "$d.scx/scx" "$d/"; cp -a "$d.ext/extest" "$d/"; echo gpl >"$d/LICENSES/scx-LICENSE"; echo src >"$d/SOURCE"; echo build >"$d/BUILDINFO"   # the top-level union and records of an assembled image
    printf 'scx\trequired\t%s\tbuilt\tsha256:%s\nextest\trequired\t%s\treused\tsha256:%s\n' "$H40" "$(printf 'a%.0s' {1..64})" "$H40" "$(printf 'b%.0s' {1..64})" >"$d/COMPONENTS"
    if [ "${WITH_GHOSTTY:-1}" = 1 ]; then
        mkghostty "$d"
        printf 'ghostty\toptional\t%s\tbuilt\tsha256:%s\n' "$H40" "$(printf 'c%.0s' {1..64})" >>"$d/COMPONENTS"
    fi
}
inst() { rm -rf "$dest"; env "$@" BINARIES_ROOT="$root/img" DESTDIR="$dest" bash "$here/build_files/install-binaries.sh" >"$root/run" 2>&1; rc=$?; }
dest="$root/dest"; lic="$dest/usr/share/licenses/octarine-os-binaries"
mkimg "$root/img"; inst X=1
check "installer: a normal build writes no MISSING or REMOVED record" bash -c "[ $rc = 0 ] && for f in MISSING REMOVED; do [ ! -e '$lic'/\$f ] || exit 1; done"
mkimg "$root/img"; rm -r "$root/img/extest"; sed -i '/^extest/d' "$root/img/COMPONENTS"; inst X=1
check "installer: a missing REQUIRED component fails the build" bash -c "[ $rc != 0 ] && grep -q 'required component extest is not in the binaries image' '$root/run'"
mkimg "$root/img"; mkdir -p "$root/img/stray"; inst X=1
check "installer: a component directory that COMPONENTS does not list is refused" bash -c "[ $rc != 0 ] && grep -q 'not in COMPONENTS' '$root/run'"
mkimg "$root/img"; printf 'nosuch\toptional\t%s\tbuilt\tsha256:%s\n' "$H40" "$(printf 'c%.0s' {1..64})" >>"$root/img/COMPONENTS"; mkdir -p "$root/img/nosuch"; inst X=1
check "installer: a component this installer does not know is refused (an image newer than the installer)" bash -c "[ $rc != 0 ] && grep -q 'does not know' '$root/run'"
mkimg "$root/img"; rm "$root/img/COMPONENTS"; inst X=1
check "installer: an image without COMPONENTS is not an assembled binaries image: refused" bash -c "[ $rc != 0 ] && grep -q 'COMPONENTS is missing' '$root/run'"
check "installer: the required list matches binaries/components.tsv" bash -c "[ \"\$(sed -n 's/^required=\"\\(.*\\)\"/\\1/p' '$here/build_files/install-binaries.sh')\" = \"\$(grep -vE '^[[:space:]]*(#|\$)' '$here/binaries/components.tsv' | awk -F'\t' '\$2 == \"required\" {print \$1}' | tr '\n' ' ' | sed 's/ \$//')\" ] && [ \"\$(sed -n 's/^optional=\"\\(.*\\)\"/\\1/p' '$here/build_files/install-binaries.sh')\" = \"\$(grep -vE '^[[:space:]]*(#|\$)' '$here/binaries/components.tsv' | awk -F'\t' '\$2 == \"optional\" {print \$1}' | tr '\n' ' ' | sed 's/ \$//')\" ]"
# runtime libraries: a stub ldd for the 64-bit files, readelf for the 32-bit one (a hand made header with an unresolved NEEDED is not available, so the 32-bit case uses the real libextest stand-in: no dynamic section means no NEEDED)
printf '#!/usr/bin/env bash\necho "\tlibfoo.so.1 => not found"\n' >"$bin/ldd-missing"; printf '#!/usr/bin/env bash\necho "\tlibc.so.6 => /lib64/libc.so.6"\n' >"$bin/ldd-ok"; chmod +x "$bin"/ldd-*
elf64() { python3 -I - "$1" <<'PY'
import struct, sys
h = b"\x7fELF" + bytes([2, 1, 1, 0]) + bytes(8) + struct.pack("<HHIQQQIHHHHHH", 3, 62, 1, 0, 0, 0, 0, 64, 56, 0, 64, 0, 0)
open(sys.argv[1], "wb").write(h)
PY
}
elf32() { python3 -I - "$1" <<'PY'
import struct, sys
h = b"\x7fELF" + bytes([1, 1, 1, 0]) + bytes(8) + struct.pack("<HHIIIIIHHHHHH", 3, 3, 1, 0, 0, 0, 0, 52, 32, 0, 40, 0, 0)
open(sys.argv[1], "wb").write(h)
PY
}
mkimg "$root/img"; for f in "$root"/img/scx/bin/*; do elf64 "$f"; done; elf64 "$root/img/extest/lib64/libextest.so"; elf32 "$root/img/extest/lib/libextest.so"
inst BINARIES_CHECK_NEEDED=1 BINARIES_LDD="$bin/ldd-ok"
check "installer: every 64-bit file resolves its libraries in this image: the check passes, and says so" bash -c "[ $rc = 0 ] && grep -q 'runtime libraries of scx: all found' '$root/run' && grep -q 'runtime libraries of extest: all found' '$root/run'"
inst BINARIES_CHECK_NEEDED=1 BINARIES_LDD="$bin/ldd-missing"
check "installer: a required component whose library is missing from the image FAILS the build, naming file and library" bash -c "[ $rc != 0 ] && grep -q 'libfoo.so.1 => not found' '$root/run' && grep -q 'required component scx needs shared libraries' '$root/run'"
inst X=1 BINARIES_LDD="$bin/ldd-missing"
check "installer: without BINARIES_CHECK_NEEDED a DESTDIR run does not check (only a real image build does)" bash -c "[ $rc = 0 ] && ! grep -q 'runtime libraries' '$root/run'"
# the removal path of an OPTIONAL component, with a one-off installer copy whose optional list names extest (the check function is the same code)
WITH_GHOSTTY=0 mkimg "$root/img"; for f in "$root"/img/scx/bin/*; do elf64 "$f"; done; elf64 "$root/img/extest/lib64/libextest.so"; elf32 "$root/img/extest/lib/libextest.so"
sed 's/^required="scx extest"/required="scx"/; s/^optional="ghostty"/optional="extest ghostty"/' "$here/build_files/install-binaries.sh" >"$root/inst-opt.sh"
printf 'scx\trequired\t%s\tbuilt\tsha256:%s\nextest\toptional\t%s\tbuilt\tsha256:%s\n' "$H40" "$(printf 'a%.0s' {1..64})" "$H40" "$(printf 'b%.0s' {1..64})" >"$root/img/COMPONENTS"
printf '#!/usr/bin/env bash\ncase "$1" in *extest*) echo "\tlibfoo.so.1 => not found" ;; *) echo "\tlibc.so.6 => ok" ;; esac\n' >"$bin/ldd-ext"; chmod +x "$bin/ldd-ext"
rm -rf "$dest"; BINARIES_CHECK_NEEDED=1 BINARIES_LDD="$bin/ldd-ext" BINARIES_ROOT="$root/img" DESTDIR="$dest" bash "$root/inst-opt.sh" >"$root/run" 2>&1; rc=$?
check "installer: an OPTIONAL component with a missing library is REMOVED again with a WARNING and a REMOVED record; the build goes on and the required component stays" bash -c "[ $rc = 0 ] && grep -q 'WARNING: optional component extest needs shared libraries' '$root/run' && [ ! -e '$dest/usr/lib/extest' ] && [ ! -e '$lic/extest' ] && grep -q '^extest: removed' '$lic/REMOVED' && [ -x '$dest/usr/bin/scx_rusty' ]"
mkimg "$root/img"; for f in "$root"/img/scx/bin/*; do elf64 "$f"; done; sed -i '/^extest/d' "$root/img/COMPONENTS"; rm -r "$root/img/extest"
rm -rf "$dest"; BINARIES_ROOT="$root/img" DESTDIR="$dest" bash "$root/inst-opt.sh" >"$root/run" 2>&1; rc=$?
check "installer: an ABSENT optional component is never skipped silently: a WARNING and annotation say what is not installed, and MISSING records it; the build goes on" bash -c "[ $rc = 0 ] && grep -q 'WARNING: optional component extest is not in the binaries image: it is NOT installed' '$root/run' && grep -q '^::warning::optional component extest' '$root/run' && grep -q '^extest: not in the binaries image' '$lic/MISSING' && [ ! -e '$dest/usr/lib/extest' ]"
echo
echo "passed: $pass, failed: $failn"
[ "$failn" = 0 ]
