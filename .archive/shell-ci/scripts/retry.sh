#!/usr/bin/env bash
# THE retry helper of the pipeline: run a command up to N times with a growing pause, for calls to the network (registries, apt, cosign's transparency
# and key lookups) that fail for a moment. It changes nothing else: what is verified stays the same, a permanent failure (a bad signature, a missing
# package) runs out the tries and then fails with the command's own exit status and a clear message.
#
#   retry.sh [-n TRIES] [-d DELAY] [--] command [args...]      (defaults: RETRY_TRIES=3, RETRY_DELAY=5 seconds; the pause before try k+1 is DELAY*k)
#
# stdout and stderr of the command pass through; the notices go to stderr as ::warning:: (every failed try) and ::error:: (the last one). Exit status:
# 0 when a try succeeded, else the status of the last try. Needs only bash. Not for commands that must not run twice (a push that is not idempotent).
set -uo pipefail
tries=${RETRY_TRIES:-3}
delay=${RETRY_DELAY:-5}
while (($#)); do
    case $1 in
        -n) tries=$2; shift 2 ;;
        -d) delay=$2; shift 2 ;;
        --) shift; break ;;
        *) break ;;
    esac
done
[[ "${tries}" =~ ^[1-9][0-9]*$ ]] || { echo "retry.sh: bad tries '${tries}'" >&2; exit 2; }
[[ "${delay}" =~ ^[0-9]+$ ]] || { echo "retry.sh: bad delay '${delay}'" >&2; exit 2; }
[[ $# -gt 0 ]] || { echo "usage: retry.sh [-n TRIES] [-d DELAY] [--] command [args...]" >&2; exit 2; }
rc=0
for ((i = 1; i <= tries; i++)); do
    "$@" && exit 0
    rc=$?
    if ((i < tries)); then
        echo "::warning::try ${i}/${tries} failed (exit ${rc}): $1 ${2:-}; retrying in $((delay * i)) s" >&2
        sleep $((delay * i))
    fi
done
echo "::error::$1 ${2:-} failed ${tries} times (last exit ${rc}); a transient network error would have passed by now, so treat this as a real failure (bad signature, missing package or tag, or a longer outage)" >&2
exit "${rc}"
