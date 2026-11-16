#!/usr/bin/env bash
# Tests .github/scripts/publish-latest.sh (the one step that moves the `latest` of ONE image: the default image or dx; each image publishes its own)
# with a fake registry (stub skopeo), a stub cosign and a throwaway git repository that plays main. Run: tests/publish-latest.sh
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script="$here/.github/scripts/publish-latest.sh"
root=$(mktemp -d)
trap 'rm -rf -- "$root"' EXIT
pass=0; failn=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { failn=$((failn + 1)); echo "FAIL $1"; sed 's/^/     /' "$root/out"; }
check() { local d=$1; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }

# ---- the git repository: main has c1 c2 c3, a side branch has an extra commit (not on main)
mkdir -p "$root/repo/.github/scripts" "$root/bin" "$root/reg"
cp "$here/.github/scripts/registry-digest.sh" "$here/.github/scripts/registry-read.sh" "$here/.github/scripts/registry-settled.sh" "$here/.github/scripts/cosign-check.sh" "$here/.github/scripts/retry.sh" "$root/repo/.github/scripts/"
cp "$script" "$root/repo/.github/scripts/"
cd "$root/repo"
git init -q -b main . && git config user.email t@example.invalid && git config user.name t
for i in 1 2 3; do echo "$i" > f; git add f; git commit -qm "c$i"; done
c1=$(git rev-parse HEAD~2); c2=$(git rev-parse HEAD~1); c3=$(git rev-parse HEAD)
git checkout -q -b side; echo s > f; git commit -qam side; cs=$(git rev-parse HEAD); git checkout -q main
git update-ref refs/remotes/origin/main main
echo key > cosign.pub

# ---- the fake registry: $reg/<image>/tag/<tag> holds a digest, $reg/<image>/cfg/<digest> the labels
dg() { printf 'sha256:'; printf "$1%.0s" {1..64}; }
V0=$(dg 1); V1=$(dg 2); V2=$(dg 3); Vs=$(dg 4); E0=$(dg a); E1=$(dg b); E2=$(dg c); Ex=$(dg d)
mk() { # image digest rev created base tags...
    local img=$1 d=$2 rev=$3 created=$4 base=$5; shift 5
    mkdir -p "$root/reg/$img/tag" "$root/reg/$img/cfg"
    printf '{"config":{"Labels":{"org.opencontainers.image.revision":"%s","org.opencontainers.image.created":"%s","org.opencontainers.image.base.digest":"%s"}}}' "$rev" "$created" "$base" > "$root/reg/$img/cfg/$d"
    local t; for t in "$@"; do echo "$d" > "$root/reg/$img/tag/$t"; done
}
cat >"$root/bin/skopeo" <<'F'
#!/usr/bin/env bash
reg=$FAKE_REG
echo "skopeo $*" >>"$FAKE_LOG"
split() { ref=${1#docker://}; img=${ref%%[:@]*}; img=${img##*/}; rest=${ref#*[:@]}; case "$ref" in *@sha256:*) kind=digest ;; *) kind=tag ;; esac; }
resolve() { split "$1"; if [ "$kind" = digest ]; then d=$rest; [ -e "$reg/$img/cfg/$d" ] || return 1; else d=$(cat "$reg/$img/tag/$rest" 2>/dev/null) || return 1; fi; echo "$d"; }
case "$1 $2" in
    "inspect --raw") [ -z "${FAKE_READ_ERROR:-}" ] || { echo "dial tcp: i/o timeout" >&2; exit 1; }; d=$(resolve "$3") || { echo "manifest unknown" >&2; exit 1; }; printf 'MANIFEST:%s' "$d" ;;
    "manifest-digest "*) sed 's/^MANIFEST://' "$2" ;;
    "inspect --config") [ -z "${FAKE_READ_ERROR:-}" ] || { echo "dial tcp: i/o timeout" >&2; exit 1; }; d=$(resolve "$3") || { echo "manifest unknown" >&2; exit 1; }; split "$3"; cat "$reg/$img/cfg/$d" ;;
    "list-tags "*) split "$2"; printf '{"Tags":['; ls "$reg/$img/tag" 2>/dev/null | sed 's/.*/"&"/' | paste -sd, ; printf ']}' ;;
    "copy --all")
        shift 3; src=$1; dst=$2; d=$(resolve "$src") || exit 1; split "$dst"
        [ "${FAKE_COPY_WRONG:-}" = 1 ] && d="sha256:$(printf 'f%.0s' {1..64})"
        mkdir -p "$reg/$img/tag"; echo "$d" > "$reg/$img/tag/$rest" ;;
esac
F
cat >"$root/bin/cosign" <<'F'
#!/usr/bin/env bash
ref="${@: -1}"; ref=${ref#docker://}
img=${ref%%[:@]*}; img=${img##*/}
case "$ref" in *@sha256:*) d=${ref#*@} ;; *) d=$(cat "$FAKE_REG/$img/tag/${ref#*:}" 2>/dev/null) || { echo "MANIFEST_UNKNOWN" >&2; exit 1; } ;; esac
[ -z "${FAKE_COSIGN_READ_ERROR:-}" ] || { echo "TLS handshake timeout" >&2; exit 1; }
! grep -qxF "$d" "$FAKE_REG/unsigned" 2>/dev/null || { echo "Error: no signatures found" >&2; exit 1; }
F
chmod +x "$root/bin"/*
for c in bash env cat grep sed jq git sort head tr ls paste dirname mktemp rm sha256sum awk date mkdir sleep; do p=$(command -v "$c") && ln -sf "$p" "$root/bin/$c"; done
export RETRY_DELAY=0 READBACK_WAIT=0 FAKE_REG="$root/reg" FAKE_LOG="$root/log" OWNER=RedCodeWorks MAIN_REF=refs/remotes/origin/main WRITE=true
V=octarine-os; D=octarine-os-dx
reset() {
    rm -rf "${root:?}/reg"; mkdir -p "$root/reg"; : > "$root/log"; unset FAKE_COPY_WRONG FAKE_READ_ERROR FAKE_COSIGN_READ_ERROR DRY_RUN IMAGE DIGEST TAG REASON ALLOW_BACKWARDS; export WRITE=true
    # published now: the default image V0 and dx E0 (built on V0), both at latest, both from main commit c1
    mk $V "$V0" "$c1" 2026-11-10T00:00:00Z - latest "latest-${c1:0:7}"
    mk $D "$E0" "$c1" 2026-11-10T01:00:00Z "$V0" latest "latest-20261110-${c1:0:7}"
    : > "$root/reg/unsigned"
}
run() { rm -f "$root/gout"; PATH="$root/bin" GITHUB_OUTPUT="$root/gout" GITHUB_STEP_SUMMARY="$root/sum" bash "$root/repo/.github/scripts/publish-latest.sh" >"$root/out" 2>&1; rc=$?; }
latest() { cat "$root/reg/$1/tag/latest" 2>/dev/null; }
ncopy() { grep -c 'skopeo copy' "$root/log"; }
: > "$root/sum"
newv() { mk $V "$V2" "$c3" 2026-11-13T00:00:00Z - "latest-${c3:0:7}" "latest-20261113-${c3:0:7}"; }
newd() { mk $D "$E2" "$c3" 2026-11-13T01:00:00Z "${1:-$V2}" "latest-20261113-${c3:0:7}"; }

# ---- the default image
reset; newv
IMAGE=default DIGEST=$V2 run
check "default: a signed image built from main moves ITS latest, read back; dx latest is not touched" bash -c "[ $rc = 0 ] && grep -q 'moved=true' '$root/gout' && [ \"\$(cat '$root/reg/$V/tag/latest')\" = '$V2' ] && [ \"\$(cat '$root/reg/$D/tag/latest')\" = '$E0' ] && [ \$(grep -c 'skopeo copy' '$root/log') = 1 ]"
IMAGE=default DIGEST=$V2 run
check "default: run again is idempotent, nothing copied, a green no-op that says so" bash -c "[ $rc = 0 ] && grep -q 'latest unchanged' '$root/out' && grep -q 'moved=false' '$root/gout' && [ \$(grep -c 'skopeo copy' '$root/log') = 1 ]"
reset; newv; echo "$V2" > "$root/reg/unsigned"
IMAGE=default DIGEST=$V2 run
check "default: an unsigned image is refused, nothing copied" bash -c "[ $rc = 1 ] && grep -q 'no valid signature' '$root/out' && [ \$(grep -c 'skopeo copy' '$root/log') = 0 ]"
reset; mk $V "$Vs" "$cs" 2026-11-13T00:00:00Z -
IMAGE=default DIGEST=$Vs run
check "default: an image built from a commit that is not on main is refused" bash -c "[ $rc = 1 ] && grep -q 'not on' '$root/out' && [ \$(grep -c 'skopeo copy' '$root/log') = 0 ]"
reset; mk $V "$V1" "$c2" 2026-11-11T00:00:00Z -; mk $V "$V2" "$c3" 2026-11-13T00:00:00Z - latest
IMAGE=default DIGEST=$V1 run
check "default: ORDERING GUARD, an older commit (a re-run of an old green run) does not move latest backwards: held, exit 0, nothing copied" bash -c "[ $rc = 0 ] && grep -q 'latest held' '$root/out' && [ \$(grep -c 'skopeo copy' '$root/log') = 0 ] && [ \"\$(cat '$root/reg/$V/tag/latest')\" = '$V2' ]"
reset; mk $V "$V1" "$c1" 2026-11-09T00:00:00Z -
IMAGE=default DIGEST=$V1 run
check "default: ORDERING GUARD, the same commit built EARLIER than the one under latest is held too" bash -c "[ $rc = 0 ] && grep -q 'latest held' '$root/out' && [ \$(grep -c 'skopeo copy' '$root/log') = 0 ]"
reset; mk $V "$V1" "$c2" 2026-11-11T00:00:00Z -; mk $V "$V2" "$c3" 2026-11-13T00:00:00Z - latest
ALLOW_BACKWARDS=true IMAGE=default DIGEST=$V1 REASON="bad build" run
check "default: a ROLLBACK (ALLOW_BACKWARDS) skips only the ordering guard: the older signed image moves and the summary says ROLLBACK" bash -c "[ $rc = 0 ] && [ \"\$(cat '$root/reg/$V/tag/latest')\" = '$V1' ] && grep -q 'ROLLBACK, latest moved' '$root/out'"
reset; newv
DRY_RUN=true IMAGE=default DIGEST=$V2 run
check "dry_run: the plan is printed, nothing is copied, moved=false" bash -c "[ $rc = 0 ] && grep -q 'DRY RUN' '$root/out' && [ \$(grep -c 'skopeo copy' '$root/log') = 0 ] && grep -q 'moved=false' '$root/gout'"
WRITE=false IMAGE=default DIGEST=$V2 run
check "no WRITE (any ref but main): a dry run whatever DRY_RUN says" bash -c "[ $rc = 0 ] && grep -q 'DRY RUN' '$root/out' && [ \$(grep -c 'skopeo copy' '$root/log') = 0 ]"
FAKE_COPY_WRONG=1 IMAGE=default DIGEST=$V2 run
check "a copy whose read-back digest differs fails loudly" bash -c "[ $rc = 1 ] && grep -q 'expected' '$root/out' && ! grep -q 'moved=true' '$root/gout'"
reset; newv
FAKE_READ_ERROR=1 IMAGE=default DIGEST=$V2 run
check "a registry that cannot be read fails the run and copies nothing (a read error is not 'no latest yet')" bash -c "[ $rc != 0 ] && grep -q 'could not read the registry' '$root/out' && [ \$(grep -c 'skopeo copy' '$root/log') = 0 ]"
FAKE_COSIGN_READ_ERROR=1 IMAGE=default DIGEST=$V2 run
check "a cosign check that cannot complete fails as a read error, not as 'no valid signature'" bash -c "[ $rc != 0 ] && grep -q 'could not read the registry (signature of' '$root/out' && ! grep -q 'has no valid signature' '$root/out' && [ \$(grep -c 'skopeo copy' '$root/log') = 0 ]"
reset; newv
IMAGE=default TAG="latest-${c3:0:7}" run
check "dispatch with a dated tag: resolved to its digest and moved" bash -c "[ $rc = 0 ] && [ \"\$(cat '$root/reg/$V/tag/latest')\" = '$V2' ]"
reset; newv
IMAGE=default run
check "dispatch with no tag: the newest main commit that has a published latest-<sha7> is used" bash -c "[ $rc = 0 ] && [ \"\$(cat '$root/reg/$V/tag/latest')\" = '$V2' ]"
for t in testing-abc1234 latest; do IMAGE=default TAG=$t run
check "dispatch with the tag '$t' is refused" bash -c "[ $rc = 1 ] && grep -q 'not a dated tag' '$root/out'"; done

# ---- the dx image: its own latest, on a signed default image from main
reset; newv; newd
IMAGE=dx DIGEST=$E2 run
check "dx: moves ITS latest only; the default image latest is not touched, and the base need not be the default latest (independent images)" bash -c "[ $rc = 0 ] && [ \"\$(cat '$root/reg/$D/tag/latest')\" = '$E2' ] && [ \"\$(cat '$root/reg/$V/tag/latest')\" = '$V0' ] && [ \$(grep -c 'skopeo copy' '$root/log') = 1 ]"
IMAGE=dx DIGEST=$E2 run
check "dx: run again is idempotent" bash -c "[ $rc = 0 ] && grep -q 'latest unchanged' '$root/out' && [ \$(grep -c 'skopeo copy' '$root/log') = 1 ]"
reset; newv; newd; echo "$E2" > "$root/reg/unsigned"
IMAGE=dx DIGEST=$E2 run
check "dx: an unsigned dx image is refused" bash -c "[ $rc = 1 ] && grep -q 'no valid signature' '$root/out' && [ \$(grep -c 'skopeo copy' '$root/log') = 0 ]"
reset; newv; newd; echo "$V2" > "$root/reg/unsigned"
IMAGE=dx DIGEST=$E2 run
check "dx: WRONG BASE, a dx image whose base default image is unsigned is refused (the default image is checked at its own digest)" bash -c "[ $rc = 1 ] && grep -q 'no valid signature' '$root/out' && [ \$(grep -c 'skopeo copy' '$root/log') = 0 ]"
reset; mk $V "$Vs" "$cs" 2026-11-13T00:00:00Z -; newd "$Vs"
IMAGE=dx DIGEST=$E2 run
check "dx: NOT ON MAIN, a dx image whose base default image was built from a commit that is not on main is refused" bash -c "[ $rc = 1 ] && grep -q 'not on' '$root/out' && [ \$(grep -c 'skopeo copy' '$root/log') = 0 ]"
reset; newd -
IMAGE=dx DIGEST=$E2 run
check "dx: no base digest label is refused" bash -c "[ $rc = 1 ] && grep -q 'no usable base digest' '$root/out' && [ \$(grep -c 'skopeo copy' '$root/log') = 0 ]"
reset; newv; newd; mk $D "$E1" "$c2" 2026-11-11T00:00:00Z "$V0"; mk $D "$E2" "$c3" 2026-11-13T01:00:00Z "$V2" latest
IMAGE=dx DIGEST=$E1 run
check "dx: ORDERING GUARD per image, an older dx image does not move dx latest backwards" bash -c "[ $rc = 0 ] && grep -q 'latest held' '$root/out' && [ \$(grep -c 'skopeo copy' '$root/log') = 0 ] && [ \"\$(cat '$root/reg/$D/tag/latest')\" = '$E2' ]"
reset; newv; newd
FAKE_COPY_WRONG=1 IMAGE=dx DIGEST=$E2 run
check "dx: a read-back mismatch fails" bash -c "[ $rc = 1 ] && grep -q 'expected' '$root/out'"
reset; newv; newd
IMAGE=dx run
check "dx dispatch without a tag is refused (a variant needs its tag)" bash -c "[ $rc = 1 ] && grep -q 'dated tag is required' '$root/out'"
IMAGE=dx TAG="latest-20261113-${c3:0:7}" run
check "dx dispatch with its dated tag moves it" bash -c "[ $rc = 0 ] && [ \"\$(cat '$root/reg/$D/tag/latest')\" = '$E2' ]"
IMAGE=nvidia run
check "an unknown image name is refused" bash -c "[ $rc = 2 ]"
echo; echo "passed: $pass, failed: $failn"
[ "$failn" = 0 ]
