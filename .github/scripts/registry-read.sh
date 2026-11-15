#!/usr/bin/env bash
# Read from a registry so that "the registry could not be read" is never mistaken for "it is not there". The one reader of the pipeline's decisions
# (what is published, what to promote, what to skip).
#
#   registry-read.sh raw|config <image reference without docker://>      env: RETRY_TRIES (3), RETRY_DELAY (5, the pause before try k+1 is DELAY*k)
#
# raw     the raw manifest (skopeo inspect --raw)         config   the image config JSON (skopeo inspect --config)
# Exit status: 0 the answer is on stdout; 3 ABSENT: skopeo said explicitly that the tag or repository does not exist (manifest unknown, name unknown, not found,
# 404) and nothing is retried; 4 READ ERROR: anything else (network, TLS, 5xx, rate limit, a timeout), retried and still failing after the last try, with
# skopeo's own message on stderr. Callers decide: a missing candidate may mean "build instead", an unreadable registry must never silently mean that.
set -uo pipefail
mode=${1:?raw|config}
ref=${2:?image reference}
case "${mode}" in raw) flag=--raw ;; config) flag=--config ;; *) echo "registry-read.sh: mode must be raw or config" >&2; exit 2 ;; esac
tries=${RETRY_TRIES:-3}; delay=${RETRY_DELAY:-5}
err=$(mktemp); out=$(mktemp)
trap 'rm -f "${err}" "${out}"' EXIT
for ((i = 1; i <= tries; i++)); do
    if skopeo inspect "${flag}" "docker://${ref}" > "${out}" 2> "${err}" && [[ -s "${out}" ]]; then cat "${out}"; exit 0; fi
    if grep -qiE 'manifest unknown|name unknown|MANIFEST_UNKNOWN|NAME_UNKNOWN|not found|\b404\b|no such manifest' "${err}"; then
        echo "registry-read: ${ref} does not exist ($(head -c 200 "${err}" | tr '\n' ' '))" >&2
        exit 3
    fi
    if ((i < tries)); then
        echo "::warning::registry read of ${ref} failed (try ${i}/${tries}): $(head -c 200 "${err}" | tr '\n' ' '); retrying in $((delay * i)) s" >&2
        sleep $((delay * i))
    fi
done
echo "::error::registry-read: could not read ${ref} after ${tries} tries (a read error, NOT a missing image): $(head -c 300 "${err}" | tr '\n' ' ')" >&2
exit 4
