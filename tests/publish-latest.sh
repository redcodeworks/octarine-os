#!/usr/bin/env bash
# Tests .github/scripts/publish-latest.sh (the one step that moves `latest` of the default image and the dx image together, or of the
# default image alone) with a fake registry (stub skopeo), a stub cosign and a throwaway git repository that plays main. Run: tests/publish-latest.sh
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
cp "$here/.github/scripts/registry-digest.sh" "$root/repo/.github/scripts/"
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
    "inspect --raw") d=$(resolve "$3") || exit 1; printf 'MANIFEST:%s' "$d" ;;
    "manifest-digest "*) sed 's/^MANIFEST://' "$2" ;;
    "inspect --config") d=$(resolve "$3") || exit 1; split "$3"; cat "$reg/$img/cfg/$d" ;;
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
case "$ref" in *@sha256:*) d=${ref#*@} ;; *) d=$(cat "$FAKE_REG/$img/tag/${ref#*:}" 2>/dev/null) || exit 1 ;; esac
! grep -qxF "$d" "$FAKE_REG/unsigned" 2>/dev/null
F
chmod +x "$root/bin"/*
for c in bash env cat grep sed jq git sort head tr ls paste dirname mktemp rm sha256sum awk date mkdir; do p=$(command -v "$c") && ln -sf "$p" "$root/bin/$c"; done
export FAKE_REG="$root/reg" FAKE_LOG="$root/log" OWNER=RedCodeWorks MAIN_REF=refs/remotes/origin/main WRITE=true
V=octarine-os; D=octarine-os-dx
reset() {
    rm -rf "${root:?}/reg"; mkdir -p "$root/reg"; : > "$root/log"; unset FAKE_COPY_WRONG DRY_RUN SCOPE VANILLA_DIGEST DX_DIGEST VANILLA_TAG REASON; export WRITE=true
    # currently published pair: V1 (main c2) and E0... start with V0/E0 at latest
    mk $V "$V0" "$c1" 2026-11-10T00:00:00Z - latest "latest-${c1:0:7}"
    mk $D "$E0" "$c1" 2026-11-10T01:00:00Z "$V0" latest "latest-20261110-${c1:0:7}"
    : > "$root/reg/unsigned"
}
run() { rm -f "$root/gout"; PATH="$root/bin" GITHUB_OUTPUT="$root/gout" GITHUB_STEP_SUMMARY="$root/sum" bash "$root/repo/.github/scripts/publish-latest.sh" >"$root/out" 2>&1; rc=$?; }
tagis() { [ "$(cat "$root/reg/$1/tag/$2" 2>/dev/null)" = "$3" ]; }
copies() { grep -c 'skopeo copy' "$root/log"; }
: > "$root/sum"

# ---- called from the dx run
reset; mk $V "$V2" "$c3" 2026-11-13T00:00:00Z - "latest-${c3:0:7}"; mk $D "$E2" "$c3" 2026-11-13T01:00:00Z "$V2" "latest-20261113-${c3:0:7}"
VANILLA_DIGEST=$V2 DX_DIGEST=$E2 run
check "a verified pair moves BOTH latest tags, dx first and the default image last, each read back" bash -c "[ $rc = 0 ] && grep -q 'moved=true' '$root/gout' && grep -q 'latest moved:' '$root/out' && [ \$(grep -n 'copy.*octarine-os-dx:latest' '$root/log' | head -1 | cut -d: -f1) -lt \$(grep -n 'copy.*octarine-os:latest' '$root/log' | head -1 | cut -d: -f1) ]"
check "...and the registry has the new digests under latest" bash -c "[ \"\$(cat '$root/reg/$V/tag/latest')\" = '$V2' ] && [ \"\$(cat '$root/reg/$D/tag/latest')\" = '$E2' ]"
VANILLA_DIGEST=$V2 DX_DIGEST=$E2 run; n1=$(copies)
check "run again: idempotent, nothing copied, a green no-op that says so" bash -c "[ $rc = 0 ] && grep -q 'latest unchanged' '$root/out' && grep -q 'moved=false' '$root/gout' && [ \$(grep -c 'skopeo copy' '$root/log') = 2 ]"
reset; mk $V "$V2" "$c3" 2026-11-13T00:00:00Z - "latest-${c3:0:7}"; mk $D "$E2" "$c3" 2026-11-13T01:00:00Z "$V2" "latest-20261113-${c3:0:7}"
echo "$V2" > "$root/reg/$V/tag/latest"
VANILLA_DIGEST=$V2 DX_DIGEST=$E2 run
check "a half-finished earlier run (default image already moved): the missing dx tag is moved, no second copy of the default image" bash -c "[ $rc = 0 ] && [ \$(grep -c 'skopeo copy' '$root/log') = 1 ] && grep -q 'octarine-os-dx:latest' '$root/log' && [ \"\$(cat '$root/reg/$D/tag/latest')\" = '$E2' ]"
reset; mk $V "$V2" "$c3" 2026-11-13T00:00:00Z - "latest-${c3:0:7}"; mk $D "$E2" "$c3" 2026-11-13T01:00:00Z "$V1"
VANILLA_DIGEST=$V2 DX_DIGEST=$E2 run
check "the dx image was built on another default image (base digest label): refused, nothing copied" bash -c "[ $rc = 1 ] && grep -q 'was not built on' '$root/out' && [ \$(grep -c 'skopeo copy' '$root/log') = 0 ]"
reset; mk $V "$V2" "$c3" 2026-11-13T00:00:00Z -; mk $D "$E2" "$c3" 2026-11-13T01:00:00Z "$V2"; echo "$E2" > "$root/reg/unsigned"
VANILLA_DIGEST=$V2 DX_DIGEST=$E2 run
check "an unsigned dx image is refused BEFORE any copy (the default image does not move either)" bash -c "[ $rc = 1 ] && grep -q 'no valid signature' '$root/out' && [ \$(grep -c 'skopeo copy' '$root/log') = 0 ]"
reset; mk $V "$V2" "$c3" 2026-11-13T00:00:00Z -; mk $D "$E2" "$c3" 2026-11-13T01:00:00Z "$V2"; echo "$V2" > "$root/reg/unsigned"
VANILLA_DIGEST=$V2 DX_DIGEST=$E2 run
check "an unsigned default image is refused" bash -c "[ $rc = 1 ] && grep -q 'no valid signature' '$root/out' && [ \$(grep -c 'skopeo copy' '$root/log') = 0 ]"
reset; mk $V "$Vs" "$cs" 2026-11-13T00:00:00Z -; mk $D "$Ex" "$cs" 2026-11-13T01:00:00Z "$Vs"
VANILLA_DIGEST=$Vs DX_DIGEST=$Ex run
check "a default image built from a commit that is not on main is refused" bash -c "[ $rc = 1 ] && grep -q 'not on' '$root/out' && [ \$(grep -c 'skopeo copy' '$root/log') = 0 ]"
reset; mk $V "$V1" "$c2" 2026-11-11T00:00:00Z -; mk $D "$E1" "$c2" 2026-11-11T01:00:00Z "$V1"
echo "$V2" > "$root/reg/$V/tag/latest"; mk $V "$V2" "$c3" 2026-11-13T00:00:00Z - latest; mk $D "$E2" "$c3" 2026-11-13T01:00:00Z "$V2" latest
VANILLA_DIGEST=$V1 DX_DIGEST=$E1 run
check "ORDERING GUARD: a re-run of an older green run (older main commit) does not move latest backwards: held, exit 0, nothing copied" bash -c "[ $rc = 0 ] && grep -q 'latest held' '$root/out' && [ \$(grep -c 'skopeo copy' '$root/log') = 0 ] && [ \"\$(cat '$root/reg/$V/tag/latest')\" = '$V2' ]"
reset; mk $V "$V1" "$c1" 2026-11-09T00:00:00Z -; mk $D "$E1" "$c1" 2026-11-09T01:00:00Z "$V1"
VANILLA_DIGEST=$V1 DX_DIGEST=$E1 run
check "ORDERING GUARD: the same commit built EARLIER (label created) is held back too" bash -c "[ $rc = 0 ] && grep -q 'latest held' '$root/out' && [ \$(grep -c 'skopeo copy' '$root/log') = 0 ]"
reset; mk $V "$V2" "$c3" 2026-11-13T00:00:00Z -; mk $D "$E2" "$c3" 2026-11-13T01:00:00Z "$V2"
DRY_RUN=true VANILLA_DIGEST=$V2 DX_DIGEST=$E2 run
check "dry_run: the plan is printed, nothing is copied, moved=false" bash -c "[ $rc = 0 ] && grep -q 'DRY RUN' '$root/out' && [ \$(grep -c 'skopeo copy' '$root/log') = 0 ] && grep -q 'moved=false' '$root/gout'"
WRITE=false VANILLA_DIGEST=$V2 DX_DIGEST=$E2 run
check "a ref that may not write (WRITE not true) is a dry run whatever else is set" bash -c "[ $rc = 0 ] && grep -q 'DRY RUN' '$root/out' && [ \$(grep -c 'skopeo copy' '$root/log') = 0 ]"
FAKE_COPY_WRONG=1 VANILLA_DIGEST=$V2 DX_DIGEST=$E2 run
check "a copy whose read-back digest differs fails loudly" bash -c "[ $rc = 1 ] && grep -q 'expected' '$root/out'"
reset; mk $V "$V2" "$c3" 2026-11-13T00:00:00Z - ; mk $D "$E2" "$c3" 2026-11-13T01:00:00Z "$V2"; echo "$E0" >/dev/null
mk $D "$E0" "$c1" 2026-11-10T01:00:00Z "$V2" latest   # dx latest already built on this default image
VANILLA_DIGEST=$V2 run
check "dx unchanged (no dx digest handed over): dx latest must be built on this default image, only the default image moves" bash -c "[ $rc = 0 ] && [ \$(grep -c 'skopeo copy' '$root/log') = 1 ] && [ \"\$(cat '$root/reg/$V/tag/latest')\" = '$V2' ]"
reset; mk $V "$V2" "$c3" 2026-11-13T00:00:00Z -
VANILLA_DIGEST=$V2 run
check "dx unchanged but dx latest is built on ANOTHER default image: refused" bash -c "[ $rc = 1 ] && grep -q 'was not built on' '$root/out'"

# ---- dispatched: both (default: newest main commit with a published image) and vanilla-only (the escape hatch)
reset; mk $V "$V1" "$c2" 2026-11-11T00:00:00Z - "latest-${c2:0:7}" "latest-20261111-${c2:0:7}"; mk $D "$E1" "$c2" 2026-11-11T01:00:00Z "$V1" "latest-20261111-${c2:0:7}"
run
check "dispatch both without a tag: the newest commit of main with a published latest-<sha7> (c2, c3 has none) and the dx image built on it" bash -c "[ $rc = 0 ] && [ \"\$(cat '$root/reg/$V/tag/latest')\" = '$V1' ] && [ \"\$(cat '$root/reg/$D/tag/latest')\" = '$E1' ]"
reset; mk $V "$V1" "$c2" 2026-11-11T00:00:00Z - "latest-${c2:0:7}"
run
check "dispatch both, no dx image was built on that default image: fails and names the way out" bash -c "[ $rc = 1 ] && grep -q 'no dx image was built on' '$root/out' && grep -q 'vanilla-only' '$root/out'"
reset; mk $V "$V2" "$c3" 2026-11-13T00:00:00Z - "latest-${c3:0:7}" "latest-20261113-${c3:0:7}"
SCOPE=vanilla-only REASON="CVE-2026-0001" run
check "vanilla-only: only the default image moves, no dx image is needed, the summary says dx latest is behind and carries the reason" bash -c "[ $rc = 0 ] && [ \"\$(cat '$root/reg/$V/tag/latest')\" = '$V2' ] && [ \"\$(cat '$root/reg/$D/tag/latest')\" = '$E0' ] && grep -q 'NOT moved and is behind' '$root/out' && grep -q 'CVE-2026-0001' '$root/out'"
reset; mk $V "$V2" "$c3" 2026-11-13T00:00:00Z - "latest-20261113-${c3:0:7}"
SCOPE=vanilla-only VANILLA_TAG="latest-20261113-${c3:0:7}" run
check "vanilla-only with a dated tag names it" bash -c "[ $rc = 0 ] && [ \"\$(cat '$root/reg/$V/tag/latest')\" = '$V2' ]"
for bad_tag in testing-abcdef1 beta beta-20261113-abcdef1 latest "latest-20261113" "../x" "latest-20261113-abcdef1;x" "candidate"; do
    reset; SCOPE=vanilla-only VANILLA_TAG="$bad_tag" run
    check "vanilla-only refuses the tag '$bad_tag'" bash -c "[ $rc != 0 ] && [ \$(grep -c 'skopeo copy' '$root/log') = 0 ]"
done
reset; mk $V "$Vs" "$cs" 2026-11-13T00:00:00Z - "latest-20261113-${cs:0:7}"
SCOPE=vanilla-only VANILLA_TAG="latest-20261113-${cs:0:7}" run
check "vanilla-only refuses a signed dated image that was not built from main" bash -c "[ $rc = 1 ] && grep -q 'not on' '$root/out' && [ \$(grep -c 'skopeo copy' '$root/log') = 0 ]"
reset; mk $V "$V2" "$c3" 2026-11-13T00:00:00Z - "latest-20261113-${c3:0:7}"; echo "$V2" > "$root/reg/unsigned"
SCOPE=vanilla-only VANILLA_TAG="latest-20261113-${c3:0:7}" run
check "vanilla-only refuses an unsigned image" bash -c "[ $rc = 1 ] && grep -q 'no valid signature' '$root/out'"
check "the script never signs, never logs in and never writes anything but the latest tag of the two images" bash -c "! grep -E 'cosign sign|docker login|skopeo login|--dest-creds' '$script' && [ \$(grep -c 'skopeo copy' '$script') = 1 ]"
echo; echo "passed: $pass, failed: $failn"
[ "$failn" = 0 ]
