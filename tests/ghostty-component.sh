#!/usr/bin/env bash
# Tests for the Ghostty component of the prebuilt binaries and its update path: the pins and the build recipe, the Zig fetch
# (fetch-zig.sh with a stub curl, minisign and a fake tarball), the installer's handling of the component (installed, conflict, missing), the
# version selection of the weekly check (ghostty-check.sh with stubbed gh and index.json data) and the pin writer (bump-ghostty.sh). No network. Needs: bash, git, jq, python3 with PyYAML, tar with xz. Run: tests/ghostty-component.sh
# shellcheck disable=SC2016,SC2034
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$here/tests/lib/components.sh"
root=$(mktemp -d)
trap 'rm -rf -- "$root"' EXIT
pass=0; failn=0; rc=0
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { failn=$((failn + 1)); echo "FAIL $1"; [ -f "$root/run" ] && sed 's/^/     run: /' "$root/run"; [ -f "$root/out" ] && sed 's/^/     out: /' "$root/out"; true; }
check() { local d=$1; shift; if "$@" >"$root/out" 2>&1; then ok "$d"; else bad "$d"; fi; }
bin="$root/bin"; mkdir -p "$bin"
sha() { local s='' i; for i in {1..40}; do s+=$1; done; echo "${s}"; }
g="$here/binaries/ghostty"


# ---- fetch-zig.sh with a fake tarball, a stub curl, minisign and index.json
ver=0.17.9
zd="$root/zigsrc/zig-x86_64-linux-$ver"; mkdir -p "$zd"
printf '#!/bin/sh\necho %s\n' "$ver" >"$zd/zig"; chmod +x "$zd/zig"
tar -C "$root/zigsrc" -cJf "$root/zig.tar.xz" "zig-x86_64-linux-$ver"
zsha=$(sha256sum "$root/zig.tar.xz" | cut -d' ' -f1); zsize=$(stat -c %s "$root/zig.tar.xz")
zurl="https://ziglang.org/download/$ver/zig-x86_64-linux-$ver.tar.xz"
key=RWSGOq2NVecA2UPNdBUZykf1CCb147pkmdtYxgb3Ti+JO/wCYvhbAb/U
mkenv() { printf 'ZIG_VERSION=%s\nZIG_URL=%s\nZIG_SHA256=%s\nZIG_SIZE=%s\nZIG_SIGNATURE_URL=%s.minisig\nZIG_MINISIGN_KEY=%s\n' "${1:-$ver}" "${2:-$zurl}" "${3:-$zsha}" "${4:-$zsize}" "${2:-$zurl}" "$key" >"$root/zig.env"; }
mkindex() { printf '{"%s":{"x86_64-linux":{"tarball":"%s","shasum":"%s","size":"%s"}}}\n' "$ver" "${1:-$zurl}" "${2:-$zsha}" "${3:-$zsize}" >"$root/index.json"; }
cat >"$bin/curl" <<'F'
#!/usr/bin/env bash
# stub: curl -fsSL --retry N -o <out> <url>
out=""; url=""; while [ $# -gt 0 ]; do case "$1" in -o) out=$2; shift 2 ;; -*) shift ;; --retry) shift 2 ;; *) url=$1; shift ;; esac; done
echo "curl $url" >>"$CURL_LOG"
case "$url" in
    *.tar.xz.minisig) printf 'sig' >"$out" ;;
    *.tar.xz) cp "$ZIG_TARBALL" "$out" ;;
    *index.json) cp "$ZIG_INDEX" "$out" ;;
    *) exit 22 ;;
esac
F
cat >"$bin/minisign" <<'F'
#!/usr/bin/env bash
echo "minisign $*" >>"$CURL_LOG"; exit "${MINISIGN_RC:-0}"
F
chmod +x "$bin"/*
export CURL_LOG="$root/curl.log" ZIG_TARBALL="$root/zig.tar.xz" ZIG_INDEX="$root/index.json"
fz() { rm -rf "$root/zd"; : >"$CURL_LOG"; env "$@" CURL="$bin/curl" MINISIGN="${MINISIGN_CMD:-$bin/minisign}" bash "$g/fetch-zig.sh" "$root/zig.env" "$root/zd" >"$root/run" 2>&1; rc=$?; }
mkenv; mkindex; fz X=1
check "fetch-zig: a matching pin passes: size, sha256, index.json and the minisign signature (with the pinned key) are checked, the Zig is unpacked and reports its version" bash -c "[ $rc = 0 ] && grep -q 'minisign signature verified' '$root/zd/FETCH-RECORD' && grep -q -- \"-P $key\" '$CURL_LOG' && grep -q 'index.json' '$CURL_LOG' && [ \"\$('$root/zd/zig' version)\" = $ver ]"
mkenv "$ver" "$zurl" "$(printf 'a%.0s' {1..64})"; fz X=1
check "fetch-zig: a sha256 that does not match the download FAILS" bash -c "[ $rc != 0 ] && grep -q 'tarball sha256 is' '$root/run' && [ ! -e '$root/zd/zig' ]"
mkenv "$ver" "$zurl" "$zsha" 1; fz X=1
check "fetch-zig: a size that does not match FAILS" bash -c "[ $rc != 0 ] && grep -q 'bytes' '$root/run'"
mkenv; mkindex "$zurl" "$(printf 'b%.0s' {1..64})"; fz X=1
check "fetch-zig: an index.json that lists another sha256 for this version FAILS (pin and upstream disagree)" bash -c "[ $rc != 0 ] && grep -q 'index.json does not list' '$root/run'"
mkindex "https://ziglang.org/elsewhere.tar.xz"; fz X=1
check "fetch-zig: an index.json with another URL FAILS" test "$rc" != 0
mkindex; fz MINISIGN_RC=1
check "fetch-zig: a signature that does not verify FAILS" bash -c "[ $rc != 0 ] && grep -q 'minisign signature of the tarball does not verify' '$root/run'"
MINISIGN_CMD=/nonexistent/minisign fz X=1
check "fetch-zig: without minisign the record says so plainly (sha256 pin and index.json only), the build still passes" bash -c "[ $rc = 0 ] && grep -q 'minisign NOT installed' '$root/zd/FETCH-RECORD'"
mkenv "$ver" "https://example.org/zig.tar.xz"; fz X=1
check "fetch-zig: a URL that is not the official ziglang.org one for this version is refused before any download" bash -c "[ $rc != 0 ] && grep -q 'ZIG_URL must be' '$root/run' && [ ! -s '$CURL_LOG' ]"
mkenv; sed -i '/^ZIG_SIZE/d' "$root/zig.env"; mkindex; fz X=1
check "fetch-zig: ZIG_SIZE is optional: without it the pinned sha256 and index.json still have to agree on the real file (size from the index)" bash -c "[ $rc = 0 ] && [ \"\$('$root/zd/zig' version)\" = $ver ]"
mkenv; sed -i '/^ZIG_SIZE/d' "$root/zig.env"; mkindex "$zurl" "$zsha" 1; fz X=1
check "fetch-zig: with no pinned size an index.json that lists another size than the file FAILS" bash -c "[ $rc != 0 ] && grep -q 'index.json does not list' '$root/run'"
mkenv; mkindex; fz X=1 >/dev/null 2>&1
mkenv; echo 'ZIG_EXTRA=1' >>"$root/zig.env"; fz X=1
check "fetch-zig: an unknown key is refused" bash -c "[ $rc != 0 ] && grep -q 'unknown key' '$root/run'"
mkenv; echo "ZIG_SIZE=1" >>"$root/zig.env"; fz X=1
check "fetch-zig: a duplicate key is refused" bash -c "[ $rc != 0 ] && grep -q 'duplicate' '$root/run'"
mkenv; sed -i '/^ZIG_SHA256/d' "$root/zig.env"; fz X=1
check "fetch-zig: a missing key is refused" bash -c "[ $rc != 0 ] && grep -q 'ZIG_SHA256 is missing' '$root/run'"
mkenv; echo 'echo pwned' >>"$root/zig.env"; fz X=1
check "fetch-zig: shell syntax in the file is refused (it is parsed, never sourced)" test "$rc" != 0
printf '#!/bin/sh\necho 0.0.1\n' >"$zd/zig"; tar -C "$root/zigsrc" -cJf "$root/zig.tar.xz" "zig-x86_64-linux-$ver"
zsha2=$(sha256sum "$root/zig.tar.xz" | cut -d' ' -f1); zsize2=$(stat -c %s "$root/zig.tar.xz"); mkenv "$ver" "$zurl" "$zsha2" "$zsize2"; mkindex "$zurl" "$zsha2" "$zsize2"; fz X=1
check "fetch-zig: a Zig that reports another version than the pin FAILS" bash -c "[ $rc != 0 ] && grep -q 'zig reports 0.0.1' '$root/run'"

# ---- the installer with the ghostty component (a fixture tree)
H40=$(printf 'b%.0s' {1..40})
mkimg() { # dir
    rm -rf "$1"; mkdir -p "$1/scx/bin" "$1/scx/LICENSES" "$1/extest/lib" "$1/extest/lib64" "$1/extest/LICENSES" "$1/ghostty/root/usr/bin" "$1/ghostty/root/usr/share/applications" "$1/ghostty/LICENSES"
    printf '#!/bin/sh\n' >"$1/scx/bin/scx_rusty"; printf 'scx_rusty\tbin/scx_rusty\t\tHybrid\n' >"$1/scx/schedulers.tsv"
    printf 'GNU GENERAL PUBLIC LICENSE\n' >"$1/scx/LICENSES/l"; printf 'MIT License\n' >"$1/extest/LICENSES/l"; echo 32 >"$1/extest/lib/libextest.so"; echo 64 >"$1/extest/lib64/libextest.so"
    printf '#!/bin/sh\n' >"$1/ghostty/root/usr/bin/ghostty"; chmod +x "$1/ghostty/root/usr/bin/ghostty"
    printf '[Desktop Entry]\nExec=/usr/bin/ghostty\n' >"$1/ghostty/root/usr/share/applications/com.mitchellh.ghostty.desktop"
    printf 'MIT License\n' >"$1/ghostty/LICENSES/l"
    (cd "$1/ghostty/root" && find . -type f | sed 's#^\./##' | sort) >"$1/ghostty/FILES"
    for c in scx extest ghostty; do echo src >"$1/$c/SOURCE"; echo build >"$1/$c/BUILDINFO"; done
    [ "${NO_GHOSTTY:-0}" != 1 ] || rm -rf "$1/ghostty"
    if [ "${NO_GHOSTTY:-0}" = 1 ]; then write_components "$1" scx extest; else write_components "$1" scx extest ghostty; fi
}
inst() { rm -rf "$dest"; env "$@" BINARIES_ROOT="$root/img" DESTDIR="$dest" bash "$here/build_files/install-binaries.sh" >"$root/run" 2>&1; rc=$?; }
dest="$root/dest"; lic="$dest/usr/share/licenses/octarine-binaries"
mkimg "$root/img"; inst X=1
check "installer: the ghostty tree goes under /usr (binary, desktop file, data), its records under the licenses directory, " bash -c "[ $rc = 0 ] && [ -x '$dest/usr/bin/ghostty' ] && [ -f '$dest/usr/share/applications/com.mitchellh.ghostty.desktop' ] && [ -s '$lic/ghostty/SOURCE' ] && [ -s '$lic/ghostty/ghostty-LICENSE' -o -s '$lic/ghostty/l' ]"
NO_GHOSTTY=1 mkimg "$root/img"; inst X=1
check "installer: ghostty is required: not in the image fails the build" bash -c "[ $rc != 0 ] && grep -q 'required component ghostty is not in the binaries image' '$root/run'"
mkimg "$root/img"; rm -rf "$dest"; mkdir -p "$dest/usr/bin"; echo mine >"$dest/usr/bin/ghostty"
env BINARIES_ROOT="$root/img" DESTDIR="$dest" bash "$here/build_files/install-binaries.sh" >"$root/run" 2>&1; rc=$?
check "installer: a file the image already has is never overwritten: the build fails and the existing file is untouched" bash -c "[ $rc != 0 ] && grep -q 'would overwrite usr/bin/ghostty' '$root/run' && [ \"\$(cat '$dest/usr/bin/ghostty')\" = mine ]"
mkimg "$root/img"; mkdir -p "$root/img/ghostty/root/usr/share/terminfo/g"; echo ti >"$root/img/ghostty/root/usr/share/terminfo/g/ghostty"; (cd "$root/img/ghostty/root" && find . -type f | sed 's#^\./##' | sort) >"$root/img/ghostty/FILES"
rm -rf "$dest"; mkdir -p "$dest/usr/share/terminfo/g"; echo base >"$dest/usr/share/terminfo/g/ghostty"
env BINARIES_ROOT="$root/img" DESTDIR="$dest" bash "$here/build_files/install-binaries.sh" >"$root/run" 2>&1; rc=$?
check "installer: a terminfo file the image already has (ncurses-term ships ghostty) is KEPT and skipped, everything else of ghostty is installed, no conflict" bash -c "[ $rc = 0 ] && grep -q 'kept the image.s own terminfo: usr/share/terminfo/g/ghostty' '$root/run' && [ \"\$(cat '$dest/usr/share/terminfo/g/ghostty')\" = base ] && [ -x '$dest/usr/bin/ghostty' ]"
mkimg "$root/img"; echo '../../etc/passwd' >>"$root/img/ghostty/FILES"; inst X=1
check "installer: a FILES entry outside usr/ fails the build (nothing is written outside /usr)" bash -c "[ $rc != 0 ] && grep -q 'outside usr/' '$root/run' && [ ! -e '$dest/usr/bin/ghostty' ]"
printf '#!/usr/bin/env bash\necho "\tlibgtk4-layer-shell.so.0 => not found"\n' >"$bin/ldd-missing"; chmod +x "$bin/ldd-missing"
printf '#!/usr/bin/env bash\necho "\tlibc.so.6 => ok"\n' >"$bin/ldd-ok"; chmod +x "$bin/ldd-ok"
elf64() { python3 -I - "$1" <<'PY'
import struct, sys
h = b"\x7fELF" + bytes([2, 1, 1, 0]) + bytes(8) + struct.pack("<HHIQQQIHHHHHH", 3, 62, 1, 0, 0, 0, 0, 64, 56, 0, 64, 0, 0)
open(sys.argv[1], "wb").write(h)
PY
}
mkimg "$root/img"; elf64 "$root/img/ghostty/root/usr/bin/ghostty"; elf64 "$root/img/scx/bin/scx_rusty"; elf64 "$root/img/extest/lib64/libextest.so"
python3 -I - "$root/img/extest/lib/libextest.so" <<'PY'
import struct, sys
open(sys.argv[1], "wb").write(b"\x7fELF" + bytes([1, 1, 1, 0]) + bytes(8) + struct.pack("<HHIIIIIHHHHHH", 3, 3, 1, 0, 0, 0, 0, 52, 32, 0, 40, 0, 0))
PY
# a stub ldd that only fails for ghostty
printf '#!/usr/bin/env bash\ncase "$1" in *ghostty*) echo "\tlibgtk4-layer-shell.so.0 => not found" ;; *) echo "\tlibc.so.6 => ok" ;; esac\n' >"$bin/ldd-ghostty"; chmod +x "$bin/ldd-ghostty"
inst BINARIES_CHECK_NEEDED=1 BINARIES_LDD="$bin/ldd-ghostty"
check "installer: ghostty needs a library the image lacks (gtk4-layer-shell): the build fails and names the missing library" bash -c "[ $rc != 0 ] && grep -q 'libgtk4-layer-shell.so.0 => not found' '$root/run' && grep -q 'component ghostty needs shared libraries' '$root/run'"
inst BINARIES_CHECK_NEEDED=1 BINARIES_LDD="$bin/ldd-ok"
check "installer: with every library present ghostty stays installed" bash -c "[ $rc = 0 ] && [ -x '$dest/usr/bin/ghostty' ] && grep -q 'runtime libraries of ghostty: all found' '$root/run'"

# ---- build.sh itself with a stub zig (the Zig 0.17 fetch layout) and a stub stage.sh: fetch, unpack, flatten, build arguments, pruning
zb="$root/zbin"; mkdir -p "$zb"
cat >"$zb/zig" <<'F'
#!/usr/bin/env bash
case "$1" in
    version) echo 0.17.0 ;;
    fetch)
        [ "$2" = "--help" ] && exit 0
        h="pkg-$(printf '%s' "$2" | cksum | cut -d' ' -f1)"; mkdir -p "$ZIG_GLOBAL_CACHE_DIR/p" "$ZSTUB_TMP/t/$h"
        rm -rf "$ZSTUB_TMP/t/$h"/*
        case "$2" in
            *nested2*) mkdir -p "$ZSTUB_TMP/t/$h/up/deeper"; echo x >"$ZSTUB_TMP/t/$h/up/deeper/f" ;;
            *nested*) mkdir -p "$ZSTUB_TMP/t/$h/upstream-1.0"; echo x >"$ZSTUB_TMP/t/$h/upstream-1.0/build.zig" ;;
            *) echo x >"$ZSTUB_TMP/t/$h/build.zig" ;;
        esac
        tar -C "$ZSTUB_TMP/t" -czf "$ZIG_GLOBAL_CACHE_DIR/p/$h.tar.gz" "$h"; echo "$h" ;;
    build)
        echo "$*" >"$ZSTUB_TMP/build.args"; ls "${@:4:1}" >/dev/null 2>&1; for a in "$@"; do case "$prev" in --system) cp -r "$a" "$ZSTUB_TMP/sysdir"; esac; prev=$a; done
        mkdir -p "$DESTDIR/usr/bin" "$DESTDIR/usr/share/applications" "$DESTDIR/usr/lib" "$DESTDIR/usr/include/ghostty/vt"
        echo bin >"$DESTDIR/usr/bin/ghostty"; chmod +x "$DESTDIR/usr/bin/ghostty"; echo d >"$DESTDIR/usr/share/applications/com.mitchellh.ghostty.desktop"
        echo so >"$DESTDIR/usr/lib/libghostty-vt.so"; echo so >"$DESTDIR/usr/lib/libghostty-vt.so.0"; echo h >"$DESTDIR/usr/include/ghostty/vt/a.h" ;;
esac
F
cat >"$root/stage-stub.sh" <<'F'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do case "$1" in --out) out=$2; shift 2 ;; --src) src=$2; shift 2 ;; --bin) b=$2; shift 2 ;; *) shift ;; esac; done
mkdir -p "$out/root/usr/bin"; cp "$src/${b%%:*}" "$out/${b#*:}"; echo ok >"$out/SOURCE"; echo ok >"$out/BUILDINFO"
F
chmod +x "$zb/zig" "$root/stage-stub.sh"
mksrc() { rm -rf "$root/zsrc" "$root/zout" "$root/ztmp"; mkdir -p "$root/zsrc" "$root/ztmp"; printf '%s\n' "$@" >"$root/zsrc/build.zig.zon.txt"; echo mit >"$root/zsrc/LICENSE"; }
zrun() { env PATH="$zb:$PATH" ZSTUB_TMP="$root/ztmp" STAGE_SH="$root/stage-stub.sh" bash "$g/build.sh" "$g/upstream.env" "$root/zsrc" "$root/zout" >"$root/run" 2>&1; rc=$?; }
mksrc https://d.example/a.tar.gz https://d.example/nested-b.tar.gz https://d.example/c.tar.gz
zrun
check "build.sh with the Zig 0.17 fetch layout: every URL is fetched into a fresh cache and unpacked, a package that keeps the upstream top-level directory is flattened, zig build gets that directory with --system, the build succeeds" bash -c "[ $rc = 0 ] && [ \$(ls '$root/ztmp/sysdir' | wc -l) = 3 ] && [ \$(ls '$root/ztmp'/sysdir/*/build.zig | wc -l) = 3 ] && grep -q -- '--system' '$root/ztmp/build.args' && grep -q -- '-Doptimize=ReleaseFast' '$root/ztmp/build.args' && ! grep -q 'fno-sys' '$root/ztmp/build.args' && grep -q 'fetched and unpacked 3 packages' '$root/run'"
check "build.sh: libghostty-vt (library and headers) is pruned from the staged tree, the desktop file and the binary are kept, FILES lists them" bash -c "f='$root/zout/FILES'; grep -qx usr/bin/ghostty \$f && grep -qx usr/share/applications/com.mitchellh.ghostty.desktop \$f && ! grep -q 'libghostty-vt' \$f && ! grep -q 'include/ghostty' \$f && [ ! -e '$root/zout/root/usr/include' ]"
mksrc https://d.example/a.tar.gz https://d.example/nested2-b.tar.gz
zrun
check "build.sh: a package still nested after one flattening fails with a clear message (not a confusing Zig error later)" bash -c "[ $rc != 0 ] && grep -q 'still holds a single subdirectory' '$root/run'"
mksrc https://d.example/a.tar.gz
printf '#!/usr/bin/env bash\n[ "$1" = fetch ] && [ "$2" != --help ] && exit 1; exec "$REAL_ZIG" "$@"\n' >"$root/zbin2.sh"; mkdir -p "$root/zb2"; cp "$zb/zig" "$root/zb2/zig.real"; printf '#!/usr/bin/env bash\n[ "$1" = fetch ] && [ "$2" != --help ] && { echo "boom" >&2; exit 1; }\nexec "%s/zig.real" "$@"\n' "$root/zb2" >"$root/zb2/zig"; chmod +x "$root/zb2/zig"
env PATH="$root/zb2:$PATH" ZSTUB_TMP="$root/ztmp" STAGE_SH="$root/stage-stub.sh" bash "$g/build.sh" "$g/upstream.env" "$root/zsrc" "$root/zout" >"$root/run" 2>&1; rc=$?
check "build.sh: a failed zig fetch (a package that does not verify against its hash) fails the build and names the URL" bash -c "[ $rc != 0 ] && grep -q 'zig fetch failed for https://d.example/a.tar.gz' '$root/run'"

# ---- ghostty-check.sh: the version selection, with a stub gh and index.json data
cr="$root/crepo"; mkdir -p "$cr/binaries/lib" "$cr/binaries/ghostty" "$cr/.github/scripts"
cp "$here/binaries/lib/upstream-env.sh" "$cr/binaries/lib/"; cp "$here/.github/scripts/ghostty-check.sh" "$cr/.github/scripts/"
setpin() { printf 'UPSTREAM_REPO=ghostty-org/ghostty\nUPSTREAM_TAG=%s\nUPSTREAM_COMMIT=%s\n' "$1" "$(sha a)" >"$cr/binaries/ghostty/upstream.env"
    printf 'ZIG_VERSION=%s\nZIG_URL=u\nZIG_SHA256=s\nZIG_SIZE=1\nZIG_SIGNATURE_URL=u.minisig\nZIG_MINISIGN_KEY=k\n' "$2" >"$cr/binaries/ghostty/zig.env"; }
cat >"$bin/gh" <<'F'
#!/usr/bin/env bash
echo "gh $*" >>"$GH_LOG"
[ "$1" = api ] || exit 99
shift; path=""; for a in "$@"; do case "$a" in -*) ;; *) [ -z "$path" ] && path=$a ;; esac; done
[ "$path" = "--jq" ] && exit 99
f="$GH_DIR/$(printf '%s' "$path" | tr '/?=&' '____')"
[ -f "$f" ] && [ ! -f "$f.fail" ] && cat "$f"
F
chmod +x "$bin/gh"
export GH_LOG="$root/gh.log" GH_DIR="$root/gh"
export GITHUB_REPOSITORY=o/r BUMP_CHECKS_WAIT=0
reply() { rm -rf "$GH_DIR"; mkdir -p "$GH_DIR"; : >"$GH_LOG"; }
put() { printf '%s\n' "$2" >"$GH_DIR/$1"; }
zon() { printf '.{ .name = .ghostty, .version = "x", .minimum_zig_version = "%s", }\n' "$1" | base64 -w0; echo; }
tagsfile() { local t; : >"$GH_DIR/repos_ghostty-org_ghostty_tags_per_page_100"; for t in "$@"; do echo "$t" >>"$GH_DIR/repos_ghostty-org_ghostty_tags_per_page_100"; done; }
zi() { # versions with x86_64-linux entries
    local v j=""; for v in "$@"; do j+="\"$v\":{\"x86_64-linux\":{\"tarball\":\"https://ziglang.org/download/$v/zig-x86_64-linux-$v.tar.xz\",\"shasum\":\"$(printf '%064d' "$((10#${v//./}))")\",\"size\":\"123\"}},"; done
    printf '{"master":{"version":"0.18.0-dev"},%s"0.16.0":{"date":"x"}}\n' "$j" >"$root/idx.json"; }
chk() { REPO_ROOT="$cr" ZIG_INDEX_FILE="$root/idx.json" PATH="$bin:$PATH" bash "$cr/.github/scripts/ghostty-check.sh"; }
newc() { put "repos_ghostty-org_ghostty_commits_$1" "$(sha c)"; put "repos_ghostty-org_ghostty_contents_build.zig.zon_ref_$1" "$(zon "$2")"; }
zsh1=$(printf '%064d' 171); zsh2=$(printf '%064d' 172)
setpin v1.4.0 0.17.1; reply; tagsfile v1.4.0 v1.3.1 tip vt-1.0.1; zi 0.17.0 0.17.1; newc v1.4.0 0.17.0
check "check: the pinned tag is the newest stable tag and Zig the newest published patch of its minor: current" bash -c "[[ \"\$(PATH='$bin:$PATH' REPO_ROOT='$cr' ZIG_INDEX_FILE='$root/idx.json' bash '$cr/.github/scripts/ghostty-check.sh')\" == current* ]]"
setpin v1.4.0 0.17.1; reply; tagsfile v1.4.0 v1.5.0 v1.5.0-rc1 tip vt-1.0.1 v1.3.1; zi 0.17.0 0.17.1 0.17.2; newc v1.5.0 0.17.0; newc v1.4.0 0.17.0
out=$(chk)
check "check: a new tag with an unchanged Zig minor: bump with the tag, its peeled commit and the NEWEST published patch of that minor (0.17.2), with URL, sha256 and size from index.json" bash -c "[ \"$out\" = \"bump v1.5.0 $(sha c) 0.17.2 https://ziglang.org/download/0.17.2/zig-x86_64-linux-0.17.2.tar.xz $zsh2 123\" ]"
setpin v1.4.0 0.17.1; reply; tagsfile v1.9.0 v1.10.0 v1.4.0; zi 0.17.0 0.17.1; newc v1.10.0 0.17.0; newc v1.4.0 0.17.0
out=$(chk)
check "check: tags are compared as versions (v1.10.0 is newer than v1.9.0 and v1.4.0)" bash -c "[[ \"$out\" == 'bump v1.10.0 '* ]]"
setpin v1.4.0 0.17.1; reply; tagsfile v1.4.0 v1.6.0; zi 0.17.0 0.17.1; newc v1.6.0 0.18.0; newc v1.4.0 0.17.0
out=$(chk)
check "check: a new tag that needs a new Zig minor with no published tarball yet: wait, nothing to open, and the line says why" bash -c "[[ \"$out\" == wait\ v1.6.0\ * && \"$out\" == *'0.18'* && \"$out\" == *'no x86_64-linux tarball'* ]]"
setpin v1.4.0 0.17.1; reply; tagsfile v1.4.0 v1.6.0; zi 0.17.0 0.17.1 0.18.0; newc v1.6.0 0.18.0; newc v1.4.0 0.17.0
out=$(chk)
check "check: a new tag with a new Zig minor that IS published: the Zig minor follows the Ghostty tag (bump moves to 0.18.0), never on its own" bash -c "[[ \"$out\" == bump\ v1.6.0\ *\ 0.18.0\ * ]]"
setpin v1.4.0 0.17.1; reply; tagsfile v1.4.0; zi 0.17.0 0.17.1 0.18.0 0.18.1; newc v1.4.0 0.17.0
out=$(chk)
check "check: a newer Zig MINOR alone never causes a bump (the pinned tag requires 0.17): current" bash -c "[[ \"$out\" == current* ]]"
setpin v1.4.0 0.17.1; reply; tagsfile v1.4.0 v1.5.0; zi 0.17.0 0.17.1; newc v1.5.0 0.17.3; newc v1.4.0 0.17.0
out=$(chk)
check "check: the new tag needs Zig 0.17.3 or newer and only 0.17.1 is published: wait" bash -c "[[ \"$out\" == wait* ]]"
setpin v1.4.0 0.17.1; reply; tagsfile v1.4.0; printf '{"0.17.1":{"x86_64-linux":{"tarball":"https://ziglang.org/download/0.17.1/zig-x86_64-linux-0.17.1.tar.xz","shasum":"%s","size":"1"}},"0.17.2":{"aarch64-linux":{"tarball":"x","shasum":"y","size":"1"}}}\n' "$zsh1" >"$root/idx.json"; newc v1.4.0 0.17.0
out=$(chk)
check "check: a newer patch that has no x86_64-linux tarball is not offered" bash -c "[[ \"$out\" == current* ]]"
setpin v1.4.0 0.17.1; reply; zi 0.17.1
check "check: the tags API failing is unreachable (fail soft, exit 0)" bash -c "[[ \"\$(PATH='$bin:$PATH' REPO_ROOT='$cr' ZIG_INDEX_FILE='$root/idx.json' bash '$cr/.github/scripts/ghostty-check.sh'; echo rc=\$?)\" == *unreachable*rc=0 ]]"
reply; tagsfile v1.4.0 v1.5.0; newc v1.5.0 0.17.0; echo 'not json' >"$root/idx.json"
out=$(chk)
check "check: an unreadable index.json is unreachable" bash -c "[[ \"$out\" == unreachable* ]]"
! grep -qE 'gh (pr|repo|release) |--method|-X ' "$GH_LOG" && ok "check: only reads (gh api GET)" || bad "check wrote something"

# ---- bump-ghostty.sh: the pin writer (the commit and the pull request are bump-run.sh and bump-weekly.sh, tested in tests/bump-run.sh)
wc="$root/wc"; mkdir -p "$wc/binaries/lib" "$wc/binaries/ghostty"
cp "$here/binaries/lib/upstream-env.sh" "$wc/binaries/lib/"
cp "$g/upstream.env" "$g/zig.env" "$wc/binaries/ghostty/"
Z2=https://ziglang.org/download/0.17.2/zig-x86_64-linux-0.17.2.tar.xz; Z3=https://ziglang.org/download/0.18.0/zig-x86_64-linux-0.18.0.tar.xz
bump() { REPO_ROOT="$wc" bash "$here/.github/scripts/bump-ghostty.sh" "$@" >"$root/run" 2>&1; rc=$?; }
cp "$wc/binaries/ghostty/upstream.env" "$root/up.orig"
bump ghostty v1.5.0 "$(sha d)" 0.18.0 "$Z3" "$(printf 'e%.0s' {1..64})" 777
check "bump ghostty: upstream.env AND zig.env change together (tag, peeled commit, Zig version, URL, sha256, size, signature URL; the minisign key and the comments stay)" bash -c "
  [ $rc = 0 ] && z=\$(cat '$wc/binaries/ghostty/zig.env') && grep -qx 'ZIG_VERSION=0.18.0' <<<\"\$z\" && grep -qx 'ZIG_URL=$Z3' <<<\"\$z\" && grep -qx 'ZIG_SHA256=$(printf 'e%.0s' {1..64})' <<<\"\$z\" &&
  grep -qx 'ZIG_SIGNATURE_URL=$Z3.minisig' <<<\"\$z\" && grep -qx 'ZIG_MINISIGN_KEY=$key' <<<\"\$z\" && grep -q '^# ' <<<\"\$z\" &&
  u=\$(cat '$wc/binaries/ghostty/upstream.env') && grep -qx 'UPSTREAM_TAG=v1.5.0' <<<\"\$u\" && grep -qx 'UPSTREAM_COMMIT=$(sha d)' <<<\"\$u\""
bump zig 0.17.2 1 2 3
check "bump: a standalone Zig bump is refused (mode zig no longer exists)" test "$rc" = 2

echo
echo "passed: $pass, failed: $failn"
[ "$failn" = 0 ]
