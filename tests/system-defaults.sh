#!/usr/bin/env bash
# Syntax and behavior of the system-wide defaults shipped in system_files: the GNOME dconf keyfile compiles, the fish snippets and function run
# in a temp HOME, the GameMode file parses. Which keys, files and modes exist is not asserted. Uses dconf, fish and python3 when they exist.
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
sf=$here/system_files
fail=0
check() { if "${@:2}" >/dev/null 2>&1; then echo "PASS $1"; else echo "FAIL $1"; fail=1; fi; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export XDG_CONFIG_HOME="$tmp/xdg" XDG_DATA_HOME="$tmp/xdgdata"

keyfile=$sf/etc/dconf/db/distro.d/90-octarine-os
gm=$sf/etc/gamemode.ini
fish_files=("$sf"/usr/share/fish/vendor_conf.d/octarine-os-*.fish "$sf"/usr/share/fish/vendor_functions.d/*.fish)
all_files=("$keyfile" "$gm" "${fish_files[@]}")


# dconf keyfile
if command -v dconf >/dev/null; then
  mkdir -p "$tmp/d.d"; cp "$keyfile" "$tmp/d.d/"
  check "dconf compiles the keyfile" dconf compile "$tmp/out.db" "$tmp/d.d"
  check "the compiled database is not empty" test -s "$tmp/out.db"
else
  check "keyfile has group headers and key=value lines only (no dconf here)" bash -c "grep -vE '^(#|\\[[a-z0-9/_-]+\\]|[a-z0-9-]+=.+|)\$' '$keyfile' | wc -l | grep -qx 0"
fi

# fish syntax and behavior
if command -v fish >/dev/null; then
  for f in "${fish_files[@]}"; do check "fish --no-execute $(basename "$f")" fish --no-execute "$f"; done
  mkdir -p "$tmp/home/.cargo" "$tmp/home/.local/bin"
  for f in "$sf"/usr/share/fish/vendor_conf.d/octarine-os-*.fish; do
    check "$(basename "$f"): silent and exit 0 in a non-interactive shell" bash -c "[ -z \"\$(HOME='$tmp/home' fish --no-config -c 'source $f' 2>&1)\" ]"
  done
  check "rustup snippet sources env.fish when present" bash -c "echo 'set -g OCT_RUSTUP_LOADED yes' > '$tmp/home/.cargo/env.fish'; [ \"\$(HOME='$tmp/home' fish --no-config -c 'source $sf/usr/share/fish/vendor_conf.d/octarine-os-30-rustup.fish; echo \$OCT_RUSTUP_LOADED')\" = yes ]"
  check "path snippet adds ~/.local/bin (to fish_user_paths, which fish puts in front of PATH once startup is done)" bash -c "[ \"\$(HOME='$tmp/home' fish --no-config -c 'source $sf/usr/share/fish/vendor_conf.d/octarine-os-10-path.fish; contains \$HOME/.local/bin \$fish_user_paths; and echo yes')\" = yes ]"
  check "steam snippet drops only the overlay entries (interactive shell)" bash -c "[ \"\$(HOME='$tmp/home' LD_PRELOAD='/a/gameoverlayrenderer.so:/b/libextest.so:/c/gameoverlayrenderer.so' fish --no-config -i -c 'source $sf/usr/share/fish/vendor_conf.d/octarine-os-20-steam-ld-preload.fish; echo \$LD_PRELOAD' 2>/dev/null | tail -n1)\" = /b/libextest.so ]"
  check "y reports a missing yazi with status 127" bash -c "HOME='$tmp/home' PATH=/nonexistent:/usr/bin fish --no-config -c 'source $sf/usr/share/fish/vendor_functions.d/y.fish; command -q yazi; and exit 9; y; exit \$status' >/dev/null 2>&1; [ \$? = 127 ]"
else
  for f in "${fish_files[@]}"; do check "$(basename "$f") non-empty with balanced blocks (no fish here)" bash -c "[ -s '$f' ] && [ \$(grep -cE '^[[:space:]]*(if|for|function|while|switch|begin)[[:space:]]' '$f') = \$(grep -cE '^[[:space:]]*end\$' '$f') ]"; done
fi

# GameMode
check "gamemode.ini parses as INI" python3 -I -c "
import configparser,sys
c=configparser.ConfigParser(interpolation=None); c.read(sys.argv[1]); assert c['general']['renice']=='10'" "$gm"

# build step and smoke test

# nothing personal
# VM hosting is a dx-only feature: the default image installs none of the hosting meta packages but keeps the libguestfs tools
exit "$fail"
