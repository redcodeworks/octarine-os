#!/usr/bin/env bash
# Tests for the floating base with safeguards (.github/scripts/base_pin.py): the tag is resolved to a digest once, its signature is verified with the pinned
# Universal Blue key, a failure stops the build. Fake skopeo and cosign.
# Run: tests/supply/base-pin.sh. Needs: bash, jq.
set -uo pipefail
here=$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)
root=$(mktemp -d); trap 'rm -rf -- "$root"' EXIT
pass=0; failn=0; rc=0
# the CI runner exports these (root-owned files the test user cannot write): the script must only write where each case points them
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { failn=$((failn + 1)); echo "FAIL $1"; sed 's/^/     /' "$root/run" 2>/dev/null; }
check() { local d=$1; shift; if "$@" >"$root/out" 2>&1; then ok "$d"; else bad "$d"; fi; }
py=$(command -v python3)
bin="$root/bin"; mkdir -p "$bin"
cat >"$bin/skopeo" <<'F'
#!/usr/bin/env bash
echo "skopeo $*" >>"$LOG"
[ "${READ_ERROR:-0}" = 1 ] && { echo "dial tcp: i/o timeout" >&2; exit 1; }
[ "${NO_TAG:-0}" = 1 ] && { echo "Error: manifest unknown" >&2; exit 1; }
printf '%s' "${MANIFEST}"
F
cat >"$bin/cosign" <<'F'
#!/usr/bin/env bash
echo "cosign $*" >>"$LOG"
ref="${@: -1}"
# SIGNED lists the digests that carry a valid signature
case " ${SIGNED:-} " in *" ${ref#*@} "*) exit 0 ;; esac
[ "${COSIGN_ERR:-}" = timeout ] && { echo "Error: GET https://ghcr.io: TLS handshake timeout" >&2; exit 1; }
[ "${COSIGN_ERR:-}" = nosig ] && { echo "Error: no signatures found" >&2; exit 1; }
echo "Error: no matching signatures: failed to verify signature" >&2
exit 1
F
chmod +x "$bin"/*
export RETRY_DELAY=0 LOG="$root/log" BASE_IMAGE=ghcr.io/ublue-os/silverblue-main FEDORA_VERSION=45
echo key >"$root/key.pub"
CHILD="sha256:$(printf 'c%.0s' {1..64})"
LIST="{\"manifests\":[{\"digest\":\"sha256:$(printf 'e%.0s' {1..64})\",\"platform\":{\"os\":\"linux\",\"architecture\":\"arm64\"}},{\"digest\":\"$CHILD\",\"platform\":{\"os\":\"linux\",\"architecture\":\"amd64\"}}]}"
SINGLE='{"schemaVersion":2,"layers":[]}'
pin_of() { printf 'sha256:'; printf '%s' "$1" | sha256sum | sed 's/ .*//'; }
bp() { : >"$LOG"; : >"$root/genv"; : >"$root/sum"; env "$@" KEY="$root/key.pub" PATH="$bin:$PATH" GITHUB_ENV="$root/genv" GITHUB_STEP_SUMMARY="$root/sum" "$py" -I "$here/.github/scripts/base_pin.py" >"$root/run" 2>&1; rc=$?; }
P=$(pin_of "$SINGLE"); bp MANIFEST="$SINGLE" SIGNED="$P"
check "a signed single manifest: the tag is resolved to its digest once, verified with the key, BASE_PIN printed, exported and named in the summary" bash -c "[ $rc = 0 ] && grep -qx 'BASE_PIN=$P' '$root/run' && grep -qx 'BASE_PIN=$P' '$root/genv' && grep -q 'resolved ONCE to \`$P\`' '$root/sum' && grep -q 'cosign verify --key $root/key.pub ghcr.io/ublue-os/silverblue-main@$P' '$LOG' && [ \$(grep -c '^skopeo' '$LOG') = 1 ]"
bp MANIFEST="$SINGLE" SIGNED=""
check "an unsigned or differently signed base FAILS the build (exit 1), names the key, a possible key rotation, nothing exported" bash -c "[ $rc = 1 ] && grep -q 'is not signed by $root/key.pub' '$root/run' && grep -q 'rotated its signing key' '$root/run' && [ ! -s '$root/genv' ]"
bp READ_ERROR=1 MANIFEST=x SIGNED=x
check "a registry that cannot be read is a read error (re-run), not a missing tag, and nothing is verified" bash -c "[ $rc = 1 ] && grep -q 'registry read error' '$root/run' && ! grep -q 'cannot resolve' '$root/run' && ! grep -q '^cosign' '$LOG'"
bp COSIGN_ERR=timeout MANIFEST="$LIST" SIGNED=""
check "a cosign check that cannot be completed says TRANSIENT (a read error, not a wrong key) and fails" bash -c "[ $rc = 1 ] && grep -q 'could not be checked after the retries' '$root/run' && ! grep -q 'rotated its signing key' '$root/run'"
echo; echo "passed: $pass, failed: $failn"; [ "$failn" = 0 ]
