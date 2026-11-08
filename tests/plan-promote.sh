#!/usr/bin/env bash
# Tests .github/scripts/plan-promote.sh in a temporary git repository with a fake registry lookup.
set -euo pipefail
script=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.github/scripts/plan-promote.sh
tmp=$(mktemp -d)
trap 'rm -rf "${tmp}"' EXIT
mkdir "${tmp}/fake" "${tmp}/repo"
cd "${tmp}/repo"
git init -q -b main .
git config user.email t@example.invalid
git config user.name t
cat > "${tmp}/fake/lookup" <<'EOS'
#!/usr/bin/env bash
# fake registry: ${FAKE_TAGS} lists the published tags; the digest is derived from the tag
grep -qx "$1" "${FAKE_TAGS}" && echo "sha256:fake-$1"
EOS
chmod +x "${tmp}/fake/lookup"
export REGISTRY_LOOKUP="${tmp}/fake/lookup" FAKE_TAGS="${tmp}/fake/tags"
: > "${FAKE_TAGS}"
fail=0
sha() { git rev-parse --short "$1"; }
commit() { git add -A; git commit -qm "$1"; }
expect() { # name want-promote want-tag event ref after
    local out got tag
    out=$("${script}" "$4" "$5" "$6" 2>/dev/null) || true
    got=$(sed -n 's/^promote=//p' <<< "${out}")
    tag=$(sed -n 's/^source_tag=//p' <<< "${out}")
    if [[ "${got}" == "$2" && "${tag}" == "$3" ]]; then echo "PASS $1"; else echo "FAIL $1 (got ${got} ${tag}, want $2 $3)"; fail=1; fi
}

mkdir docs system_files
echo a > README.md; echo a > system_files/x
git add -A; commit base
git checkout -q -b testing
echo b >> system_files/x; commit code
code=$(git rev-parse HEAD)
echo b >> README.md; commit docs-only-tip
docs=$(git rev-parse HEAD)
git checkout -q main
git merge -q --no-ff -m merge testing
m1=$(git rev-parse HEAD)
export PROMOTE_ENABLED=true

echo "testing-$(sha "${docs}")" > "${FAKE_TAGS}"
expect "merge, equal tree, image for the tip" true "testing-$(sha "${docs}")" push refs/heads/main "${m1}"
echo "testing-$(sha "${code}")" > "${FAKE_TAGS}"
expect "docs-only tip, older image behind it" true "testing-$(sha "${code}")" push refs/heads/main "${m1}"
: > "${FAKE_TAGS}"
expect "no image found" false "" push refs/heads/main "${m1}"
echo "testing-$(sha "${code}")" > "${FAKE_TAGS}"
expect "schedule" false "" schedule refs/heads/main "${m1}"
expect "dispatch" false "" workflow_dispatch refs/heads/main "${m1}"
expect "testing branch push" false "" push refs/heads/testing "${m1}"
(unset PROMOTE_ENABLED; expect "PROMOTE_ENABLED unset" false "" push refs/heads/main "${m1}")
(PROMOTE_ENABLED=false; expect "PROMOTE_ENABLED false" false "" push refs/heads/main "${m1}")

# non-merge push to main
git checkout -q main; echo c >> README.md; commit docs-on-main
expect "non-merge push" false "" push refs/heads/main "$(git rev-parse HEAD)"

# merge where main has an extra non-docs commit (trees differ)
git checkout -q -b testing2 "${m1}"; echo d >> system_files/x; commit code2
t2=$(git rev-parse HEAD)
git checkout -q main; echo e > system_files/y; commit main-extra
git merge -q --no-ff -m merge2 testing2
echo "testing-$(sha "${t2}")" > "${FAKE_TAGS}"
expect "merge, main has an extra code commit" false "" push refs/heads/main "$(git rev-parse HEAD)"

# merge where the testing tip has a code change newer than the newest image
git checkout -q -b testing3 "${m1}"; echo f >> system_files/x; commit code3
t3=$(git rev-parse HEAD); echo g >> README.md; commit docs3
git checkout -q -B main "${m1}"; git merge -q --no-ff -m merge3 testing3
echo "testing-$(sha "${code}")" > "${FAKE_TAGS}"
expect "image is older than a code change" false "" push refs/heads/main "$(git rev-parse HEAD)"
echo "testing-$(sha "${t3}")" > "${FAKE_TAGS}"
expect "image of the code commit" true "testing-$(sha "${t3}")" push refs/heads/main "$(git rev-parse HEAD)"
exit "${fail}"
