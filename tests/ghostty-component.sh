#!/usr/bin/env bash
# Tests for the optional Ghostty component of the prebuilt binaries and its update path: the pins and the build recipe, the Zig fetch
# (fetch-zig.sh with a stub curl, minisign and a fake tarball), the installer's handling of the component (installed, conflict, absent), the
# version selection of the weekly check (ghostty-check.sh with stubbed gh and index.json data) and the bump pull requests (bump-ghostty.sh with a
# local origin and a stub gh). No network. Needs: bash, git, jq, python3 with PyYAML, tar with xz. Run: tests/ghostty-component.sh
# shellcheck disable=SC2016,SC2034
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
root=$(mktemp -d)
trap 'rm -rf -- "$root"' EXIT
pass=0; failn=0; rc=0
unset GITHUB_OUTPUT GITHUB_ENV GITHUB_STEP_SUMMARY
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { failn=$((failn + 1)); echo "FAIL $1"; [ -f "$root/run" ] && sed 's/^/     run: /' "$root/run"; [ -f "$root/out" ] && sed 's/^/     out: /' "$root/out"; true; }
check() { local d=$1; shift; if "$@" >"$root/out" 2>&1; then ok "$d"; else bad "$d"; fi; }
bin="$root/bin"; mkdir -p "$bin"
sha() { local s='' i; for i in {1..40}; do s+=$1; done; echo "${s}"; }
g="$here/binaries/ghostty"

# ---- the pins and the recipe
check "upstream.env: Ghostty v1.4.0 pinned by tag AND peeled commit (the build fails if the tag moved)" bash -c "grep -qx 'UPSTREAM_REPO=ghostty-org/ghostty' '$g/upstream.env' && grep -qx 'UPSTREAM_TAG=v1.4.0' '$g/upstream.env' && grep -qx 'UPSTREAM_COMMIT=83fb95624b0439ee660c2679b43b38c8b63769cd' '$g/upstream.env' && source '$here/binaries/lib/upstream-env.sh' && upstream_env_load '$g/upstream.env' && [ \"\$UPSTREAM_WATCH\" = ghostty-org/ghostty ]"
check "zig.env: Zig 0.17.0 (the version Ghostty 1.4.0 builds with), the official ziglang.org URL, a sha256, no pinned size and the minisign key, and nothing else" bash -c "
  grep -qx 'ZIG_VERSION=0.17.0' '$g/zig.env' && grep -qx 'ZIG_URL=https://ziglang.org/download/0.17.0/zig-x86_64-linux-0.17.0.tar.xz' '$g/zig.env' &&
  grep -qx 'ZIG_SHA256=1cbe9df9f27e6b78d14ccbca43b6703a404ef79ef1c463de901d7f088d4e2026' '$g/zig.env' && ! grep -q '^ZIG_SIZE' '$g/zig.env' &&
  grep -qx 'ZIG_SIGNATURE_URL=https://ziglang.org/download/0.17.0/zig-x86_64-linux-0.17.0.tar.xz.minisig' '$g/zig.env' && grep -qx 'ZIG_MINISIGN_KEY=RWSGOq2NVecA2UPNdBUZykf1CCb147pkmdtYxgb3Ti+JO/wCYvhbAb/U' '$g/zig.env' &&
  [ \"\$(grep -vE '^[[:space:]]*(#|\$)' '$g/zig.env' | wc -l)\" = 5 ]"
check "Containerfile: builder from builder.env, the Zig and the source are fetched and verified before the build, a FROM scratch image holds only /ghostty, the packages include gtk4-layer-shell-devel, blueprint-compiler and minisign" bash -c "
  cf='$g/Containerfile'; grep -qx 'FROM \${BUILDER} AS build' \$cf && grep -q 'fetch-zig.sh /binaries/ghostty/zig.env /opt/zig' \$cf && grep -q 'fetch-source.sh /binaries/ghostty/upstream.env /src' \$cf &&
  grep -q 'gtk4-layer-shell-devel' \$cf && grep -q 'blueprint-compiler' \$cf && grep -qw 'minisign' \$cf && grep -q 'libadwaita-devel' \$cf && grep -qx 'COPY --from=build /out /ghostty' \$cf &&
  [ \"\$(grep -E '^FROM ' \$cf | tail -n1)\" = 'FROM scratch' ] && [ \"\$(grep -c '^FROM \${BUILDER}' \$cf)\" = 1 ]"
check "build.sh: Zig 0.17 recipe: a FRESH empty Zig cache, zig fetch of every build.zig.zon.txt URL, each saved tarball unpacked into a separate package directory and flattened, a clear failure for a package still nested, zig build --system <that directory>, no -fno-sys, libghostty-vt pruned, the absolute exe path, ReleaseFast and the baseline CPU, a --version smoke run, the staged tree with FILES" bash -c "
  b='$g/build.sh'; grep -q 'mktemp -d /tmp/zig-global-cache' \$b && grep -q 'zig fetch \"\${url}\"' \$b && grep -q 'build.zig.zon.txt' \$b && grep -q 'tar -xzf \"\${pkg}\" -C \"\${sys}\"' \$b && grep -q 'still holds a single subdirectory' \$b &&
  grep -q -- '--system \"\${sys}\"' \$b && ! grep -q -- '-fno-sys' \$b && ! grep -q 'fetch-zig-cache.sh\$' \$b && grep -q -- '-Doptimize=ReleaseFast' \$b && grep -q -- '-Dcpu=baseline' \$b &&
  grep -q -- '-Dinstalled-exe-path=/usr/bin/ghostty' \$b && grep -q -- '--prefix /usr' \$b && grep -q 'libghostty-vt' \$b && grep -q 'include/ghostty' \$b &&
  grep -q -- '--smoke root/usr/bin/ghostty:--version' \$b && grep -q -- '--elf-x86-64 root/usr/bin/ghostty' \$b && grep -q 'FILES' \$b && grep -q 'com.mitchellh.ghostty.desktop' \$b"
check "the OS image build installs gtk4-layer-shell (the runtime library Ghostty links); a missing one is recorded as an optional package, and the runtime check then removes Ghostty with a warning" bash -c "grep -q '\"misc:.* gtk4-layer-shell\"' '$here/build_files/build.sh'"
check "components.tsv lists ghostty as optional and the installer's lists agree; the layout contract knows ghostty" bash -c "grep -qP '^ghostty\toptional\$' '$here/binaries/components.tsv' && grep -q '^optional=\"ghostty\"' '$here/build_files/install-binaries.sh' && grep -q 'ghostty) need ghostty/root/usr/bin/ghostty' '$here/.github/scripts/binaries-layout.sh'"
check "both smoke tests check ghostty (installed with its desktop file and resolved libraries, or recorded as left out)" bash -c "for f in build.yml build-beta.yml; do grep -q 'optional ghostty: installed with its desktop file' '$here/.github/workflows/'\$f || exit 1; done"

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
    printf 'scx\trequired\t%s\tbuilt\t\tsha256:%s\nextest\trequired\t%s\tbuilt\t\tsha256:%s\n' "$H40" "$(printf 'a%.0s' {1..64})" "$H40" "$(printf 'b%.0s' {1..64})" >"$1/COMPONENTS"
    [ "${NO_GHOSTTY:-0}" != 1 ] || rm -rf "$1/ghostty"
    [ "${NO_GHOSTTY:-0}" = 1 ] || printf 'ghostty\toptional\t%s\tbuilt\t\tsha256:%s\n' "$H40" "$(printf 'c%.0s' {1..64})" >>"$1/COMPONENTS"
}
inst() { rm -rf "$dest"; env "$@" BINARIES_ROOT="$root/img" DESTDIR="$dest" bash "$here/build_files/install-binaries.sh" >"$root/run" 2>&1; rc=$?; }
dest="$root/dest"; lic="$dest/usr/share/licenses/octarine-os-binaries"
mkimg "$root/img"; inst X=1
check "installer: the ghostty tree goes under /usr (binary, desktop file, data), its records under the licenses directory, nothing is reported missing" bash -c "[ $rc = 0 ] && [ -x '$dest/usr/bin/ghostty' ] && [ -f '$dest/usr/share/applications/com.mitchellh.ghostty.desktop' ] && [ -s '$lic/ghostty/SOURCE' ] && [ -s '$lic/ghostty/ghostty-LICENSE' -o -s '$lic/ghostty/l' ] && [ ! -e '$lic/MISSING' ]"
NO_GHOSTTY=1 mkimg "$root/img"; inst X=1
check "installer: ghostty not in the image: a WARNING, an annotation and MISSING say it is NOT installed; the build goes on" bash -c "[ $rc = 0 ] && grep -q 'WARNING: optional component ghostty is not in the binaries image: it is NOT installed' '$root/run' && grep -q '^::warning::' '$root/run' && grep -q '^ghostty: not in the binaries image' '$lic/MISSING' && [ ! -e '$dest/usr/bin/ghostty' ] && [ -x '$dest/usr/bin/scx_rusty' ]"
mkimg "$root/img"; rm -rf "$dest"; mkdir -p "$dest/usr/bin"; echo mine >"$dest/usr/bin/ghostty"
env BINARIES_ROOT="$root/img" DESTDIR="$dest" bash "$here/build_files/install-binaries.sh" >"$root/run" 2>&1; rc=$?
check "installer: a file the image already has is never overwritten: ghostty is LEFT OUT with a warning and MISSING (an optional component never blocks the build), the existing file is untouched" bash -c "[ $rc = 0 ] && grep -q 'would overwrite usr/bin/ghostty' '$root/run' && grep -q 'LEFT OUT' '$root/run' && [ \"\$(cat '$dest/usr/bin/ghostty')\" = mine ] && grep -q '^ghostty: could not be installed' '$lic/MISSING' && [ ! -e '$dest/usr/share/applications/com.mitchellh.ghostty.desktop' ]"
mkimg "$root/img"; mkdir -p "$root/img/ghostty/root/usr/share/terminfo/g"; echo ti >"$root/img/ghostty/root/usr/share/terminfo/g/ghostty"; (cd "$root/img/ghostty/root" && find . -type f | sed 's#^\./##' | sort) >"$root/img/ghostty/FILES"
rm -rf "$dest"; mkdir -p "$dest/usr/share/terminfo/g"; echo base >"$dest/usr/share/terminfo/g/ghostty"
env BINARIES_ROOT="$root/img" DESTDIR="$dest" bash "$here/build_files/install-binaries.sh" >"$root/run" 2>&1; rc=$?
check "installer: a terminfo file the image already has (ncurses-term ships ghostty) is KEPT and skipped, everything else of ghostty is installed, no conflict" bash -c "[ $rc = 0 ] && grep -q 'kept the image.s own terminfo: usr/share/terminfo/g/ghostty' '$root/run' && [ \"\$(cat '$dest/usr/share/terminfo/g/ghostty')\" = base ] && [ -x '$dest/usr/bin/ghostty' ] && [ ! -e '$lic/MISSING' ]"
check "installer: the ghostty files are extracted into DESTDIR or, when DESTDIR is empty (the real image build), into / (tar -C with an empty string is not the root: the first real install put nothing at /usr/bin/ghostty)" bash -c "grep -q 'tar -C \"\\\${dest:-/}\" -xf -' '$here/build_files/install-binaries.sh'"
check "installer: after installing ghostty in the REAL build (empty DESTDIR) the hicolor icon cache and the desktop database are refreshed and the cache is checked for com.mitchellh.ghostty (the base's cache and directory share the epoch mtime, so a stale cache looks valid and the icon is not found); the smoke test checks the cache too" bash -c "i='$here/build_files/install-binaries.sh'; grep -q 'gtk-update-icon-cache gtk4-update-icon-cache' \$i && grep -q 'update-desktop-database -q /usr/share/applications' \$i && grep -q 'grep -aq com.mitchellh.ghostty /usr/share/icons/hicolor/icon-theme.cache' \$i && grep -q -- '-f -t /usr/share/icons/hicolor' \$i && grep -q 'hicolor/256x256/apps/com.mitchellh.ghostty.png && grep -aq com.mitchellh.ghostty /usr/share/icons/hicolor/icon-theme.cache' '$here/.github/workflows/build.yml'"
mkimg "$root/img"; echo '../../etc/passwd' >>"$root/img/ghostty/FILES"; inst X=1
check "installer: a FILES entry outside usr/ leaves ghostty out (nothing is written outside /usr)" bash -c "[ $rc = 0 ] && grep -q 'outside usr/' '$root/run' && [ ! -e '$dest/usr/bin/ghostty' ]"
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
check "installer: ghostty needs a library the image lacks (gtk4-layer-shell): ghostty is REMOVED again with a WARNING, a REMOVED record and the missing library named; scx and extest stay, the build succeeds" bash -c "[ $rc = 0 ] && grep -q 'libgtk4-layer-shell.so.0 => not found' '$root/run' && grep -q 'WARNING: optional component ghostty needs shared libraries' '$root/run' && [ ! -e '$dest/usr/bin/ghostty' ] && [ ! -e '$dest/usr/share/applications/com.mitchellh.ghostty.desktop' ] && grep -q '^ghostty: removed' '$lic/REMOVED' && [ -x '$dest/usr/bin/scx_rusty' ]"
inst BINARIES_CHECK_NEEDED=1 BINARIES_LDD="$bin/ldd-ok"
check "installer: with every library present ghostty stays installed" bash -c "[ $rc = 0 ] && [ -x '$dest/usr/bin/ghostty' ] && grep -q 'runtime libraries of ghostty: all found' '$root/run' && [ ! -e '$lic/REMOVED' ]"

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
setpin v1.4.0 0.17.1; reply; tagsfile v1.4.0 v1.5.0-rc1 v1.5.0-rc2 tip vt-1.0.2 vt-1.1.0; zi 0.17.0 0.17.1 0.17.2; newc v1.4.0 0.17.0
out=$(chk)
check "check: pre-releases, tip and vt-* tags are ignored (and the same-tag run still finds the newer Zig patch: zigbump)" bash -c "[ \"$out\" = \"zigbump 0.17.2 https://ziglang.org/download/0.17.2/zig-x86_64-linux-0.17.2.tar.xz $zsh2 123\" ]"
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
setpin v1.4.0 0.17.1; reply; tagsfile v1.4.0; zi 0.17.0 0.17.1; newc v1.4.0 0.17.2
out=$(chk)
check "check: the pinned Zig is below the minimum of the pinned tag: no zigbump is offered below it" bash -c "[[ \"$out\" == current* ]]"
setpin v1.4.0 0.16.0; reply; tagsfile v1.4.0; zi 0.17.0 0.17.1; newc v1.4.0 0.17.0
out=$(chk)
check "check: a pinned Zig of another minor than the tag requires is reported unreachable (fix by hand), not auto-bumped" bash -c "[[ \"$out\" == unreachable* ]]"
setpin v1.4.0 0.17.1; reply; zi 0.17.1
check "check: the tags API failing is unreachable (fail soft, exit 0)" bash -c "[[ \"\$(PATH='$bin:$PATH' REPO_ROOT='$cr' ZIG_INDEX_FILE='$root/idx.json' bash '$cr/.github/scripts/ghostty-check.sh'; echo rc=\$?)\" == *unreachable*rc=0 ]]"
reply; tagsfile v1.4.0 v1.5.0; newc v1.5.0 0.17.0; echo 'not json' >"$root/idx.json"
out=$(chk)
check "check: an unreadable index.json is unreachable" bash -c "[[ \"$out\" == unreachable* ]]"
! grep -qE 'gh (pr|repo|release) |--method|-X ' "$GH_LOG" && ok "check: only reads (gh api GET)" || bad "check wrote something"

# ---- bump-ghostty.sh: a local origin and a stub gh
origin="$root/origin.git"; git init -q --bare -b testing "$origin"
wc="$root/wc"; mkdir -p "$wc/binaries/lib" "$wc/binaries/ghostty" "$wc/.github/scripts"
cp "$here/binaries/lib/upstream-env.sh" "$wc/binaries/lib/"; cp "$here/.github/scripts/bump-ghostty.sh" "$wc/.github/scripts/"
cp "$g/upstream.env" "$g/zig.env" "$wc/binaries/ghostty/"
git -C "$wc" init -q -b testing; git -C "$wc" add -A; git -C "$wc" commit -q -m base; git -C "$wc" remote add origin "$origin"; git -C "$wc" push -q origin testing
cat >"$bin/gh" <<'F'
#!/usr/bin/env bash
echo "gh $*" >>"$GH_LOG"
case "$1 $2" in
    "pr list") cat "${PR_LIST:-/dev/null}" ;;
    "pr create"|"pr edit") exit 0 ;;
    "workflow run") [ -z "${GH_WF_FAIL:-}" ] ;;
    *) exit 99 ;;
esac
F
Z2=https://ziglang.org/download/0.17.2/zig-x86_64-linux-0.17.2.tar.xz; Z3=https://ziglang.org/download/0.18.0/zig-x86_64-linux-0.18.0.tar.xz
bump() { PR_LIST="$root/prlist" PATH="$bin:$PATH" REPO_ROOT="$wc" bash "$wc/.github/scripts/bump-ghostty.sh" "$@" >"$root/run" 2>&1; rc=$?; }
: >"$root/prlist"; : >"$GH_LOG"
bump ghostty v1.5.0 "$(sha d)" 0.18.0 "$Z3" "$(printf 'e%.0s' {1..64})" 777
check "bump ghostty: one PR from bump/ghostty into testing, titled with the tag and the Zig version; the Test workflow is dispatched on the branch" bash -c "[ $rc = 0 ] && grep -q '^gh pr create --base testing --head bump/ghostty --title Bump ghostty to v1.5.0 (Zig 0.18.0)' '$GH_LOG' && grep -qx 'gh workflow run test.yml --ref bump/ghostty' '$GH_LOG'"
check "bump ghostty: upstream.env AND zig.env change in the same branch (tag, peeled commit, Zig version, URL, sha256, size, signature URL; the minisign key and the comments stay), nothing else" bash -c "
  [ \"\$(git -C '$origin' diff --name-only testing bump/ghostty | sort | tr '\n' ' ')\" = 'binaries/ghostty/upstream.env binaries/ghostty/zig.env ' ] &&
  z=\$(git -C '$origin' show bump/ghostty:binaries/ghostty/zig.env) && grep -qx 'ZIG_VERSION=0.18.0' <<<\"\$z\" && grep -qx 'ZIG_URL=$Z3' <<<\"\$z\" && grep -qx 'ZIG_SHA256=$(printf 'e%.0s' {1..64})' <<<\"\$z\" &&
  grep -qx 'ZIG_SIGNATURE_URL=$Z3.minisig' <<<\"\$z\" && grep -qx 'ZIG_MINISIGN_KEY=$key' <<<\"\$z\" && grep -q '^# ' <<<\"\$z\" &&
  u=\$(git -C '$origin' show bump/ghostty:binaries/ghostty/upstream.env) && grep -qx 'UPSTREAM_TAG=v1.5.0' <<<\"\$u\" && grep -qx 'UPSTREAM_COMMIT=$(sha d)' <<<\"\$u\""
printf '{"number":4,"title":"Bump ghostty to v1.5.0 (Zig 0.18.0)"}\n' >"$root/prlist"; : >"$GH_LOG"
bump ghostty v1.5.0 "$(sha d)" 0.18.0 "$Z3" "$(printf 'e%.0s' {1..64})" 777
check "bump ghostty: a PR for exactly this version is already open: nothing happens" bash -c "[ $rc = 0 ] && ! grep -qE '^gh (pr (create|edit)|workflow run)' '$GH_LOG'"
printf '{"number":4,"title":"Bump ghostty to v1.5.0 (Zig 0.18.0)"}\n' >"$root/prlist"; : >"$GH_LOG"
bump ghostty v1.5.1 "$(sha f)" 0.18.0 "$Z3" "$(printf 'e%.0s' {1..64})" 777
check "bump ghostty: an older bump PR is updated (edit, a new commit on the same branch, never a force-push), not duplicated" bash -c "[ $rc = 0 ] && grep -q '^gh pr edit 4 --title Bump ghostty to v1.5.1' '$GH_LOG' && [ \"\$(git -C '$origin' log --format=%s testing..bump/ghostty | wc -l)\" -ge 2 ] && ! git -C '$origin' log --format=%B bump/ghostty | grep -qi 'co-authored-by'"
: >"$root/prlist"; : >"$GH_LOG"
bump zig 0.17.2 "$Z2" "$(printf 'd%.0s' {1..64})" 555
check "bump zig: a SEPARATE low-priority PR from bump/zig that changes only zig.env (upstream.env is untouched) and says it is low priority" bash -c "[ $rc = 0 ] && grep -q '^gh pr create --base testing --head bump/zig --title Bump the Ghostty Zig toolchain to 0.17.2' '$GH_LOG' && [ \"\$(git -C '$origin' diff --name-only testing bump/zig)\" = binaries/ghostty/zig.env ] && grep -q 'LOW PRIORITY' '$GH_LOG'"
: >"$GH_LOG"; bump zig 0.17.2 "https://example.org/zig.tar.xz" "$(printf 'd%.0s' {1..64})" 555
check "bump: Zig arguments that are not an official ziglang.org x86_64-linux entry are refused before anything is touched" bash -c "[ $rc = 2 ] && ! grep -q '^gh pr' '$GH_LOG'"
: >"$GH_LOG"; bump other 1 2 3 4
check "bump: an unknown mode is refused" test "$rc" = 2

# ---- the workflow and the documentation of the update path
check "upstream-check.yml: the generic loop skips ghostty, which has its own step (ghostty-check.sh, bump-ghostty.sh for a Ghostty bump and a Zig bump), a wait is a notice and says so in the summary, nothing is published" python3 -I - "$here" <<'PY'
import sys, yaml
t = open(sys.argv[1] + "/.github/workflows/upstream-check.yml").read()
assert "[[ \"${dir}\" != binaries/ghostty ]] || continue" in t
for n in ("ghostty-check.sh", "bump-ghostty.sh ghostty", "bump-ghostty.sh zig", "wait)", "unreachable)", "echo \"- \\`binaries/ghostty\\`: ${decision}\" >> \"${GITHUB_STEP_SUMMARY}\""):
    assert n in t, n
assert "packages: write" not in t and "podman" not in t and "cosign" not in t
yaml.safe_load(t)
PY
check "CLAUDE.md documents the update path: the Ghostty tag decides the Zig minor, a patch bump is separate and low priority, a missing Zig tarball opens nothing" bash -c "grep -q 'Ghostty tag decides the Zig minor' '$here/CLAUDE.md' && grep -q 'bump/zig' '$here/CLAUDE.md' && grep -q 'ghostty-check.sh' '$here/CLAUDE.md'"

echo
echo "passed: $pass, failed: $failn"
[ "$failn" = 0 ]
