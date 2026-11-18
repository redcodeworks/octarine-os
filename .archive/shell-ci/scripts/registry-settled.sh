#!/usr/bin/env bash
# Read a tag back after a write until it shows the expected digest ("settled"): the registry may answer a read right after a push or a copy with the PREVIOUS manifest
# of the tag (seen on GHCR 2026-11-14), or fail the read for a moment. The one read-back of the pipeline (push-tags.sh, publish-latest.sh, the retag read-backs of the promote jobs).
#
#   registry-settled.sh <image (registry/owner/name)> <tag> <expected digest>       env: READBACK_TRIES (default 6), READBACK_WAIT (seconds apart, default 5)
#
# Exit 0 as soon as one read shows the expected digest; exit 1 when after the last read the tag still shows another digest (a wrong copy) or could not be read, with the
# last answer in the message (the digest, "absent" or "unreadable").
set -uo pipefail
image=${1:?image}; tag=${2:?tag}; want=${3:?expected digest}
tries=${READBACK_TRIES:-6}
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
got=""
for ((i = 1; i <= tries; i++)); do
    rc=0
    got=$(IMAGE="${image}" RETRY_TRIES=1 "${here}/registry-digest.sh" "${tag}" 2> /dev/null) || rc=$?
    case "${rc}" in 0) ;; 3) got="absent" ;; *) got="unreadable" ;; esac
    [[ "${got}" != "${want}" ]] || exit 0
    ((i == tries)) || sleep "${READBACK_WAIT:-5}"
done
echo "::error::${image}:${tag} is ${got}, expected ${want} (after ${tries} reads)" >&2
exit 1
