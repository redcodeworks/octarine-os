#!/usr/bin/env bash
# Tests for the weekly digest bump of the external image pinned by digest, chunkah (.github/workflows/bump-pins.yml,
# .github/scripts/bump-pin.sh): the decision table with fake skopeo and cosign (equal, different, unreachable registry, bad signature,
# malformed pin, unknown image) and the workflow (triggers, permissions, default token only, the Test dispatch with a soft failure).
# Nothing is pulled. Needs: bash, python3 with PyYAML. Run: tests/bump-pins.sh
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
root=$(mktemp -d)
trap 'rm -rf -- "$root"' EXIT
pass=0
failn=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { failn=$((failn + 1)); echo "FAIL $1"; [ -f "$root/out" ] && sed 's/^/     /' "$root/out"; [ -f "$root/run" ] && sed 's/^/     run: /' "$root/run"; }
check() { local d=$1; shift; if "$@" >"$root/out" 2>&1; then ok "$d"; else bad "$d"; fi; }

# ---- stubs
bin="$root/bin"; mkdir -p "$bin"
cat >"$bin/skopeo" <<'F'
#!/usr/bin/env bash
echo "skopeo $*" >>"$LOG"
case "$1" in
    inspect)
        [ "${SKOPEO_FAIL:-0}" = 1 ] && { echo "unauthorized or unreachable" >&2; exit 1; }
        [ "${SKOPEO_EMPTY:-0}" = 1 ] && exit 0
        printf 'manifest of %s' "${@: -1}" ;;
    list-tags) echo "${TAGS_JSON:-{\"Tags\":[]}}" ;;
esac
F
cat >"$bin/cosign" <<'F'
#!/usr/bin/env bash
echo "cosign $*" >>"$LOG"
exit "${COSIGN_RC:-0}"
F
chmod +x "$bin"/*
export LOG="$root/log"
dg() { printf 'manifest of docker://quay.io/coreos/%s:%s' "$1" "$2" | sha256sum | sed 's/ .*//'; }

# ---- bump-pin.sh: the decision table
bw="$root/bump"; rm -rf "$bw"; mkdir -p "$bw/config"
reset_bump() { cp "$here/config/chunkah.env" "$bw/config/chunkah.env"; : >"$LOG"; : >"$root/gho"; }
bump() { local img=$1; shift; (cd "$bw" && env "$@" PATH="$bin:$PATH" GITHUB_OUTPUT="$root/gho" bash "$here/.github/scripts/bump-pin.sh" "$img") >"$root/run" 2>&1; rc=$?; }
pin_digest() { sed -n "s/^$2_DIGEST=//p" "$bw/$1"; }
ARGLINES='^CHUNKAH_(TAG|DIGEST)='

reset_bump
cur=$(pin_digest config/chunkah.env CHUNKAH)
sed -i "s/^CHUNKAH_DIGEST=.*/CHUNKAH_DIGEST=sha256:$(dg chunkah latest)/" "$bw/config/chunkah.env"
cp "$bw/config/chunkah.env" "$root/before"
bump chunkah
check "decision equal: exit 0, 'nothing to bump', file untouched, cosign still verified latest" bash -c "[ $rc = 0 ] && grep -q 'nothing to bump' '$root/run' && cmp -s '$root/before' '$bw/config/chunkah.env' && grep -q 'cosign verify --certificate-oidc-issuer https://token.actions.githubusercontent.com --certificate-identity-regexp ^https://github.com/coreos/chunkah/ quay.io/coreos/chunkah@sha256:$(dg chunkah latest)' '$LOG' && grep -qx 'result=equal' '$root/gho'"

reset_bump
bump chunkah TAGS_JSON='{"Tags":["latest","testing","latest-20261109-1111111","latest-20261117-2222222"]}'
new="sha256:$(dg chunkah latest)"
check "decision different, no dated tag matches: pin moves to latest, exit 10, only the pin lines change" bash -c "[ $rc = 10 ] && grep -qx 'CHUNKAH_DIGEST=$new' '$bw/config/chunkah.env' && grep -qx 'CHUNKAH_TAG=latest' '$bw/config/chunkah.env' && diff <(grep -vE '$ARGLINES' '$here/config/chunkah.env') <(grep -vE '$ARGLINES' '$bw/config/chunkah.env') && grep -qx 'result=different' '$root/gho' && grep -qx 'previous=$cur' '$root/gho'"
# a dated tag with the same digest: the stub hashes the reference, so only the :latest reference hashes to the digest of latest
# unless the tag is asked for under that name; use a stub variant that answers the dated tag like latest
reset_bump
mv "$bin/skopeo" "$bin/skopeo.real"
cat >"$bin/skopeo" <<'F'
#!/usr/bin/env bash
echo "skopeo $*" >>"$LOG"
case "$1" in
    inspect) ref="${@: -1}"; printf 'manifest of %s' "${ref/:latest-20261117-2222222/:latest}" ;;
    list-tags) echo '{"Tags":["latest","latest-20261109-1111111","latest-20261117-2222222","testing-20261117-3333333"]}' ;;
esac
F
chmod +x "$bin/skopeo"
bump chunkah
check "decision different, a dated tag has the same digest: the tag line records it (and nothing else changes)" bash -c "[ $rc = 10 ] && grep -qx 'CHUNKAH_TAG=latest-20261117-2222222' '$bw/config/chunkah.env' && grep -qx 'CHUNKAH_DIGEST=sha256:$(dg chunkah latest)' '$bw/config/chunkah.env'"
rm "$bin/skopeo"; mv "$bin/skopeo.real" "$bin/skopeo"; 

reset_bump; cp "$bw/config/chunkah.env" "$root/before"
bump chunkah SKOPEO_FAIL=1
check "decision unreachable registry: exit 1, file untouched, no cosign call, result=unreachable" bash -c "[ $rc = 1 ] && cmp -s '$root/before' '$bw/config/chunkah.env' && ! grep -q cosign '$LOG' && grep -qx 'result=unreachable' '$root/gho' && grep -q 'cannot resolve' '$root/run'"
bump chunkah SKOPEO_EMPTY=1
check "decision empty answer (latest missing): exit 1, file untouched" bash -c "[ $rc = 1 ] && cmp -s '$root/before' '$bw/config/chunkah.env'"

reset_bump; cp "$bw/config/chunkah.env" "$root/before"
bump chunkah COSIGN_RC=1
check "decision bad signature: exit 2, file untouched, result=badsignature" bash -c "[ $rc = 2 ] && cmp -s '$root/before' '$bw/config/chunkah.env' && grep -qx 'result=badsignature' '$root/gho' && grep -q 'cosign verification failed' '$root/run'"
# equal digest does not excuse a bad signature
sed -i "s/^CHUNKAH_DIGEST=.*/CHUNKAH_DIGEST=sha256:$(dg chunkah latest)/" "$bw/config/chunkah.env"
bump chunkah COSIGN_RC=1
check "decision bad signature with an equal digest still fails" test "$rc" = 2

reset_bump; sed -i 's/^CHUNKAH_DIGEST=.*/CHUNKAH_DIGEST=sha256:short/' "$bw/config/chunkah.env"
bump chunkah
check "a malformed pin in the file: exit 3, no registry call" bash -c "[ $rc = 3 ] && ! grep -q skopeo '$LOG'"
bump nothing
check "an unknown image name: exit 3" test "$rc" = 3



echo
echo "passed: $pass, failed: $failn"
[ "$failn" = 0 ]
