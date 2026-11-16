#!/usr/bin/env bash
# Tests for the EXPERIMENTAL second launcher `ojust` (system_files/usr/bin/ojust, root justfile system_files/usr/share/octarine-os/justfile): its
# root parses without any file of Universal Blue's ublue-os-just package, imports none of them, lists the same custom recipes as ujust, ujust's
# wrapper files still give ujust the same recipes, and nothing user-facing mentions it. The files are copied into a temp tree and the absolute
# /usr paths rewritten; nothing real is touched. Needs: bash, just, jq. Run: tests/ojust.sh
# shellcheck disable=SC2016
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
root=$(mktemp -d)
trap 'rm -rf -- "$root"' EXIT
pass=0; failn=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { failn=$((failn + 1)); echo "FAIL $1"; [ -f "$root/out" ] && sed 's/^/     /' "$root/out" | head -20; }
check() { local d=$1; shift; if "$@" >"$root/out" 2>&1; then ok "$d"; else bad "$d"; fi; }
sf="$here/system_files"; dxd="$here/variants/dx/system_files"

# the image layout in a temp tree: ours, the dx files, and (for ujust) stub copies of the package's files that build.sh renames
mk() { # dir with_base
    local t=$1 f
    mkdir -p "$t/usr/share/ublue-os/just" "$t/usr/share/octarine-os/just" "$t/usr/bin"
    cp "$sf"/usr/share/ublue-os/just/*.just "$dxd"/usr/share/ublue-os/just/*.just "$t/usr/share/ublue-os/just/"
    cp "$sf"/usr/share/octarine-os/just/*.just "$sf/usr/share/octarine-os/justfile" "$t/usr/share/octarine-os/" 2>/dev/null
    mv "$t/usr/share/octarine-os/justfile" "$t/usr/share/octarine-os/justfile.tmp"; mv "$t/usr/share/octarine-os/"*.just "$t/usr/share/octarine-os/just/" 2>/dev/null
    mv "$t/usr/share/octarine-os/justfile.tmp" "$t/usr/share/octarine-os/justfile"
    cp "$sf/usr/bin/ojust" "$t/usr/bin/"
    if [ "$2" = 1 ]; then
        printf 'toggle-user-motd:\n    echo base\n\nbios:\n    echo base\n' >"$t/usr/share/ublue-os/just/00-default-base.just"
        printf 'alias upgrade := update\n\nupdate:\n    echo base\n\nchangelogs:\n    echo base\n\ntoggle-updates:\n    echo base\n' >"$t/usr/share/ublue-os/just/10-update-base.just"
        printf '[private]\nsetup-distrobox-app:\n    echo base\n\ndistrobox-new:\n    echo base\n' >"$t/usr/share/ublue-os/just/30-distrobox-base.just"
        printf 'clean-system:\n    echo base\n' >"$t/usr/share/ublue-os/just/20-clean.just"
        { printf 'set allow-duplicate-recipes := true\nset ignore-comments := true\n\n_default:\n    echo base\n\nimport "/usr/share/ublue-os/just/00-default.just"\nimport "/usr/share/ublue-os/just/10-update.just"\nimport "/usr/share/ublue-os/just/15-luks.just"\nimport "/usr/share/ublue-os/just/20-clean.just"\nimport "/usr/share/ublue-os/just/30-distrobox.just"\nimport "/usr/share/ublue-os/just/40-nvidia.just"\nimport "/usr/share/ublue-os/just/50-akmods.just"\nimport? "/usr/share/ublue-os/just/60-custom.just"\nimport? "/usr/share/ublue-os/just/70-octarine-dev.just"\nimport? "/usr/share/ublue-os/just/72-octarine-datastore.just"\nimport? "/usr/share/ublue-os/just/75-octarine-virthost.just"\n'; } >"$t/usr/share/ublue-os/justfile"
    fi
    for f in $(grep -rlE '/usr/share/(ublue-os|octarine-os)' "$t"); do sed -i "s|/usr/share/|$t/usr/share/|g" "$f"; done
}
nb="$root/nobase"; wb="$root/withbase"
mk "$nb" 0; mk "$wb" 1
oj="$nb/usr/share/octarine-os/justfile"; uj="$wb/usr/share/ublue-os/justfile"

check "ojust root parses (just --list, --summary) with NO file of the ublue-os-just package present (not even the renamed *-base.just files)" bash -c "ls '$nb/usr/share/ublue-os/just' | grep -q -- -base && exit 1; just --justfile '$oj' --list && just --justfile '$oj' --summary"
check "ojust imports only the image's own files: no *-base.just, none of the package's wrapper files (00-default, 10-update, 30-distrobox), no 20-clean" bash -c "
  imports=\$(grep -hE '^import' '$sf/usr/share/octarine-os/justfile' '$sf'/usr/share/octarine-os/just/*.just | sed 's/^import? */import /' | sort -u)
  ! grep -q -- '-base.just' <<<\"\$imports\" && ! grep -qE '00-default.just|10-update.just|30-distrobox.just|20-clean.just' <<<\"\$imports\" &&
  grep -q 'octarine-os/just/motd.just' <<<\"\$imports\" && grep -q '60-custom.just' <<<\"\$imports\""
check "no recipe file ojust imports sources a helper of the package (/usr/lib/ujust) or needs ugum to run" bash -c "! grep -lE '/usr/lib/ujust|libformatting|libcolors' '$sf/usr/share/octarine-os/justfile' '$sf'/usr/share/octarine-os/just/*.just '$sf'/usr/share/ublue-os/just/{15-luks,40-nvidia,50-akmods,60-custom}.just '$dxd'/usr/share/ublue-os/just/*.just"
check "the image's own recipes show up in ojust: toggle-motd, toggle-updates, update, niri-setup, user-setup, toolbox, plus the copied pieces (bios, changelogs, update-firmware, clean-system)" bash -c "s=\$(just --justfile '$oj' --summary); for r in toggle-motd toggle-user-motd toggle-updates update niri-setup user-setup toolbox switch-image bios changelogs update-firmware clean-system; do grep -qw \$r <<<\"\$s\" || { echo missing \$r; exit 1; }; done"
check "ojust and ujust list the same custom recipes: every recipe defined in the image's own files is in both lists" bash -c "
  o=\$(just --justfile '$oj' --summary); u=\$(just --justfile '$uj' --summary)
  for f in '$sf'/usr/share/ublue-os/just/60-custom.just '$sf'/usr/share/ublue-os/just/15-luks.just '$sf'/usr/share/ublue-os/just/40-nvidia.just '$sf'/usr/share/octarine-os/just/motd.just '$sf'/usr/share/octarine-os/just/update.just '$dxd'/usr/share/ublue-os/just/70-octarine-dev.just; do
    for r in \$(just --justfile \$f --summary 2>/dev/null || grep -oE '^[a-z][a-z0-9-]*' \$f | sort -u); do :; done
  done
  mine=\$(grep -hoE '^[a-z][a-z0-9-]*( \\*?[A-Za-z_=\"-]+)*:' '$sf'/usr/share/ublue-os/just/60-custom.just '$sf'/usr/share/octarine-os/just/motd.just '$sf'/usr/share/octarine-os/just/update.just | sed 's/[ :].*//' | sort -u)
  for r in \$mine; do
    grep -qw \$r <<<\"\$o\" && grep -qw \$r <<<\"\$u\" || { case \$r in _*) ;; *) echo \"not in both: \$r\"; exit 1 ;; esac; }
  done"
check "what only ujust has: the package's distrobox and power helpers (distrobox-new, install-resolve, check-idle-power-draw are not copied; their stubs here: distrobox-new)" bash -c "u=\$(just --justfile '$uj' --summary); o=\$(just --justfile '$oj' --summary); grep -qw distrobox-new <<<\"\$u\" && ! grep -qw distrobox-new <<<\"\$o\""
check "ujust is unchanged by the split: toggle-motd, toggle-user-motd, toggle-updates and update are the image's recipes (not the base stubs), identical in ujust and ojust (bodies, parameters, attributes)" bash -c "
  for r in toggle-motd toggle-user-motd toggle-updates update; do
    a=\$(just --justfile '$uj' --dump --dump-format json | jq -c --arg r \$r '.recipes[\$r] | del(.namepath)' | sed 's|$wb||g')
    b=\$(just --justfile '$oj' --dump --dump-format json | jq -c --arg r \$r '.recipes[\$r] | del(.namepath)' | sed 's|$nb||g')
    [ -n \"\$a\" ] && [ \"\$a\" = \"\$b\" ] && ! grep -q 'echo base' <<<\"\$a\" || { echo differs: \$r; exit 1; }
  done"
check "ujust keeps the package's other recipes through the wrapper files (changelogs, bios, distrobox-new, clean-system, the aliases)" bash -c "s=\$(just --justfile '$uj' --summary); for r in changelogs bios distrobox-new clean-system; do grep -qw \$r <<<\"\$s\" || { echo missing \$r; exit 1; }; done; just --justfile '$uj' --dump --dump-format json | jq -e '.aliases | has(\"upgrade\")' >/dev/null"
check "the ujust wrapper files import the own files FIRST and the base file second (the first import wins)" bash -c "for f in 00-default:motd:00-default-base 10-update:update:10-update-base; do w=\${f%%:*}; r=\${f#*:}; own=\${r%%:*}; base=\${r#*:}; a=\$(grep -n 'octarine-os/just/'\$own'.just' '$sf/usr/share/ublue-os/just/'\$w'.just' | head -1 | cut -d: -f1); b=\$(grep -n '\"'\$base'.just\"' '$sf/usr/share/ublue-os/just/'\$w'.just' | head -1 | cut -d: -f1); [ -n \"\$a\" ] && [ -n \"\$b\" ] && [ \$a -lt \$b ] || exit 1; done"
check "the aliases of the package's files are re-created for ojust (upgrade, changelog, auto-update) and resolve" bash -c "just --justfile '$oj' --dump --dump-format json | jq -e '.aliases | has(\"upgrade\") and has(\"changelog\") and has(\"auto-update\")' >/dev/null"
# the launcher
mkdir -p "$root/stub"; printf '#!/usr/bin/env bash\necho "just JUST_JUSTFILE=$JUST_JUSTFILE OCTARINE_UJUST=$OCTARINE_UJUST args=$*"\n' >"$root/stub/just"; chmod +x "$root/stub/just"
check "launcher: ojust runs just with JUST_JUSTFILE=/usr/share/octarine-os/justfile (the same mechanism ujust uses) and OCTARINE_UJUST=/usr/bin/ojust, arguments passed through" bash -c "out=\$(OJUST_JUST='$root/stub/just' bash '$sf/usr/bin/ojust' --list foo); [[ \"\$out\" == *'JUST_JUSTFILE=/usr/share/octarine-os/justfile'* && \"\$out\" == *'OCTARINE_UJUST=/usr/bin/ojust'* && \"\$out\" == *'args=--list foo'* ]]"
check "launcher: with the real just ojust --list works and prints the image's recipes" bash -c "OJUST_JUSTFILE='$oj' bash '$sf/usr/bin/ojust' --list | grep -q toggle-motd"
check "launcher: with no argument ojust prints its own list (Available commands), no Universal Blue documentation link" bash -c "mkdir -p '$root/bin2'; sed 's|/usr/bin/ojust|$root/bin2/ojust|' '$sf/usr/bin/ojust' >'$root/bin2/ojust'; chmod +x '$root/bin2/ojust'; sed -i 's|OCTARINE_UJUST:-[^}]*|OCTARINE_UJUST:-$root/bin2/ojust|' '$oj'; out=\$(OJUST_JUSTFILE='$oj' '$root/bin2/ojust'); grep -q 'Available commands' <<<\"\$out\" && grep -q ' - toggle-motd' <<<\"\$out\" && ! grep -qiE 'universal blue|projectbluefin|Click here' <<<\"\$out\""
check "ojust is executable in git (100755) and the launcher parses" bash -c "bash -n '$sf/usr/bin/ojust' && git -C '$here' ls-files -s system_files/usr/bin/ojust | grep -q '^100755'"
# hardware-setup calls ujust itself: with OCTARINE_UJUST the calls stay in ojust
check "recipes that call ujust themselves honor OCTARINE_UJUST (hardware-setup), which ojust sets" bash -c "grep -q 'ujust_cmd=\${OCTARINE_UJUST:-ujust}' '$sf/usr/share/ublue-os/just/60-custom.just'"
# not documented
check "ojust is mentioned in no README, doc, recipe comment, completion, MOTD or workflow text: only its own files, the smoke checks, this test and the one maintainer note in CLAUDE.md" bash -c "
  cd '$here'; ! grep -rIl ojust README.md docs system_files variants .github/scripts 2>/dev/null | grep -vE '^system_files/usr/bin/ojust\$|^system_files/usr/share/octarine-os/justfile\$|^system_files/usr/share/octarine-os/just/base-pieces.just\$' ;
  [ \"\$(grep -c ojust CLAUDE.md)\" -ge 1 ] && [ \"\$(grep -n '^## ' CLAUDE.md | awk -F: '/ojust/' | wc -l)\" = 0 ]"
check "ujust --list does not offer ojust (no recipe of that name) and the wrapper recipes carry no mention" bash -c "! just --justfile '$uj' --summary | grep -qw ojust"
check "the default smoke test checks ojust" grep -q 'experimental second launcher runs' "$here/.github/scripts/default-smoke.sh"
echo
echo "passed: $pass, failed: $failn"
[ "$failn" = 0 ]
