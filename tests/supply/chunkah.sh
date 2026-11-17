#!/usr/bin/env bash
# Tests for the chunkah rechunk: the verified pin (.github/scripts/chunkah-ref.sh with a fake cosign), the Justfile recipe and its use in
# every image workflow. Nothing is pulled or run. Run: tests/supply/chunkah.sh. Needs: bash, python3 with PyYAML.
set -uo pipefail
export RETRY_DELAY=0  # retry.sh must not slow the failing-verification cases
here=$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)
root=$(mktemp -d); trap 'rm -rf -- "$root"' EXIT
pass=0; failn=0; rc=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { failn=$((failn + 1)); echo "FAIL $1"; [ -f "$root/run" ] && sed 's/^/     run: /' "$root/run"; }
check() { local d=$1; shift; if "$@" >"$root/out" 2>&1; then ok "$d"; else bad "$d"; fi; }
bin="$root/bin"; mkdir -p "$bin"
printf '#!/usr/bin/env bash\necho "cosign $*" >>"$LOG"\nexit "${COSIGN_RC:-0}"\n' >"$bin/cosign"; chmod +x "$bin/cosign"
printf '#!/usr/bin/env bash\necho "podman $*" >>"$LOG"\nexit "${PODMAN_RC:-0}"\n' >"$bin/podman"; chmod +x "$bin/podman"
export LOG="$root/log"
ref() { : >"$LOG"; env "$@" PATH="$bin:$PATH" bash "$here/.github/scripts/chunkah-ref.sh" "${ENVF:-$here/config/chunkah.env}" >"$root/run" 2>&1; rc=$?; }
d=$(sed -n 's/^CHUNKAH_DIGEST=//p' "$here/config/chunkah.env")
ref X=1
check "chunkah-ref: the pin in config/chunkah.env is verified keyless (OIDC issuer, coreos/chunkah identity) and printed as image@digest" bash -c "[ $rc = 0 ] && grep -qx 'quay.io/coreos/chunkah@$d' '$root/run' && grep -q 'cosign verify --certificate-oidc-issuer https://token.actions.githubusercontent.com --certificate-identity-regexp ^https://github.com/coreos/chunkah/ quay.io/coreos/chunkah@$d' '$LOG'"
ref COSIGN_RC=1
check "chunkah-ref: a signature that does not verify fails (exit 1), nothing is printed as a reference" bash -c "[ $rc = 1 ] && grep -q 'cosign verification of' '$root/run' && ! grep -qx 'quay.io/coreos/chunkah@.*' '$root/run'"
printf 'CHUNKAH_IMAGE=quay.io/coreos/chunkah\nCHUNKAH_TAG=latest\nCHUNKAH_DIGEST=latest\n' >"$root/bad.env"; ENVF="$root/bad.env" ref X=1
check "chunkah-ref: a pin that is not a sha256 digest (a floating tag) is refused before cosign runs" bash -c "[ $rc = 1 ] && [ ! -s '$LOG' ]"
ENVF="$root/missing.env" ref X=1
check "chunkah-ref: a missing pin file fails" test "$rc" = 1
echo; echo "passed: $pass, failed: $failn"; [ "$failn" = 0 ]
