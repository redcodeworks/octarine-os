#!/usr/bin/env bash
# `cosign verify` that tells a transient failure from a real one. Used wherever the RESULT of a verification decides something (promote, skip, reuse, fall back).
#
#   cosign-check.sh <cosign verify arguments...>        env: RETRY_TRIES (3), RETRY_DELAY (5)
#
# Exit status: 0 verified; 5 NOT VERIFIED: cosign said so explicitly (no signatures found, no matching signatures, an invalid signature, the image is not there)
# and nothing is retried; 4 READ ERROR: anything else (network, registry, timeout), retried, still failing after the last try. cosign's own message goes to stderr.
# The stdout of cosign is discarded (callers only want the verdict).
set -uo pipefail
[[ $# -gt 0 ]] || { echo "usage: cosign-check.sh <cosign verify arguments...>" >&2; exit 2; }
tries=${RETRY_TRIES:-3}; delay=${RETRY_DELAY:-5}
err=$(mktemp)
trap 'rm -f "${err}"' EXIT
for ((i = 1; i <= tries; i++)); do
    if cosign verify "$@" > /dev/null 2> "${err}"; then exit 0; fi
    if grep -qiE 'no signatures found|no matching signatures|invalid signature|signature verification failed|MANIFEST_UNKNOWN|NAME_UNKNOWN|manifest unknown|not found|none of the expected identities' "${err}"; then
        echo "cosign-check: not verified: $(head -c 300 "${err}" | tr '\n' ' ')" >&2
        exit 5
    fi
    if ((i < tries)); then
        echo "::warning::cosign verify failed (try ${i}/${tries}): $(head -c 200 "${err}" | tr '\n' ' '); retrying in $((delay * i)) s" >&2
        sleep $((delay * i))
    fi
done
echo "::error::cosign-check: could not complete the verification after ${tries} tries (a read error, NOT a bad signature): $(head -c 300 "${err}" | tr '\n' ' ')" >&2
exit 4
