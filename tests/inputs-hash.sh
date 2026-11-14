#!/usr/bin/env bash
# Tests .github/scripts/inputs-hash.sh (the two input hashes) and plan-vanilla-reuse.sh (the decision table of a push
# to testing) in a temporary git repository with a fake registry lookup. Run: tests/inputs-hash.sh
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
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
sha() { git rev-parse --short=7 "$1"; }

mkdir -p system_files variants/dx/system_files .github/workflows .github/scripts tests docs keys
echo a > system_files/x; echo a > variants/dx/f; echo a > variants/dx/system_files/g
echo a > .github/workflows/build-dx.yml; echo a > .github/workflows/build.yml; echo a > .github/scripts/dx-smoke.sh
echo a > tests/dx-image.sh; echo a > tests/other.sh; echo a > README.md; echo a > docs/n.md; echo a > keys/redcodeworks-toolbox-cosign.pub
commit base; c0=$(git rev-parse HEAD)

eq "stable: the same commit twice" "$(v)" "$(v)"
eq "stable: dx hash twice" "$(d)" "$(d)"
git commit -q --amend -m "other message" --date "2020-01-01T00:00:00"
eq "independent of the commit id and message" "$(v)" "$(v "${c0}")"
eq "hashes are 64 hex characters" "$(v | grep -cE '^[0-9a-f]{64}$')" 1
ne "the two hashes differ" "$(v)" "$(d)"

c0=$(git rev-parse HEAD); v0=$(v); d0=$(d)
echo b >> variants/dx/f; commit dx1
eq "dx-only change (variants/dx): vanilla_inputs equal" "$(v)" "${v0}"; ne "dx-only change: dx_inputs differ" "$(d)" "${d0}"
echo b >> .github/workflows/build-dx.yml; echo b >> tests/dx-image.sh; echo b >> .github/scripts/dx-smoke.sh; echo b >> keys/redcodeworks-toolbox-cosign.pub; commit dx2
eq "dx workflow, smoke script, dx test and key: vanilla_inputs equal" "$(v)" "${v0}"
mkdir -p .github/scripts; echo a > .github/scripts/publish-latest.sh; echo a > .github/scripts/dispatch-dx.sh; echo a > tests/publish-latest.sh; commit pipelineonly0
v0=$(v); d0=$(d)
echo b >> .github/scripts/publish-latest.sh; echo b >> .github/scripts/dispatch-dx.sh; echo b >> tests/publish-latest.sh; commit pipelineonly
eq "pipeline-only files (publish-latest, dispatch-dx and their tests): vanilla_inputs equal" "$(v)" "${v0}"; eq "...and dx_inputs equal" "$(d)" "${d0}"
( source "${hash}"; is_pipeline_only .github/workflows/build.yml || is_pipeline_only .github/workflows/build-dx.yml || is_pipeline_only .github/scripts/plan-dx.sh || is_pipeline_only Justfile ) && bad "a build file is listed as pipeline-only" || pass "the build workflows and plan scripts are not pipeline-only"
echo b >> README.md; echo b >> docs/n.md; commit docs
eq "docs-only change: vanilla_inputs equal" "$(v)" "${v0}"; eq "docs-only change: dx_inputs equal to the commit before" "$(d)" "$(d HEAD~1)"
d2=$(d)
echo b >> system_files/x; commit vanilla1
ne "vanilla change: vanilla_inputs differ" "$(v)" "${v0}"; eq "vanilla change: dx_inputs equal" "$(d)" "${d2}"
v1=$(v)
echo b >> .github/workflows/build.yml; commit workflow
ne "a change to build.yml is a vanilla change" "$(v)" "${v1}"
echo b >> tests/other.sh; commit othertest
eq "a test file is not an image input (tests/** is listed with the docs)" "$(v)" "$(v HEAD~1)"; eq "...and not a dx input either" "$(d)" "$(d HEAD~1)"
echo c > system_files/new; commit newfile
ne "a new vanilla file changes vanilla_inputs" "$(v)" "$(v HEAD~1)"
git mv variants/dx/f variants/dx/f2; commit rename
eq "renaming inside variants/dx leaves vanilla_inputs equal" "$(v)" "$(v HEAD~1)"; ne "...and changes dx_inputs" "$(d)" "$(d HEAD~1)"

# every literal path of is_dx_only that is not a glob exists in the real repository (a rename must update the list)
for f in .github/workflows/build-dx.yml .github/scripts/dx-smoke.sh .github/scripts/plan-dx.sh .github/scripts/aggregate-dx.sh keys/redcodeworks-toolbox-cosign.pub; do
    [[ -f "${here}/${f}" ]] && pass "dx-only path exists: ${f}" || bad "dx-only path missing: ${f}"
    ( source "${hash}"; is_dx_only "${f}" ) && pass "is_dx_only ${f}" || bad "is_dx_only ${f}"
done
( source "${hash}"; is_dx_only .github/workflows/build.yml || is_dx_only Justfile || is_dx_only tests/inputs-hash.sh || is_dx_only build_files/build.sh ) && bad "a default-image file is listed as dx-only" || pass "default-image files are not dx-only"
"${hash}" sideways > /dev/null 2>&1; [[ $? -eq 2 ]] && pass "unknown kind: usage, exit 2" || bad "unknown kind"
"${hash}" vanilla nosuchrev > /dev/null 2>&1; [[ $? -ne 0 ]] && pass "unknown revision fails" || bad "unknown revision"

# ---- plan-vanilla-reuse.sh: a push to testing; the registry holds testing-<sha> for the commits in FAKE_TAGS
cat > "${tmp}/fake/lookup" <<'EOS'
#!/usr/bin/env bash
grep -qx "$1" "${FAKE_TAGS}" && echo "sha256:fake-$1"
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
echo y >> README.md; commit docsonly
want "docs-only change on top of that" true "testing-$(sha "${img}")"
echo y >> system_files/x; commit vanillachange
want "vanilla change: build" false ""
: > "${FAKE_TAGS}"; git checkout -q -B t3 "${img}"; echo z >> variants/dx/f; commit dxonly2
want "dx-only change but no image published: build (first run)" false ""
echo "testing-$(sha "${img}")" > "${FAKE_TAGS}"
want "event schedule" false "" schedule refs/heads/testing HEAD
want "event dispatch" false "" workflow_dispatch refs/heads/testing HEAD
want "push to main (promotion has its own script)" false "" push refs/heads/main HEAD
want "push to a feature branch" false "" push refs/heads/feat/x HEAD
git checkout -q -B t4 "${img}"; echo q >> system_files/x; commit v2; echo "testing-$(sha "${img}")" > "${FAKE_TAGS}"; echo r >> variants/dx/f; commit d3
want "an image exists only behind a vanilla change: build" false ""
out=$("${reuse}" push refs/heads/testing HEAD 2>/dev/null); eq "the output carries the vanilla_inputs of the commit" "$(sed -n 's/^inputs=//p' <<< "${out}")" "$(v)"

# ---- plan-promote.sh on main with dx-only changes (the promotion of a dx-only testing tip promotes the vanilla image)
export PROMOTE_ENABLED=true
git checkout -q -B main "${img}"
git checkout -q -b t5 "${img}"; echo s >> variants/dx/f; commit d5; tip=$(git rev-parse HEAD)
git checkout -q main; git merge -q --no-ff -m merge t5; m=$(git rev-parse HEAD)
echo "testing-$(sha "${img}")" > "${FAKE_TAGS}"
out=$("${here}/.github/scripts/plan-promote.sh" push refs/heads/main "${m}" 2>/dev/null)
eq "promote: a dx-only testing tip promotes the default image behind it" "$(sed -n 's/^source_tag=//p' <<< "${out}")" "testing-$(sha "${img}")"
exit "${fail}"
