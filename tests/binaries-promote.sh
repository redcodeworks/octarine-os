#!/usr/bin/env bash
# Tests for the promotion of the prebuilt binaries (.github/scripts/binaries-promote.sh, run by binaries.yml on main): the tested, signed `testing` image is retagged
# to `latest`; nothing else is ever put there. Fake skopeo (a directory of tags) and cosign; nothing is pulled. Needs: bash, git, jq. Run: tests/binaries-promote.sh
set -uo pipefail
export RETRY_DELAY=0 READBACK_WAIT=0
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
root=$(mktemp -d)
trap 'rm -rf -- "$root"' EXIT
pass=0; failn=0; rc=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { failn=$((failn + 1)); echo "FAIL $1"; sed 's/^/     run: /' "$root/run" 2> /dev/null; echo "     rc=$rc"; }
check() { local d=$1; shift; if "$@" > "$root/out" 2>&1; then ok "$d"; else bad "$d"; fi; }

bin="$root/bin"; st="$root/state"; mkdir -p "$bin" "$st"
cat > "$bin/skopeo" <<'F'
#!/usr/bin/env bash
echo "skopeo $*" >> "$LOG"
ref="${@: -1}"; ref="${ref#docker://}"; tag="${ref##*:}"
case "$1" in
    inspect)
        if [[ "$2" == --config ]]; then printf '{"config":{"Labels":{"org.opencontainers.image.version":"%s"}}}' "${VERSION_LABEL:-}"; exit 0; fi
        [[ -s "$ST/$tag" ]] || { echo "manifest unknown" >&2; exit 1; }
        cat "$ST/$tag" ;;
    manifest-digest) printf 'sha256:%s\n' "$(sha256sum "$2" | sed 's/ .*//')" ;;
    copy) cp "$ST/testing" "$ST/latest" ;;
esac
F
cat > "$bin/cosign" <<'F'
#!/usr/bin/env bash
echo "cosign $*" >> "$LOG"
[ "${COSIGN_RC:-0}" != 0 ] && echo "Error: no signatures found" >&2
exit "${COSIGN_RC:-0}"
F
chmod +x "$bin"/*
export LOG="$root/log" ST="$st"
IMG=ghcr.io/redcodeworks/octarine-binaries
want=$("$here/.github/scripts/binaries-key.sh")
promote() { # env assignments...
    : > "$LOG"; : > "$root/gho"
    env "$@" PATH="$bin:$PATH" GITHUB_OUTPUT="$root/gho" bash "$here/.github/scripts/binaries-promote.sh" "$IMG" > "$root/run" 2>&1; rc=$?
}

printf tested > "$st/testing"; rm -f "$st/latest"
promote VERSION_LABEL="$want"
check "tested image of this tree, no latest yet: copied, changed=true, latest signature verified" bash -c "[ $rc = 0 ] && [ \$(grep -c '^skopeo copy' '$LOG') = 1 ] && grep -qx 'changed=true' '$root/gho' && grep -q 'cosign verify --key cosign.pub $IMG:latest' '$LOG'"
promote VERSION_LABEL="$want"
check "latest already is the tested image: nothing copied, changed=false" bash -c "[ $rc = 0 ] && [ \$(grep -c '^skopeo copy' '$LOG') = 0 ] && grep -qx 'changed=false' '$root/gho'"
printf older > "$st/latest"
promote VERSION_LABEL="$want"
check "latest holds older content: it moves to the tested digest" bash -c "[ $rc = 0 ] && [ \$(grep -c '^skopeo copy' '$LOG') = 1 ] && grep -qx 'changed=true' '$root/gho' && cmp -s '$st/testing' '$st/latest'"

printf older > "$st/latest"
promote VERSION_LABEL=0000000000000000000000000000000000000000
check "testing was built from other content: fails loudly, latest untouched" bash -c "[ $rc != 0 ] && grep -q 'not the tested content' '$root/run' && [ \$(grep -c '^skopeo copy' '$LOG') = 0 ] && [ \"\$(cat '$st/latest')\" = older ]"
promote VERSION_LABEL="$want" COSIGN_RC=1
check "testing is not signed: fails, nothing copied" bash -c "[ $rc != 0 ] && [ \$(grep -c '^skopeo copy' '$LOG') = 0 ]"
rm -f "$st/testing"
promote VERSION_LABEL="$want"
check "no testing image at all: fails, nothing copied, nothing is built instead" bash -c "[ $rc != 0 ] && grep -q 'build the binaries on testing first' '$root/run' && [ \$(grep -c '^skopeo copy' '$LOG') = 0 ]"
echo; echo "passed: $pass, failed: $failn"
[ "$failn" = 0 ]
