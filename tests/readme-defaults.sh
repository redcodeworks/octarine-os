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
    in_order "Build status" Requirements Highlights Variants Install Recipes Contributing License Credits "About this repo"
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
check "the Variants table lists the four images in the order default, dx, NVIDIA, NVIDIA dx, and has no badge" python3 - "$readme" <<'PY'
import re, sys
sec = open(sys.argv[1]).read().split("\n## Variants", 1)[1].split("\n#", 1)[0]
rows = [l for l in sec.splitlines() if l.startswith("| ")]
assert [r.split("|")[1].strip() for r in rows[1:]] == ["default", "dx", "NVIDIA", "NVIDIA dx"], rows
assert "badge.svg" not in sec
PY
# ---- the Build status table: Image | main | testing, one linked badge per cell, natural size (no text beside it)
check "Build status table: header, four rows, badges for main and testing of the real workflow files, links to the branch-filtered runs, plain text where the workflow never runs on testing" python3 - "$readme" "$repo" <<'PY'
import re, sys, os
text = open(sys.argv[1]).read(); repo = sys.argv[2]
assert text.index("\n## Build status") < text.index("\n## Requirements"), "Build status sits before Requirements"
assert text.index("CONFIG-GUIDE.md") < text.index("\n## Build status"), "after the opening paragraph"
assert "### Build status" not in text
sec = text.split("\n## Build status", 1)[1].split("\n## ", 1)[0]
rows = [l for l in sec.splitlines() if l.startswith("|")]
assert rows[0].replace(" ", "") == "|Image|main|testing|" and set(rows[1].replace("|", "")) == {"-"}, rows[:2]
body = {r.split("|")[1].strip(): [c.strip() for c in r.split("|")[2:4]] for r in rows[2:]}
assert list(body) == ["default", "dx", "beta", "NVIDIA", "NVIDIA dx"], list(body)
base = "https://github.com/redcodeworks/octarine-os/actions/workflows/"
def badge(cell, wf, br):
    m = re.fullmatch(r"\[!\[[^\]]+\]\(" + re.escape(base + wf + "/badge.svg?branch=" + br) + r"\)\]\(" + re.escape(base + wf + "?query=branch%3A" + br) + r"\)", cell)
    assert m, (wf, br, cell)
    assert os.path.exists(os.path.join(repo, ".github/workflows", wf)), wf
for img, wf in (("default", "build.yml"), ("dx", "build-dx.yml"), ("NVIDIA", "build-nvidia.yml"), ("NVIDIA dx", "build-nvidia-dx.yml")):
    badge(body[img][0], wf, "main")
badge(body["default"][1], "build.yml", "testing")
# dx is a workflow_run workflow: GitHub records every run on main, a testing badge would never show a status
assert body["dx"][1] == "after each testing build, see the check on the commit", body["dx"]
badge(body["beta"][0], "build-beta.yml", "main")
for img in ("beta", "NVIDIA", "NVIDIA dx"):
    assert body[img][1] == "weekly, main only", body[img]   # these never run on testing: no badge
PY

# ---- recipes: every public recipe of the shipped recipe files is listed, marked DX only where dx-only
recipes() { grep -hE '^[a-z][a-z0-9-]* (\*args)?:$' "$@" | sed -E 's/ .*//; s/:$//'; }
default_recipes=$(recipes "$repo/system_files/usr/share/ublue-os/just/60-custom.just" "$repo/system_files/usr/share/ublue-os/just/10-update.just")
dx_recipes=$(recipes "$repo"/variants/dx/system_files/usr/share/ublue-os/just/*.just)
check "the recipe scan finds the known recipes" bash -c "[ \$(echo '$default_recipes' | wc -w) -ge 6 ] && [ \"$(echo $dx_recipes | tr ' ' '\n' | sort | tr '\n' ' ')\" = \"datastore datastore-setup dev virthost-setup \" ]"
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
for img in octarine-os octarine-os-nvidia octarine-os-dx octarine-os-nvidia-dx; do
    check "README has the URL of $img" grep -qF "ghcr.io/redcodeworks/$img:latest" "$readme"
done
check "the nvidia and dx variants have their own build files" test -f "$repo/variants/nvidia/nvidia.sh" -a -f "$repo/variants/dx/dx.sh"
check "the README does not claim an iommu=pt kernel argument for dx and no dx tree file ships it" bash -c "! grep -q 'iommu=pt' '$readme' && ! grep -rqs iommu '$repo/variants/dx/system_files/usr/lib/bootc'"
check "the README does not say VS Code or virt-manager is preinstalled" bash -c "! grep -qiE 'Visual Studio Code preinstalled|virt-manager, Vorta' '$readme'"

check "the blur-my-shell extension is not in the package lists (build.sh, smoke test optional lists)" bash -c "! grep -rq 'gnome-shell-extension-blur-my-shell' '$repo/build_files' '$repo/.github/workflows' '$repo/variants'"

# ---- iommu=pt: no image ships it (opt-in through ujust virthost-setup)
check "the default image tree ships no kargs.d file with iommu" bash -c "! grep -rqs iommu '$repo/system_files/usr/lib/bootc'"
check "the default image tree has no 10-iommu.toml" test ! -e "$repo/system_files/usr/lib/bootc/kargs.d/10-iommu.toml"
check "the dx image tree has no kargs.d file at all" test ! -e "$repo/variants/dx/system_files/usr/lib/bootc/kargs.d/10-iommu.toml"
for wf in build.yml build-beta.yml; do
    check "$wf smoke test asserts the karg file is ABSENT" grep -qF '! test -e /usr/lib/bootc/kargs.d/10-iommu.toml' "$repo/.github/workflows/$wf"
    check "$wf smoke test no longer requires the karg file" bash -c "! grep -qF 'test -f /usr/lib/bootc/kargs.d/10-iommu.toml' '$repo/.github/workflows/$wf'"
done
check "dx-smoke.sh asserts that no kargs.d file mentions iommu" grep -q 'no image ships an iommu kernel argument' "$repo/.github/scripts/dx-smoke.sh"
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
