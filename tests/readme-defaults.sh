#!/usr/bin/env bash
# Tests for the README (structure, removed sections, recipe and variant claims against the repo) and for how zsh and
# the iommu=pt kernel argument ship: neither is in the default image's defaults, dx carries the karg.
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
line_of() { grep -nE "^## $1\$" "$readme" | head -1 | cut -d: -f1; }
in_order() { # headings in the order given, all present
    local prev=0 h n
    for h in "$@"; do n=$(line_of "$h"); [ -n "$n" ] && [ "$n" -gt "$prev" ] || return 1; prev=$n; done
}

# ---- README structure
check "sections in order: requirements, highlights, variants, install, recipes, then the closing block" \
    in_order Requirements Highlights Variants Install Recipes Contributing License Credits "About this repo"
check "the last second-level heading is About this repo (the disclaimer stays last)" \
    bash -c "[ \"\$(grep -E '^## ' '$readme' | tail -1)\" = '## About this repo' ]"
check "the disclaimer text is in the About section" bash -c "awk '/^## About this repo/{f=1} f' '$readme' | grep -q 'excuse the slop'"
check "the Fork it heading AGENTS.md links to still exists" bash -c "grep -q '^### Fork it' '$readme' && grep -q 'README.md#fork-it' '$repo/AGENTS.md'"
for h in "Defaults" "Niri session" "Beta channel" "NVIDIA graphics" "Developer image" "Which image is this?" "Security key" "Toolboxes"; do
    check "no README section named '$h'" bash -c "! grep -qiE '^#+ $h' '$readme'"
done
check "no section of the old Developer menu" bash -c "! grep -q 'Developer menu' '$readme'"
check "the old compilers sentence is gone" bash -c "! grep -q 'stay out of the host' '$readme'"
check "no personal names" bash -c "! grep -qiE 'kevin|riley' '$readme'"
check "no step-by-step recipe text (no per-step table of ujust dev, no u2f commands)" bash -c "! grep -qE 'pamu2fcfg|\`libvirt\` \\|' '$readme'"
check "the Variants table has exactly the three images" bash -c "awk '/^## Variants/{f=1;next} /^## /{f=0} f' '$readme' | grep -c '^| \(default\|NVIDIA\|dx\) |' | grep -qx 3"

# ---- recipes: every public recipe of the shipped recipe files is listed, marked DX only where dx-only
recipes() { grep -hE '^[a-z][a-z0-9-]* (\*args)?:$' "$@" | sed -E 's/ .*//; s/:$//'; }
default_recipes=$(recipes "$repo/system_files/usr/share/ublue-os/just/60-custom.just")
dx_recipes=$(recipes "$repo"/variants/dx/system_files/usr/share/ublue-os/just/*.just)
check "the recipe scan finds the known recipes" bash -c "[ \$(echo '$default_recipes' | wc -w) -ge 6 ] && [ \"$dx_recipes\" = dev ]"
for r in $default_recipes; do
    check "README lists ujust $r" grep -qF "ujust $r" "$readme"
done
for r in $dx_recipes; do
    check "README lists ujust $r as DX only" grep -qE "ujust $r.*\(DX only\)" "$readme"
done
names_only_real_recipes() {
    local r known; known=" $(echo $default_recipes $dx_recipes) list enroll-secure-boot-key "
    for r in $(grep -oE 'ujust [a-z][a-z-]*' "$readme" | sed 's/ujust //' | sort -u); do
        case "$known" in *" $r "*) ;; *) echo "unknown recipe $r"; return 1 ;; esac
    done
}
check "the README names no recipe that does not exist (enroll-secure-boot-key is the base's)" names_only_real_recipes

# ---- variants: the image names in the table exist in the repo
for img in octarine-os octarine-os-nvidia octarine-os-dx; do
    check "README has the URL of $img" grep -qF "ghcr.io/redcodeworks/$img:latest" "$readme"
done
check "the nvidia and dx variants have their own build files" test -f "$repo/variants/nvidia/nvidia.sh" -a -f "$repo/variants/dx/dx.sh"
check "the README says dx has the iommu=pt karg and the file is in the dx tree" bash -c "grep -q 'iommu=pt' '$readme' && grep -qx 'kargs = \[\"iommu=pt\"\]' '$repo/variants/dx/system_files/usr/lib/bootc/kargs.d/10-iommu.toml'"
check "the README says the VS Code build is not verified by Flathub (as dx.preinstall does)" bash -c "grep -q 'not verified by Flathub' '$readme' && grep -q 'Not verified' '$repo/variants/dx/system_files/usr/share/flatpak/preinstall.d/dx.preinstall'"

# ---- iommu=pt: dx only
check "the default image tree ships no kargs.d file with iommu" bash -c "! grep -rqs iommu '$repo/system_files/usr/lib/bootc'"
check "the default image tree has no 10-iommu.toml" test ! -e "$repo/system_files/usr/lib/bootc/kargs.d/10-iommu.toml"
check "the dx image tree ships iommu=pt" grep -q 'iommu=pt' "$repo/variants/dx/system_files/usr/lib/bootc/kargs.d/10-iommu.toml"
check "dx.sh copies the dx tree (so the karg file lands in /usr/lib/bootc/kargs.d)" grep -q 'cp -avf /ctx/system_files/. /' "$repo/variants/dx/dx.sh"
for wf in build.yml build-beta.yml; do
    check "$wf smoke test asserts the karg file is ABSENT" grep -qF '! test -e /usr/lib/bootc/kargs.d/10-iommu.toml' "$repo/.github/workflows/$wf"
    check "$wf smoke test no longer requires the karg file" bash -c "! grep -qF 'test -f /usr/lib/bootc/kargs.d/10-iommu.toml' '$repo/.github/workflows/$wf'"
done
check "dx-smoke.sh asserts the karg" grep -q 'iommu=pt karg file is shipped' "$repo/.github/scripts/dx-smoke.sh"
check "the README does not claim iommu=pt for the default image" bash -c "! grep -E 'zram swap tuning.*iommu' '$readme'"

# ---- zsh: installed, not the default of new users
check "build.sh still installs zsh and lists it in /etc/shells (the shell step needs it)" bash -c "grep -q 'steam-devices zsh' '$repo/build_files/build.sh' && grep -q 'echo /usr/bin/zsh >> /etc/shells' '$repo/build_files/build.sh'"
check "build.sh does not rewrite /etc/default/useradd" bash -c "! grep -E '^[^#]*(sed|echo|cat|tee).*useradd' '$repo/build_files/build.sh'"
check "build.sh fails the build if zsh were the default" grep -q "must not be the default shell" "$repo/build_files/build.sh"
for wf in build.yml build-beta.yml; do
    check "$wf smoke test asserts zsh is not the default" grep -qF '! grep -qx SHELL=/usr/bin/zsh /etc/default/useradd' "$repo/.github/workflows/$wf"
    check "$wf smoke test still checks zsh is in /etc/shells" grep -qF 'zsh in /etc/shells' "$repo/.github/workflows/$wf"
done
check "dx-smoke.sh asserts zsh is not the default" grep -q 'new users do not default to zsh' "$repo/.github/scripts/dx-smoke.sh"
check "the opt-in path exists: user-setup has the shell step" grep -q '"shell^Login shell zsh' "$repo/system_files/usr/share/ublue-os/just/60-custom.just"
check "no file ships a useradd default" test ! -e "$repo/system_files/etc/default/useradd"

echo "== $pass passed, $failn failed"
[ "$failn" = 0 ]
