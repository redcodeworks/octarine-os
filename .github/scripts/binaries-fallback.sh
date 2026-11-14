#!/usr/bin/env bash
# The last good binaries image, as a fallback for a scheduled build whose binaries build failed. Fails (exit 1) unless the candidate
# is signed, complete and installable; it never decides WHEN a fallback is allowed (binaries.yml does).
#
#   binaries-fallback.sh <registry image> <last-good tag> <schedulers.tsv of this tree> <install-binaries.sh of this tree>
#
# 1. the tag resolves to a manifest digest (`skopeo inspect --raw`, sha256 of it: the way every pin here is made),
# 2. cosign verifies that digest against cosign.pub (COSIGN_KEY_FILE overrides): a candidate whose signature does not verify is NEVER
#    used, the workflow does not fall back to anything else,
# 3. the layout contract of THIS tree: the image is exported, every file binaries-layout.sh requires is there (every scheduler of
#    this tree's schedulers.tsv, both extest libraries, SOURCE, BUILDINFO, LICENSES per component), and the real installer
#    (this tree's install-binaries.sh, BINARIES_ROOT and DESTDIR in a scratch directory) accepts it: an older image that lacks a
#    component the installer now requires is refused, so the image build never ships without it.
# Output (GITHUB_OUTPUT when set, and stdout): digest, hash (the tree hash of binaries/ the candidate was built from, from its version
# label), created (its created label), tag. A hard failure prints ::error:: and exits 1.
set -euo pipefail
image=${1:?registry image}
tag=${2:?last-good tag}
tsv=${3:?schedulers.tsv}
installer=${4:?install-binaries.sh}
key=${COSIGN_KEY_FILE:-cosign.pub}
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
out() { [[ -z "${GITHUB_OUTPUT:-}" ]] || echo "$1=$2" >> "${GITHUB_OUTPUT}"; echo "$1=$2"; }
die() { echo "::error::binaries fallback refused: $*" >&2; exit 1; }

manifest=$(skopeo inspect --raw "docker://${image}:${tag}" 2> /dev/null) || manifest=""
[[ -n "${manifest}" ]] || die "${image}:${tag} does not exist (no last good binaries image yet)"
digest="sha256:$(printf '%s' "${manifest}" | sha256sum | sed 's/ .*//')"
cosign verify --key "${key}" "${image}@${digest}" > /dev/null 2>&1 || die "the signature of ${image}@${digest} (${tag}) does not verify"

work=$(mktemp -d)
trap 'rm -rf "${work}"' EXIT
id=$(podman create "${image}@${digest}" /nonexistent)
mkdir -p "${work}/root"
podman export "${id}" | tar -x -C "${work}/root"
podman rm "${id}" > /dev/null
(cd "${work}/root" && find . \( -type f -o -type l \) | sort) > "${work}/listing.txt"
"${here}/binaries-layout.sh" "${work}/listing.txt" "${tsv}" || die "${tag} (${digest}) lacks files this tree's installer requires (see above)"
BINARIES_ROOT="${work}/root" DESTDIR="${work}/dest" "${installer}" > "${work}/install.log" 2>&1 \
    || { cat "${work}/install.log" >&2; die "this tree's install-binaries.sh does not accept ${tag} (${digest})"; }

labels=$(skopeo inspect --config "docker://${image}@${digest}" 2> /dev/null | jq -r '.config.Labels // {} | [(.["org.opencontainers.image.version"] // ""), (.["org.opencontainers.image.created"] // "")] | @tsv') || labels=""
hash=$(cut -f1 <<<"${labels}")
created=$(cut -f2 <<<"${labels}")
[[ "${hash}" =~ ^[0-9a-f]{40}$ ]] || hash="unknown"
out digest "${digest}"
out hash "${hash}"
out created "${created:-unknown}"
out tag "${tag}"
