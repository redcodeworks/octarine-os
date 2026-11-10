#!/usr/bin/env bash
# The plan of the developer image workflow (build-dx.yml): decide, for one channel, whether to skip, promote or build,
# and print key=value lines to $GITHUB_OUTPUT. Run inside a checkout of the commit being built (history needed on main).
#
# Environment: CHANNEL (latest, beta or testing), FORCE (true builds anyway), GITHUB_REPOSITORY_OWNER, GITHUB_OUTPUT,
# GITHUB_STEP_SUMMARY (optional), MAX_WALK (default 60), BASE_NAME (default octarine-os), DX_NAME (default octarine-os-dx),
# PROMOTE_FROM_TESTING (default true; false skips the search for a tested testing image: the NVIDIA developer image has no
# testing channel). Tools: git, skopeo, cosign, jq.
# The NVIDIA developer image (build-nvidia-dx.yml) runs this with CHANNEL=latest BASE_NAME=octarine-os-nvidia
# DX_NAME=octarine-os-nvidia-dx PROMOTE_FROM_TESTING=false: it skips when the NVIDIA base digest and the dx inputs are unchanged.
#
# Base: octarine-os:<channel> for latest and beta, resolved to the digest of its raw manifest and verified with
# cosign.pub before anything is built on it. The testing channel does NOT use the floating `testing` tag: it takes the
# immutable tag of the commit being built, octarine-os:testing-<short sha> (the default build of that same push). When
# that tag does not exist (the default build was reused for a dx-only or docs-only change), it walks back like
# plan-vanilla-reuse.sh to the nearest earlier testing-<sha> built from the same default-image inputs; when there is
# none either, it falls back to the floating `testing` tag and prints a warning. Reason: the floating tag and the
# immutable tag of one build have been seen with different manifest digests, and a base digest recorded from the
# floating tag then never matched the promoted `latest` (push-tags.sh now keeps one digest per build; this keeps the
# plan independent of the floating tag anyway, and of a newer testing build landing while the dx build runs).
#
# The published octarine-os-dx:<channel> carries two labels: org.opencontainers.image.base.digest (the base it was built
# on) and io.github.redcodeworks.octarine-os.dx-inputs (inputs-hash.sh `dx` of the commit it was built from).
#   no force, both labels equal the current base digest and the current dx_inputs    -> skip   (build=false promote=false)
#   channel latest, a tested octarine-os-dx testing image with the same two labels   -> promote (retag, no build)
#   anything else (nothing published, unreadable, a label differs, force)            -> build
# After a vanilla promote, octarine-os:latest has the digest of the tested octarine-os:testing-<sha>, which is the base
# the dx testing image recorded: that equality is what makes the promote match.
# Candidates for the promotion: the `testing` tag, then `testing-<short sha>` of the newest MAX_WALK commits of HEAD
# (the testing commits are the second parents of the merges on main); each must carry both labels and a valid
# signature. `beta` never promotes (it has no testing image). Every lookup that fails means build, never skip.
set -euo pipefail
here=$(dirname "${BASH_SOURCE[0]}")
source "${here}/inputs-hash.sh"

channel="${CHANNEL:?CHANNEL}"
[[ "${channel}" =~ ^(latest|beta|testing)$ ]] || { echo "::error::Unknown channel '${channel}' (latest, beta or testing)"; exit 1; }
force="${FORCE:-false}"
: "${GITHUB_REPOSITORY_OWNER:?GITHUB_REPOSITORY_OWNER}"
owner="${GITHUB_REPOSITORY_OWNER,,}"
# The image names are parameters (octarine-os-nvidia-dx sets BASE_NAME=octarine-os-nvidia DX_NAME=octarine-os-nvidia-dx)
base="ghcr.io/${owner}/${BASE_NAME:-octarine-os}"
dx="ghcr.io/${owner}/${DX_NAME:-octarine-os-dx}"
base_tag="${channel}"
l_base="org.opencontainers.image.base.digest"
l_inputs="io.github.redcodeworks.octarine-os.dx-inputs"

tmp=$(mktemp)
trap 'rm -f "${tmp}"' EXIT

# The digest of the raw manifest of octarine-os:<tag>; fails when the tag cannot be read
base_digest_of() {
    skopeo inspect --raw "docker://${base}:$1" > "${tmp}" 2> /dev/null || return 1
    [[ -s "${tmp}" ]] || return 1
    echo "sha256:$(sha256sum "${tmp}" | sed 's/ .*//')"
}

if [[ "${channel}" == testing ]]; then
    # nearest_image_for_inputs (inputs-hash.sh) asks REGISTRY_LOOKUP for the digest of testing-<sha>
    REGISTRY_LOOKUP=base_digest_of
    mine="testing-$(git rev-parse --short=7 HEAD)"
    if base_digest_of "${mine}" > /dev/null; then
        base_tag="${mine}"
    elif found=$(nearest_image_for_inputs HEAD 2> /dev/null); then
        read -r base_tag _ <<< "${found}"
        echo "No ${base}:${mine} (the default build was reused): using the nearest earlier ${base_tag}, built from the same default-image inputs"
    else
        base_tag="testing"
        echo "::warning::No ${base}:${mine} and no earlier testing image with the same default-image inputs: falling back to the floating ${base}:testing"
    fi
fi
digest=$(base_digest_of "${base_tag}") || { echo "::error::Cannot read ${base}:${base_tag}"; exit 1; }
cosign verify --key cosign.pub "${base}@${digest}" > /dev/null
echo "Base image ${base}:${base_tag} = ${digest} (signature valid)"

inputs=$(dx_inputs HEAD)
echo "dx inputs of this commit: ${inputs}"

# labels of a published tag: prints "<base digest> <dx inputs>" (either may be empty) or fails
labels_of() {
    local cfg
    cfg=$(skopeo inspect --config "docker://${dx}:$1" 2> /dev/null) || return 1
    jq -r --arg a "${l_base}" --arg b "${l_inputs}" '[.config.Labels[$a] // "-", .config.Labels[$b] // "-"] | join(" ")' <<< "${cfg}"
}

build=true
promote=false
source_tag=""
source_digest=""
if cur=$(labels_of "${channel}"); then
    read -r cur_base cur_inputs <<< "${cur}"
else
    cur_base=""
    cur_inputs=""
    echo "No published ${dx}:${channel} yet (or it cannot be read)"
fi
decision=""
if [[ "${force}" == "true" ]]; then
    decision="forced: building although the published image is ${cur_base:-unknown}"
elif [[ -n "${cur_base}" && "${cur_base}" == "${digest}" && "${cur_inputs}" == "${inputs}" ]]; then
    build=false
    decision="skipped: base and dx inputs unchanged (${channel}: ${digest})"
else
    if [[ -n "${cur_base}" ]]; then
        [[ "${cur_base}" == "${digest}" ]] || echo "The published dx image was built from ${cur_base}, the base is now ${digest}"
        [[ "${cur_inputs}" == "${inputs}" ]] || echo "The dx inputs changed since the published dx image (${cur_inputs} -> ${inputs})"
    fi
    decision="building"
    if [[ "${channel}" == latest && "${PROMOTE_FROM_TESTING:-true}" == true ]]; then
        max=${MAX_WALK:-60}
        tags="testing"
        for c in $(git rev-list --max-count="${max}" HEAD); do tags+=" testing-$(git rev-parse --short=7 "${c}")"; done
        for t in ${tags}; do
            lab=$(labels_of "${t}") || continue
            read -r t_base t_inputs <<< "${lab}"
            [[ "${t_base}" == "${digest}" && "${t_inputs}" == "${inputs}" ]] || continue
            d=$(skopeo inspect --raw "docker://${dx}:${t}" | sha256sum | sed 's/ .*//')
            [[ -n "${d}" ]] || continue
            if cosign verify --key cosign.pub "${dx}@sha256:${d}" > /dev/null 2>&1; then
                build=false; promote=true; source_tag="${t}"; source_digest="sha256:${d}"
                decision="promoting ${t} (${source_digest}): same base digest and dx inputs, signed"
                break
            fi
            echo "::warning::${t} matches but its signature does not verify; not promoting it"
        done
        [[ "${promote}" == true ]] || decision="building (no tested testing image with this base digest and these dx inputs)"
    fi
fi
echo "dx ${channel}: ${decision}"
[[ -z "${GITHUB_STEP_SUMMARY:-}" ]] || echo "dx ${channel}: ${decision}" >> "${GITHUB_STEP_SUMMARY}"
if [[ "${build}" == false && "${promote}" == false ]]; then echo "::notice::base unchanged, nothing to build (${channel}: ${digest})"; fi
{
    echo "build=${build}"
    echo "promote=${promote}"
    echo "channel=${channel}"
    echo "base_tag=${base_tag}"
    echo "base_digest=${digest}"
    echo "dx_inputs=${inputs}"
    echo "source_tag=${source_tag}"
    echo "source_digest=${source_digest}"
} >> "${GITHUB_OUTPUT:?GITHUB_OUTPUT}"
