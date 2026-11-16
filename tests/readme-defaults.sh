#!/usr/bin/env bash
# Tests for the README and docs/CONFIG-GUIDE.md against the repo (every public recipe is listed, every recipe they name
# exists, the image URLs and the build-status workflow files exist) and for how zsh ships (installed, not the default of
# new users). Prose, headings and counts are not asserted. Run: tests/readme-defaults.sh
# Needs: bash, grep, awk. Run: tests/readme-defaults.sh
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$here/..
readme=$repo/README.md
pass=0
failn=0
check() { # description, command...
    local d=$1; shift
    if "$@" >/dev/null 2>&1; then echo "PASS $d"; pass=$((pass + 1)); else echo "FAIL $d"; failn=$((failn + 1)); fi
}
check "the Fork it heading AGENTS.md links to still exists" bash -c "grep -q '^### Fork it' '$readme' && grep -q 'README.md#fork-it' '$repo/AGENTS.md'"
# ---- the README keeps the heading AGENTS.md links to, and every workflow its badges name exists
check "the Fork it heading AGENTS.md links to still exists" bash -c "grep -q '^### Fork it' '$readme' && grep -q 'README.md#fork-it' '$repo/AGENTS.md'"
check "every workflow file a README badge names exists" bash -c "for w in \$(grep -oE 'actions/workflows/[a-z0-9-]+\\.yml' '$readme' | sort -u | sed 's#actions/workflows/##'); do test -f '$repo/.github/workflows/'\$w || { echo missing \$w; exit 1; }; done"

# ---- recipes: every public recipe of the shipped recipe files is listed, marked DX only where dx-only
recipes() { grep -hE '^[a-z][a-z0-9-]* (\*args)?:$' "$@" | sed -E 's/ .*//; s/:$//'; }
default_recipes=$(recipes "$repo/system_files/usr/share/ublue-os/just/60-custom.just" "$repo/system_files/usr/share/octarine-os/just/update.just")
dx_recipes=$(recipes "$repo"/variants/dx/system_files/usr/share/ublue-os/just/*.just)
check "the recipe scan finds recipes (a scan that finds none would make the loops below pass vacuously)" bash -c "[ -n \"\$(echo '$default_recipes')\" ] && [ -n \"\$(echo '$dx_recipes')\" ]"
for r in $default_recipes; do
    check "README lists ujust $r" grep -qF "ujust $r" "$readme"
done
for r in $dx_recipes; do
    check "README lists ujust $r as DX only" grep -qE "ujust $r.*\(DX only\)" "$readme"
done
names_only_real_recipes() { # files whose "ujust <recipe>" mentions must name a recipe that exists
    local r known; known=" $(echo $default_recipes $dx_recipes) list enroll-secure-boot-key toggle-motd toggle-user-motd "
    for r in $(grep -hoE 'ujust [a-z][a-z-]*' "$@" | sed 's/ujust //' | sort -u); do
        case "$known" in *" $r "*) ;; *) echo "unknown recipe $r"; return 1 ;; esac
    done
}
check "the README names no recipe that does not exist (enroll-secure-boot-key is the base's, toggle-motd is in 00-default.just)" names_only_real_recipes "$readme"
check "docs/CONFIG-GUIDE.md names no recipe that does not exist" names_only_real_recipes "$repo/docs/CONFIG-GUIDE.md"

# ---- variants: the image names in the table exist in the repo
for img in octarine-os octarine-os-nvidia octarine-os-dx octarine-os-nvidia-dx; do
    check "README has the URL of $img" grep -qF "ghcr.io/redcodeworks/$img:latest" "$readme"
done
# ---- iommu=pt: no image ships it (opt-in through ujust virthost-setup): asserted in the built images by default-smoke.sh and dx-smoke.sh

# ---- zsh: installed, not the default of new users
check "build.sh still installs zsh and lists it in /etc/shells (the shell step needs it)" bash -c "grep -q 'steam-devices zsh' '$repo/build_files/build.sh' && grep -q 'echo /usr/bin/zsh >> /etc/shells' '$repo/build_files/build.sh'"
check "build.sh does not rewrite /etc/default/useradd" bash -c "! grep -E '^[^#]*(sed|echo|cat|tee).*useradd' '$repo/build_files/build.sh'"
check "build.sh fails the build if zsh were the default" grep -q "must not be the default shell" "$repo/build_files/build.sh"
check "dx-smoke.sh asserts zsh is not the default" grep -q 'new users do not default to zsh' "$repo/.github/scripts/dx-smoke.sh"
check "the opt-in path exists: user-setup has the shell step" grep -q '"shell^Login shell zsh' "$repo/system_files/usr/share/ublue-os/just/60-custom.just"
check "no file ships a useradd default" test ! -e "$repo/system_files/etc/default/useradd"

echo "== $pass passed, $failn failed"
[ "$failn" = 0 ]
