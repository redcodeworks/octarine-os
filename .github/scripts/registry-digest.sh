#!/usr/bin/env bash
# Print the manifest digest of ${IMAGE}:<tag> (IMAGE is registry/owner/name), or fail if the tag does not
# exist. The digest is that of the raw manifest (or manifest list) bytes, so it is the same for every tag
# that points at the same content. Used by plan-promote.sh as REGISTRY_LOOKUP and by the promote job.
set -euo pipefail
tag="${1:?tag}"
tmp=$(mktemp)
trap 'rm -f "${tmp}"' EXIT
skopeo inspect --raw "docker://${IMAGE:?IMAGE}:${tag}" > "${tmp}"
skopeo manifest-digest "${tmp}"
