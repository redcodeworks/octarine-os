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
# After every copy the digest of the tag is read back from the registry and must equal the pushed one.
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

# podman's digestfile is the digest of the manifest it wrote; the registry must agree before anything is copied
got=$(registry_digest "${first}")
[[ "${got}" == "${digest}" ]] || { echo "::error::${first} is ${got} in the registry, podman pushed ${digest}" >&2; exit 1; }

for tag in "$@"; do
    skopeo copy --all --preserve-digests "docker://${registry_image}@${digest}" "docker://${registry_image}:${tag}"
    got=$(registry_digest "${tag}")
    [[ "${got}" == "${digest}" ]] || { echo "::error::${tag} is ${got}, expected ${digest}" >&2; exit 1; }
done
echo "pushed ${first} $* -> ${digest}"
echo "digests=${digest}"
[[ -z "${GITHUB_OUTPUT:-}" ]] || echo "digests=${digest}" >> "${GITHUB_OUTPUT}"
