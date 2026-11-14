#!/usr/bin/env bash
# Publish one built image under several tags with ONE manifest digest:
#
#   push-tags.sh <local-image> <registry-image> <tag> [<tag>...]
#
# The first tag is pushed with `podman push --digestfile`; every other tag is a registry-side copy of that digest
# (`skopeo copy --all --preserve-digests`), so all tags point at the same manifest and one signature (which belongs
# to the digest) covers them. Pushing the same local image once per tag does not do that: podman writes a manifest
# per push and the digests of the tags differ although the content is the same (observed 2026-11-10 on
# octarine-os:testing vs testing-cc213cb), which is what kept the dx promotion from ever matching.
# After every copy the digest of the tag is read back from the registry (polled for up to 30 s: reads can lag a write) and must equal the pushed one.
#
# Output: `digests=<digest>` appended to $GITHUB_OUTPUT (when set), and printed. Tools: podman, skopeo, sha256sum.
set -euo pipefail
local_image="${1:?local image}"
registry_image="${2:?registry image}"
shift 2
[[ $# -ge 1 ]] || { echo "::error::push-tags.sh needs at least one tag" >&2; exit 1; }

first="$1"
shift
digestfile=$(mktemp)
trap 'rm -f "${digestfile}"' EXIT
podman push --digestfile="${digestfile}" "${local_image}" "${registry_image}:${first}"
digest=$(tr -d '[:space:]' < "${digestfile}")
[[ "${digest}" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "::error::podman push gave no digest for ${first} ('${digest}')" >&2; exit 1; }

registry_digest() { echo "sha256:$(skopeo inspect --raw "docker://${registry_image}:$1" | sha256sum | sed 's/ .*//')"; }

# The registry may answer a read right after a push or a copy with the PREVIOUS manifest of the tag (seen on GHCR 2026-11-14: the
# read-back of `testing` right after the copy returned the old digest, the next read the new one). So the read-back polls: it passes as
# soon as the tag shows the expected digest and fails only when it still shows another one after READBACK_TRIES reads (default 6,
# READBACK_WAIT seconds apart, default 5). A tag that really holds other content (a wrong copy) still fails.
settled() { # tag expected
    local got="" i tries="${READBACK_TRIES:-6}"
    for ((i = 1; i <= tries; i++)); do
        got=$(registry_digest "$1") || got="unreadable"
        [[ "${got}" != "$2" ]] || return 0
        ((i == tries)) || sleep "${READBACK_WAIT:-5}"
    done
    echo "::error::$1 is ${got}, expected $2 (after ${tries} reads)" >&2
    return 1
}

# podman's digestfile is the digest of the manifest it wrote; the registry must agree before anything is copied
settled "${first}" "${digest}" || exit 1

for tag in "$@"; do
    skopeo copy --all --preserve-digests "docker://${registry_image}@${digest}" "docker://${registry_image}:${tag}"
    settled "${tag}" "${digest}" || exit 1
done
echo "pushed ${first} $* -> ${digest}"
echo "digests=${digest}"
[[ -z "${GITHUB_OUTPUT:-}" ]] || echo "digests=${digest}" >> "${GITHUB_OUTPUT}"
