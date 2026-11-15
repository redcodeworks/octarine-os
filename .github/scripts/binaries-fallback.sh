#!/usr/bin/env bash
# The last good image of ONE component, as a fallback for a build of that component that failed. Fails (exit 1) unless the candidate is
# signed, complete and installable; it never decides WHEN a fallback is allowed (binaries-component.yml does).
#
#   binaries-fallback.sh <registry image> <last-good tag> <component> <schedulers.tsv of this tree> <install-binaries.sh of this tree>
#
# 1. the tag (last-good-<component>) resolves to a manifest digest (`skopeo inspect --raw`, sha256 of it: the way every pin here is made),
# 2. cosign verifies that digest against cosign.pub (COSIGN_KEY_FILE overrides): a candidate whose signature does not verify is NEVER used,
# 3. the layout contract of THIS tree for this component: the image is exported, every file binaries-layout.sh requires is there, and the
#    real installer (this tree's install-binaries.sh with BINARIES_ONLY=<component>, BINARIES_ROOT and DESTDIR in a scratch directory)
#    accepts it: an older image that lacks something the installer now requires is refused,
# 4. its labels carry the content key it was built from (org.octarineos.binaries-component-key, 40 hex), which the assembled key needs.
# Output (GITHUB_OUTPUT when set, and stdout): digest, key, created, tag. A refusal prints ::error:: (::warning:: when
# FALLBACK_REFUSAL_LEVEL=warning, for an optional component that simply has no last good image yet) and exits 1.
set -euo pipefail
image=${1:?registry image}
tag=${2:?last-good tag}
comp=${3:?component}
tsv=${4:?schedulers.tsv}
installer=${5:?install-binaries.sh}
key=${COSIGN_KEY_FILE:-cosign.pub}
level=${FALLBACK_REFUSAL_LEVEL:-error}
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
out() { [[ -z "${GITHUB_OUTPUT:-}" ]] || echo "$1=$2" >> "${GITHUB_OUTPUT}"; echo "$1=$2"; }
die() { echo "::${level}::binaries fallback for ${comp} refused: $*" >&2; exit 1; }

manifest=$(skopeo inspect --raw "docker://${image}:${tag}" 2> /dev/null) || manifest=""
[[ -n "${manifest}" ]] || die "${image}:${tag} does not exist (no last good ${comp} image yet)"
digest="sha256:$(printf '%s' "${manifest}" | sha256sum | sed 's/ .*//')"
cosign verify --key "${key}" "${image}@${digest}" > /dev/null 2>&1 || die "the signature of ${image}@${digest} (${tag}) does not verify"

work=$(mktemp -d)
trap 'rm -rf "${work}"' EXIT
id=$(podman create "${image}@${digest}" /nonexistent)
mkdir -p "${work}/root"
podman export "${id}" | tar -x -C "${work}/root"
podman rm "${id}" > /dev/null
(cd "${work}/root" && find . \( -type f -o -type l \) | sort) > "${work}/listing.txt"
"${here}/binaries-layout.sh" "${work}/listing.txt" "${tsv}" "${comp}" || die "${tag} (${digest}) lacks files this tree's installer requires (see above)"
BINARIES_ONLY="${comp}" BINARIES_ROOT="${work}/root" DESTDIR="${work}/dest" "${installer}" > "${work}/install.log" 2>&1 \
    || { cat "${work}/install.log" >&2; die "this tree's install-binaries.sh does not accept ${tag} (${digest})"; }

labels=$(skopeo inspect --config "docker://${image}@${digest}" 2> /dev/null | jq -r '.config.Labels // {} | [(.["org.octarineos.binaries-component-key"] // ""), (.["org.opencontainers.image.created"] // "")] | @tsv') || labels=""
ckey=$(cut -f1 <<<"${labels}")
created=$(cut -f2 <<<"${labels}")
[[ "${ckey}" =~ ^[0-9a-f]{40}$ ]] || die "${tag} (${digest}) has no readable content key label (org.octarineos.binaries-component-key)"
out digest "${digest}"
out key "${ckey}"
out created "${created:-unknown}"
out tag "${tag}"
