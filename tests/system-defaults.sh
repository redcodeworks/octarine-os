#!/usr/bin/env bash
# Tests the system-wide defaults shipped in system_files: the GNOME dconf keyfile, the fish vendor snippets and function,
# and the generic GameMode file. Placement and modes, syntax (dconf compile, fish --no-execute, INI parse), behavior of
# the fish snippets in a temp HOME, the build step and the smoke checks, and that no personal setting slipped in.
# Uses dconf, fish and python3 when they exist; without them the syntax checks fall back to plain greps.
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

# placement and modes (git tracks only 644 and 755)
check "keyfile is in distro.d with a numeric prefix" test -f "$keyfile"
check "at least three fish conf.d snippets named octarine-os-NN-*.fish" bash -c "[ \$(ls '$sf'/usr/share/fish/vendor_conf.d/octarine-os-[0-9][0-9]-*.fish | wc -l) -ge 3 ]"
check "the fish function file is named after its function" bash -c "grep -q '^function y ' '$sf/usr/share/fish/vendor_functions.d/y.fish'"
check "vendor_functions.d holds only .fish files" bash -c "[ -z \"\$(ls '$sf/usr/share/fish/vendor_functions.d' | grep -v '\\.fish\$')\" ]"
check "no file is executable (git mode 100644)" bash -c "cd '$here' && ! git ls-files -s system_files/etc/dconf system_files/etc/gamemode.ini system_files/usr/share/fish | grep -v '^100644'"
check "nothing is shipped in /etc/fish (config.fish stays the user's and the package's)" bash -c "[ ! -e '$sf/etc/fish' ]"
check "no dconf lock files are shipped" bash -c "[ ! -e '$sf/etc/dconf/db/distro.d/locks' ] && [ \$(ls '$sf/etc/dconf/db/distro.d' | wc -l) = 1 ]"

# dconf keyfile
if command -v dconf >/dev/null; then
  mkdir -p "$tmp/d.d"; cp "$keyfile" "$tmp/d.d/"
  check "dconf compiles the keyfile" dconf compile "$tmp/out.db" "$tmp/d.d"
  check "the compiled database is not empty" test -s "$tmp/out.db"
else
  check "keyfile has group headers and key=value lines only (no dconf here)" bash -c "grep -vE '^(#|\\[[a-z0-9/_-]+\\]|[a-z0-9-]+=.+|)\$' '$keyfile' | wc -l | grep -qx 0"
fi
check "enabled-extensions keeps the packaged default (background-logo) first" grep -q "^enabled-extensions=\['background-logo@fedorahosted.org'," "$keyfile"
check "extensions enabled are only ones the image ships (appindicator, gsconnect)" bash -c "grep '^enabled-extensions=' '$keyfile' | grep -o '[A-Za-z0-9.-]*@[a-zA-Z0-9.-]*' | sort | tr '\n' ' ' | grep -qx 'appindicatorsupport@rgcjonas.gmail.com background-logo@fedorahosted.org gsconnect@andyholmes.github.io '"
check "GPaste is shipped but not enabled by default" bash -c "! grep -qi gpaste '$keyfile'"
check "GPaste is in the misc optional group of build.sh" grep -q "^    \"misc:.* gpaste gnome-shell-extension-gpaste " "$here/build_files/build.sh"

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
check "every conf.d snippet is interactive-guarded or only sets PATH/sources a guarded file" bash -c "cd '$sf/usr/share/fish/vendor_conf.d' && for f in octarine-os-*.fish; do grep -qE 'status is-interactive|fish_add_path|test -r' \$f || exit 1; done"
check "the function guards on command -q yazi" grep -q 'command -q yazi' "$sf/usr/share/fish/vendor_functions.d/y.fish"
check "every snippet tells the user how to disable it" bash -c "for f in '$sf'/usr/share/fish/vendor_conf.d/octarine-os-*.fish; do grep -q 'empty file of the same name' \$f || exit 1; done"

# GameMode
check "gamemode.ini parses as INI" python3 -I -c "
import configparser,sys
c=configparser.ConfigParser(interpolation=None); c.read(sys.argv[1]); assert c['general']['renice']=='10'" "$gm"
check "gamemode.ini sets nothing hardware specific (no governor, tuned or GPU keys)" bash -c "! grep -E '^[^;#[:space:]].*(desiredgov|tuned|gpu_device|amd_performance|nv_)' '$gm' && ! grep -q '^\\[custom\\]' '$gm'"

# build step and smoke test
check "build.sh runs dconf update after copying system_files" bash -c "a=\$(grep -n 'cp -avf' '$here/build_files/build.sh' | head -1 | cut -d: -f1); b=\$(grep -n '^dconf update' '$here/build_files/build.sh' | cut -d: -f1); [ -n \"\$b\" ] && [ \"\$b\" -gt \"\$a\" ]"
for wf in build.yml build-beta.yml; do
  check "$wf smoke test checks the dconf database, fish files and gamemode defaults" bash -c "w='$here/.github/workflows/$wf'; grep -q 'dconf distro database is newer' \$w && grep -q 'fish --no-execute' \$w && grep -q 'gamemode defaults file shipped' \$w"
done

# nothing personal
check "no excluded category in the shipped files (theme names, key model, editor, personal names and paths)" bash -c "! grep -nEi 'gruvbox|papirus|helix|\\bhx\\b|/home/kevin|/var/home/|nox|asgard|kevin|riley' $keyfile $gm ${fish_files[*]} && ! grep -nE '\\bMEH\\b|\\bHYPR\\b' $keyfile $gm ${fish_files[*]}"
check "no theme, icon, cursor or font key in the keyfile" bash -c "! grep -E '^(gtk-theme|icon-theme|cursor-theme|monospace-font-name|font-name|color-scheme|name)=' '$keyfile'"
check "no keybinding group in the keyfile" bash -c "! grep -Ei 'keybindings|\\[org/gnome/desktop/wm|tilingshell|arcmenu|dash-to-dock|auto-move' '$keyfile'"
exit "$fail"
