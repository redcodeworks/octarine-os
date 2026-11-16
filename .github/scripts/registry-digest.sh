#!/usr/bin/env bash
# Print the manifest digest of ${IMAGE}:<tag> (IMAGE is registry/owner/name). The digest is that of the raw manifest (or manifest list) bytes, so it is the same for every
# tag that points at the same content. Used by plan-promote.sh and plan-vanilla-reuse.sh as REGISTRY_LOOKUP and by the promote job.
# Exit status (the contract of every REGISTRY_LOOKUP): 0 the digest is printed; 3 the tag does not exist (skopeo said so explicitly); 4 the registry could not be read
# (retried by registry-read.sh): a caller must not take that for "absent".
set -euo pipefail
tag="${1:?tag}"
tmp=$(mktemp)
trap 'rm -f "${tmp}"' EXIT
rc=0
"$(dirname "${BASH_SOURCE[0]}")/registry-read.sh" raw "${IMAGE:?IMAGE}:${tag}" > "${tmp}" || rc=$?
[[ "${rc}" == 0 ]] || exit "${rc}"
skopeo manifest-digest "${tmp}"
