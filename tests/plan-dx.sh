#!/usr/bin/env bash
# Tests .github/scripts/plan-dx.sh (skip, promote or build, per channel) with stub skopeo and cosign in a temporary git
# repository, and .github/scripts/aggregate-dx.sh (the result of the job `Build dx and push image`) with fixed job
# results. Run: tests/plan-dx.sh
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
plan="$here/.github/scripts/plan-dx.sh"
agg="$here/.github/scripts/aggregate-dx.sh"
root=$(mktemp -d)
trap 'rm -rf -- "$root"' EXIT
fail=0
pass() { echo "PASS $1"; }
bad() { echo "FAIL $1"; fail=1; }

mkdir -p "$root/bin" "$root/cfg" "$root/repo/variants/dx"
cd "$root/repo"
git init -q -b testing .
git config user.email t@example.invalid; git config user.name t
echo a > variants/dx/f; echo a > x; git add -A; git commit -qm one
echo b >> x; git add -A; git commit -qm two
echo c >> variants/dx/f; git add -A; git commit -qm "three (dx only)"
inputs=$("$here/.github/scripts/inputs-hash.sh" dx HEAD)
sha7=$(git rev-parse --short=7 HEAD)
older7=$(git rev-parse --short=7 HEAD~1)

# stub registry: config of octarine-os-dx:<tag> is $root/cfg/<tag> (missing = not published); the raw manifest is
# derived from the reference (a reference listed in $root/missing does not exist; a line "<from> <to>" in $root/alias
# gives <from> the manifest of <to>, like a retag); cosign fails for references listed in $root/unsigned and for the key check of nothing else
cat > "$root/bin/skopeo" <<'F'
#!/usr/bin/env bash
ref="${@: -1}"
echo "$*" >> "${SK_LOG:-/dev/null}"
case "$1 $2" in
    "inspect --raw")
        ref="${ref#docker://}"
        ! grep -qxF "${ref}" "${MISSING}" || exit 1
        to=$(awk -v r="${ref}" '$1 == r { print $2 }' "${ALIAS}"); printf 'manifest of docker://%s' "${to:-${ref}}" ;;
    "inspect --config") tag="${ref##*:}"; [[ ( "${ref}" == *octarine-os-dx:* || "${ref}" == *octarine-os-nvidia-dx:* ) && -f "${CFG}/${tag}" ]] && { cat "${CFG}/${tag}"; exit 0; }; exit 1 ;;
esac
F
cat > "$root/bin/cosign" <<'F'
#!/usr/bin/env bash
ref="${@: -1}"
[[ "${COSIGN_BASE_FAIL:-}" != 1 || "${ref}" != *octarine-os@* ]] || exit 1
! grep -qxF "${ref}" "${UNSIGNED}"
F
chmod +x "$root/bin"/*
export CFG="$root/cfg" UNSIGNED="$root/unsigned" MISSING="$root/missing" ALIAS="$root/alias"
: > "$UNSIGNED"; : > "$MISSING"; : > "$ALIAS"

dig() { printf 'manifest of %s' "$1" | sha256sum | sed 's/ .*//'; }
base() { dig "docker://ghcr.io/redcodeworks/octarine-os:$1"; }   # the base digest of a channel's tag
dxd() { dig "docker://ghcr.io/redcodeworks/octarine-os-dx:$1"; }  # the manifest digest of a dx tag
cfg() { # tag base-digest inputs
    printf '{"config":{"Labels":{"org.opencontainers.image.base.digest":"%s","io.github.redcodeworks.octarine-os.dx-inputs":"%s"}}}' "$2" "$3" > "$CFG/$1"
}
run() { # channel [force]; outputs in $root/out
    : > "$root/out"; : > "$root/sum"
    PATH="$root/bin:$PATH" CHANNEL="$1" FORCE="${2:-false}" GITHUB_REPOSITORY_OWNER=RedCodeWorks \
        GITHUB_OUTPUT="$root/out" GITHUB_STEP_SUMMARY="$root/sum" bash "$plan" > "$root/log" 2>&1
}
get() { sed -n "s/^$1=//p" "$root/out"; }
expect() { # name build promote source_tag
    if [[ "$(get build)" == "$2" && "$(get promote)" == "$3" && "$(get source_tag)" == "$4" ]]; then pass "$1"
    else bad "$1 (got build=$(get build) promote=$(get promote) tag=$(get source_tag); want $2 $3 $4)"; sed 's/^/     /' "$root/log"; fi
}
other="sha256:$(printf 'a%.0s' {1..64})"
bt="sha256:$(base "testing-${sha7}")"; bf="sha256:$(base testing)"; bl="sha256:$(base latest)"; bb="sha256:$(base beta)"

echo "== testing channel"
rm -f "$CFG"/*
run testing; expect "testing, first run (nothing published): build" true false ""
[[ "$(get base_tag)" == "testing-${sha7}" && "$(get base_digest)" == "${bt}" && "${bt}" != "${bf}" ]] && pass "testing builds on octarine-os:testing-<sha7> of the commit, not the floating testing tag (digest of the raw manifest)" || bad "testing base"
[[ "$(get dx_inputs)" == "${inputs}" ]] && pass "the dx inputs of the commit are passed on" || bad "dx_inputs output"
cfg testing "${bt}" "${inputs}"; run testing; expect "testing, same base digest and dx inputs: skip" false false ""
grep -q 'base unchanged, nothing to build' "$root/log" && pass "the skip notice is printed" || bad "skip notice"
cfg testing "${bt}" "different"; run testing; expect "testing, dx inputs changed (dx-only change): build" true false ""
cfg testing "${other}" "${inputs}"; run testing; expect "testing, vanilla base changed (vanilla-only change): build" true false ""
cfg testing "${other}" "different"; run testing; expect "testing, both changed: build" true false ""
cfg testing "${bt}" "${inputs}"; run testing true; expect "testing, force: build" true false ""
cfg latest "${bt}" "${inputs}"; run testing; expect "testing never promotes and reads only the testing tag" false false ""
rm -f "$CFG/testing"; run testing; expect "testing, dx image unreadable: build" true false ""

echo "== testing channel: the commit's default image is missing"
rm -f "$CFG"/*
older="sha256:$(base "testing-${older7}")"
echo "ghcr.io/redcodeworks/octarine-os:testing-${sha7}" > "$MISSING"   # the default build was reused for this dx-only commit
run testing; expect "testing, reused default build: build on the nearest earlier testing-<sha>" true false ""
[[ "$(get base_tag)" == "testing-${older7}" && "$(get base_digest)" == "${older}" ]] && pass "...the base is testing-<sha7> of the nearest commit with the same default-image inputs" || bad "walk-back base ($(get base_tag))"
cfg testing "${older}" "${inputs}"; run testing; expect "testing, reused default build, dx image on that base: skip" false false ""
printf '%s\n' "ghcr.io/redcodeworks/octarine-os:testing-${sha7}" "ghcr.io/redcodeworks/octarine-os:testing-${older7}" "ghcr.io/redcodeworks/octarine-os:testing-$(git rev-parse --short=7 HEAD~2)" > "$MISSING"
run testing; expect "testing, no usable testing-<sha> (a default-image change in between): build" true false ""
[[ "$(get base_tag)" == testing && "$(get base_digest)" == "${bf}" ]] && pass "...falls back to the floating testing tag" || bad "fallback base"
grep -q '::warning::.*floating' "$root/log" && pass "...and says so" || bad "fallback warning"
: > "$MISSING"

echo "== promotion sequence (testing build, default promote, dx latest plan)"
rm -f "$CFG"/*
run testing; expect "step 1, dx plan on testing: build" true false ""
built_on="$(get base_digest)"
cfg testing "${built_on}" "$(get dx_inputs)"                                  # what the dx build records
echo "ghcr.io/redcodeworks/octarine-os:latest ghcr.io/redcodeworks/octarine-os:testing-${sha7}" > "$ALIAS"   # step 2: the default promote retags testing-<sha7> (one digest)
run latest; expect "step 3, dx plan on latest after the default promote: promote the tested dx image" false true testing
[[ "$(get base_digest)" == "${built_on}" ]] && pass "...latest and the base the dx testing image was built on share one digest" || bad "digests differ"
echo "ghcr.io/redcodeworks/octarine-os:latest ghcr.io/redcodeworks/octarine-os:testing" > "$ALIAS"   # the old behavior: latest = the floating tag's digest
run latest; expect "contrast: latest equal to the floating tag only, not to testing-<sha7>: no promotion (the bug)" true false ""
: > "$ALIAS"

echo "== latest channel (main)"
rm -f "$CFG"/*
run latest; expect "latest, nothing published, no testing image: build" true false ""
cfg latest "${bl}" "${inputs}"; run latest; expect "latest, same base and dx inputs: skip" false false ""
echo "$(printf 'ghcr.io/redcodeworks/octarine-os-dx@sha256:%s' "$(dxd latest)")" > "$UNSIGNED"
cfg latest "${bl}" "${inputs}"; run latest; expect "latest, same base and inputs but the published image is NOT signed (a cancelled run): build, never skip" true false ""
grep -q 'does not verify: building' "$root/log" && pass "the unsigned skip candidate is named in a warning" || bad "unsigned warning"
: > "$UNSIGNED"
cfg latest "${other}" "${inputs}"; run latest; expect "latest, old base, no testing image: build" true false ""
cfg testing "${bl}" "${inputs}"
run latest; expect "latest, tested testing image with the same base and dx inputs: promote" false true testing
[[ "$(get source_digest)" == "sha256:$(dxd testing)" ]] && pass "the promoted digest is the raw manifest digest of the testing tag" || bad "source_digest"
cfg testing "${other}" "${inputs}"; run latest; expect "latest, testing image on another base digest: build" true false ""
cfg testing "${bl}" "different"; run latest; expect "latest, testing image with other dx inputs: build" true false ""
rm -f "$CFG/testing"
cfg "testing-${older7}" "${bl}" "${inputs}"; run latest; expect "latest, match found by testing-<sha> of an older commit: promote that tag" false true "testing-${older7}"
rm -f "$CFG"/testing-*; cfg testing "${bl}" "${inputs}"; echo "ghcr.io/redcodeworks/octarine-os-dx@sha256:$(dxd testing)" > "$UNSIGNED"
run latest; expect "latest, matching testing image but unsigned: build, not promoted" true false ""
grep -q '::warning::' "$root/log" && pass "...with a warning" || bad "unsigned warning"
: > "$UNSIGNED"; run latest true; expect "latest, force builds even with a promotable image" true false ""
cfg latest "${bl}" "${inputs}"; run latest true; expect "latest, force builds although unchanged" true false ""
cfg latest "${bl}" "-"; run latest; expect "latest, published image without the dx-inputs label: not a skip, promotes the tested one" false true testing

echo "== beta channel (main only)"
rm -f "$CFG"/*; cfg testing "${bb}" "${inputs}"
run beta; expect "beta never promotes: build" true false ""
[[ "$(get base_tag)" == beta && "$(get base_digest)" == "${bb}" ]] && pass "beta builds on octarine-os:beta" || bad "beta base"
cfg beta "${bb}" "${inputs}"; run beta; expect "beta, unchanged: skip" false false ""

echo "== NVIDIA developer image (octarine-os-nvidia-dx on octarine-os-nvidia:latest, no testing channel)"
rm -f "$CFG"/*
nvb() { dig "docker://ghcr.io/redcodeworks/octarine-os-nvidia:$1"; }
run_nv() { # force; outputs in $root/out
    : > "$root/out"; : > "$root/sum"; : > "$root/sklog"
    PATH="$root/bin:$PATH" CHANNEL=latest FORCE="${1:-false}" GITHUB_REPOSITORY_OWNER=RedCodeWorks BASE_NAME=octarine-os-nvidia \
        DX_NAME=octarine-os-nvidia-dx PROMOTE_FROM_TESTING=false SK_LOG="$root/sklog" \
        GITHUB_OUTPUT="$root/out" GITHUB_STEP_SUMMARY="$root/sum" bash "$plan" > "$root/log" 2>&1
}
nv="sha256:$(nvb latest)"
run_nv; expect "nvidia-dx: nothing published: build" true false ""
[[ "$(get base_tag)" == latest && "$(get base_digest)" == "${nv}" ]] && pass "nvidia-dx builds on octarine-os-nvidia:latest" || bad "nvidia-dx base: $(get base_tag) $(get base_digest)"
printf '{"config":{"Labels":{"org.opencontainers.image.base.digest":"%s","io.github.redcodeworks.octarine-os.dx-inputs":"%s"}}}' "${nv}" "${inputs}" > "$CFG/latest"
run_nv; expect "nvidia-dx: same NVIDIA base digest and dx inputs: skip" false false ""
printf '{"config":{"Labels":{"org.opencontainers.image.base.digest":"sha256:old","io.github.redcodeworks.octarine-os.dx-inputs":"%s"}}}' "${inputs}" > "$CFG/latest"
run_nv; expect "nvidia-dx: a new NVIDIA base digest: build" true false ""
printf '{"config":{"Labels":{"org.opencontainers.image.base.digest":"%s","io.github.redcodeworks.octarine-os.dx-inputs":"other"}}}' "${nv}" > "$CFG/latest"
run_nv; expect "nvidia-dx: changed dx inputs: build" true false ""
run_nv true; expect "nvidia-dx: force builds" true false ""
cp "$CFG/latest" "$CFG/testing"
printf '{"config":{"Labels":{"org.opencontainers.image.base.digest":"%s","io.github.redcodeworks.octarine-os.dx-inputs":"%s"}}}' "${nv}" "${inputs}" > "$CFG/testing"
rm -f "$CFG/latest"
run_nv; expect "nvidia-dx: a matching testing tag is never promoted (no testing channel): build" true false ""
check_nolook() { ! grep -qE 'octarine-os-nvidia-dx:testing' "$root/sklog"; }
check_nolook && pass "nvidia-dx: the registry is not even asked for a testing image" || bad "nvidia-dx asked for testing"
! grep -q 'octarine-os:' "$root/sklog" && pass "nvidia-dx: the default image is never the base" || bad "nvidia-dx looked at octarine-os:"
rm -f "$CFG"/*

echo "== failures"
COSIGN_BASE_FAIL=1 run latest; [[ $? -ne 0 ]] && pass "an unsigned base fails the job" || bad "unsigned base"
run sideways; [[ $? -ne 0 ]] && pass "an unknown channel fails the job" || bad "unknown channel"

echo "== aggregate-dx.sh"
ag() { PLAN=$1 BUILD=$2 PROMOTE=$3 SIGN=$4 BUILD_WANTED=$5 PROMOTE_WANTED=$6 bash "$agg" > "$root/aglog" 2>&1; }
want_ag() { local name=$1 rc=$2; shift 2; ag "$@"; local got=$?; [[ "$got" == "$rc" ]] && pass "aggregate: $name" || { bad "aggregate: $name (rc ${got}, want ${rc})"; sed 's/^/     /' "$root/aglog"; }; }
want_ag "built and signed" 0 success success skipped success true false
want_ag "built, sign failed" 1 success success skipped failure true false
want_ag "build failed" 1 success failure skipped skipped true false
want_ag "build cancelled" 1 success cancelled skipped skipped true false
want_ag "promoted and verified" 0 success skipped success success false true
want_ag "promotion failed" 1 success skipped failure skipped false true
want_ag "promotion not verified" 1 success skipped success failure false true
want_ag "legitimate skip: nothing ran" 0 success skipped skipped skipped false false
want_ag "skip but something ran" 1 success success skipped success false false
want_ag "plan failed" 1 failure skipped skipped skipped "" ""
want_ag "plan cancelled" 1 cancelled skipped skipped skipped "" ""
want_ag "run dx is not built for (plan skipped)" 0 skipped skipped skipped skipped "" ""
want_ag "plan skipped but a job ran" 1 skipped success skipped skipped "" ""
DRY_RUN=true want_ag "dry run: the plan wanted a build, nothing ran: passes" 0 success skipped skipped skipped true false
DRY_RUN=true want_ag "dry run: the plan wanted a promotion, nothing ran: passes" 0 success skipped skipped skipped false true
DRY_RUN=true want_ag "dry run: a build ran anyway: fails" 1 success success skipped skipped true false
DRY_RUN=true want_ag "dry run: the plan itself failed: fails" 1 failure skipped skipped skipped "" ""
exit "${fail}"
