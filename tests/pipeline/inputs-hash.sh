#!/usr/bin/env bash
# Tests .github/scripts/inputs-hash.sh (the three input hashes: vanilla, dx, gx) and plan-vanilla-reuse.sh (the decision table of a push
# to testing) in a temporary git repository with a fake registry lookup. Run: tests/pipeline/inputs-hash.sh
set -uo pipefail
here=$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)
hash="$here/.github/scripts/inputs-hash.sh"
reuse="$here/.github/scripts/plan-vanilla-reuse.sh"
tmp=$(mktemp -d)
trap 'rm -rf "${tmp}"' EXIT
fail=0
pass() { echo "PASS $1"; }
bad() { echo "FAIL $1"; fail=1; }
eq() { if [[ "$2" == "$3" ]]; then pass "$1"; else bad "$1 (${2} vs ${3})"; fi; }
ne() { if [[ "$2" != "$3" ]]; then pass "$1"; else bad "$1 (both ${2})"; fi; }

mkdir "${tmp}/repo" "${tmp}/fake"
cd "${tmp}/repo"
git init -q -b testing .
git config user.email t@example.invalid
git config user.name t
commit() { git add -A; git commit -qm "$1"; }
v() { "${hash}" vanilla "${1:-HEAD}"; }
d() { "${hash}" dx "${1:-HEAD}"; }
g() { "${hash}" gx "${1:-HEAD}"; }
sha() { git rev-parse --short=7 "$1"; }

mkdir -p system_files variants/dx/system_files variants/gx .github/workflows .github/scripts tests docs keys
echo a > variants/gx/f; echo a > .github/workflows/build-gx.yml; echo a > .github/scripts/gx-smoke.sh
echo a > .github/workflows/dx-image.yml; echo a > .github/workflows/build-variant.yml; echo a > .github/workflows/build-extra.yml; echo a > .github/scripts/plan-dx.sh; echo a > .github/scripts/aggregate-dx.sh
echo a > system_files/x; echo a > variants/dx/f; echo a > variants/dx/system_files/g
echo a > .github/workflows/build-dx.yml; echo a > .github/workflows/build.yml; echo a > .github/scripts/dx-smoke.sh
echo a > tests/dx-image.sh; echo a > tests/other.sh; echo a > README.md; echo a > docs/n.md; echo a > keys/redcodeworks-toolbox-cosign.pub
commit base; c0=$(git rev-parse HEAD)

eq "stable: the same commit twice" "$(v)" "$(v)"
git commit -q --amend -m "other message" --date "2020-01-01T00:00:00"
eq "independent of the commit id and message" "$(v)" "$(v "${c0}")"

c0=$(git rev-parse HEAD); v0=$(v); d0=$(d); g0=$(g)
echo b >> variants/dx/f; commit dx1
eq "dx-only change (variants/dx): vanilla_inputs equal" "$(v)" "${v0}"; ne "dx-only change: dx_inputs differ" "$(d)" "${d0}"
eq "dx-only change: gx_inputs equal" "$(g)" "${g0}"
d1=$(d)
echo b >> variants/gx/f; commit gx1
eq "gx-only change (variants/gx): vanilla_inputs equal" "$(v)" "${v0}"; ne "gx-only change: gx_inputs differ" "$(g)" "${g0}"; eq "gx-only change: dx_inputs equal" "$(d)" "${d1}"
g1=$(g)
echo b >> .github/workflows/build-gx.yml; echo b >> .github/scripts/gx-smoke.sh; commit gx2
eq "build-gx.yml and gx-smoke.sh are gx-only: vanilla_inputs equal" "$(v)" "${v0}"; ne "...gx_inputs differ" "$(g)" "${g1}"; eq "...dx_inputs equal" "$(d)" "${d1}"
d1=$(d); g1=$(g)
for f in .github/workflows/dx-image.yml .github/workflows/build-variant.yml .github/scripts/plan-dx.sh .github/scripts/aggregate-dx.sh keys/redcodeworks-toolbox-cosign.pub; do
    echo b >> "${f}"; commit "shared ${f}"
    eq "shared file ${f}: vanilla_inputs equal" "$(v)" "${v0}"; ne "...dx_inputs differ" "$(d)" "${d1}"; ne "...gx_inputs differ" "$(g)" "${g1}"
    d1=$(d); g1=$(g)
done
echo b >> .github/workflows/build-dx.yml; commit dx2
eq "build-dx.yml is dx-only: gx_inputs equal" "$(g)" "${g1}"; ne "...dx_inputs differ" "$(d)" "${d1}"
d1=$(d)
echo b >> .github/workflows/build-extra.yml; commit extra
eq "build-extra.yml (dispatch-only extra variants) is pipeline-only: all three hashes equal" "$(v)-$(d)-$(g)" "${v0}-${d1}-${g1}"
echo b >> README.md; echo b >> docs/n.md; echo b >> docs/CONFIG-GUIDE.md; commit docs
eq "docs-only change (README, docs/, docs/CONFIG-GUIDE.md): vanilla_inputs equal" "$(v)" "${v0}"; eq "docs-only change: dx_inputs equal to the commit before" "$(d)" "$(d HEAD~1)"
d2=$(d); g2=$(g)
echo b >> system_files/x; commit vanilla1
ne "vanilla change: vanilla_inputs differ" "$(v)" "${v0}"; eq "vanilla change: dx_inputs equal" "$(d)" "${d2}"; eq "vanilla change: gx_inputs equal" "$(g)" "${g2}"
v1=$(v)
echo b >> tests/other.sh; commit othertest
eq "a test file is not an image input (tests/** is listed with the docs)" "$(v)" "$(v HEAD~1)"; eq "...and not a dx input either" "$(d)" "$(d HEAD~1)"
mkdir -p config; echo a > config/image.env; echo a > config/chunkah.env; commit configenv; ci=$(v)
echo b >> config/image.env; commit imageenv
ne "config/image.env is an image input" "$(v)" "${ci}"; ci=$(v)


# ---- plan-vanilla-reuse.sh: a push to testing; the registry holds testing-<sha> for the commits in FAKE_TAGS
cat > "${tmp}/fake/lookup" <<'EOS'
#!/usr/bin/env bash
[[ -z "${FAKE_READ_ERROR:-}" ]] || exit 4  # the registry cannot be read (contract: 3 = absent, other = read error)
grep -qx "$1" "${FAKE_TAGS}" && echo "sha256:fake-$1" || exit 3
EOS
chmod +x "${tmp}/fake/lookup"
export REGISTRY_LOOKUP="${tmp}/fake/lookup" FAKE_TAGS="${tmp}/fake/tags"
: > "${FAKE_TAGS}"
want() { # name want-reuse want-tag [event ref after]
    local out got tag
    out=$("${reuse}" "${4:-push}" "${5:-refs/heads/testing}" "${6:-HEAD}" 2>/dev/null) || true
    got=$(sed -n 's/^reuse=//p' <<< "${out}"); tag=$(sed -n 's/^source_tag=//p' <<< "${out}")
    if [[ "${got}" == "$2" && "${tag}" == "$3" ]]; then pass "reuse: $1"; else bad "reuse: $1 (got ${got} ${tag}, want $2 $3)"; fi
}
git checkout -q -b t2 "${c0}"
echo x >> system_files/x; commit imagecommit; img=$(git rev-parse HEAD)
echo "testing-$(sha "${img}")" > "${FAKE_TAGS}"
want "the commit itself has an image (re-run)" true "testing-$(sha "${img}")"
echo y >> variants/dx/f; commit dxonly
want "dx-only change on top of a published image" true "testing-$(sha "${img}")"
echo y >> system_files/x; commit vanillachange
want "vanilla change: build" false ""
exit "${fail}"
