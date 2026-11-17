#!/usr/bin/env bash
# The plan of the variant image workflows (build-variant.yml for dx and gx, build-extra.yml for dx-gx, nvidia-dx and nvidia-gx, both through the reusable dx-image.yml): decide, for one channel, whether to
# skip, promote or build, and print key=value lines to $GITHUB_OUTPUT. Run inside a checkout of the commit being built (history needed on main).
#
# Environment: CHANNEL (latest or testing), FORCE (true builds anyway), GITHUB_REPOSITORY_OWNER, GITHUB_OUTPUT,
# VARIANT (dx, the default, or gx: which inputs hash and which label are compared; the variant's own files are in inputs-hash.sh),
# GITHUB_STEP_SUMMARY (optional), MAX_WALK (default 60), BASE_NAME (default octarine-os), DX_NAME (the image built: default octarine-os-<VARIANT>),
# BASE_DIGEST_PIN (channel latest only: the default image's digest this run is built on, handed over by the pipeline; without it the
# base is whatever `octarine-os:latest` is now, which is the digest of the published pair),
# PROMOTE_FROM_TESTING (default true; false skips the search for a tested testing image: the NVIDIA developer image has no
# testing channel). Tools: git, skopeo, cosign, jq.
# The NVIDIA developer image (build-extra.yml, variant nvidia-dx) runs this with CHANNEL=latest BASE_NAME=octarine-os-nvidia
# DX_NAME=octarine-os-nvidia-dx PROMOTE_FROM_TESTING=false: it skips when the NVIDIA base digest and the dx inputs are unchanged.
#
# Base: octarine-os:latest for the latest channel, resolved to the digest of its raw manifest and verified with
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
# on) and io.github.redcodeworks.octarine-os.dx-inputs (inputs-hash.sh `dx` of the commit it was built from); the gx image carries
# gx-inputs (inputs-hash.sh `gx`). Everything below says dx and means the variant.
#   no force, both labels equal the current base digest and the current variant inputs -> skip   (build=false promote=false)
#   channel latest, a tested octarine-os-dx testing image with the same two labels   -> promote (retag, no build)
#   anything else (nothing published, unreadable, a label differs, force)            -> build
# After a vanilla promote, octarine-os:latest has the digest of the tested octarine-os:testing-<sha>, which is the base
# the dx testing image recorded: that equality is what makes the promote match.
# Candidates for the promotion: the `testing` tag, then `testing-<short sha>` of the newest MAX_WALK commits of HEAD
# (the testing commits are the second parents of the merges on main); each must carry both labels and a valid
# signature. Every lookup that fails means build, never skip.
set -euo pipefail
here=$(dirname "${BASH_SOURCE[0]}")
source "${here}/inputs-hash.sh"

channel="${CHANNEL:?CHANNEL}"
[[ "${channel}" =~ ^(latest|testing)$ ]] || { echo "::error::Unknown channel '${channel}' (latest or testing)"; exit 1; }
force="${FORCE:-false}"
: "${GITHUB_REPOSITORY_OWNER:?GITHUB_REPOSITORY_OWNER}"
owner="${GITHUB_REPOSITORY_OWNER,,}"
variant="${VARIANT:-dx}"
[[ "${variant}" =~ ^(dx|gx)$ ]] || { echo "::error::Unknown variant '${variant}' (dx or gx)"; exit 1; }
# The image names are parameters (octarine-os-nvidia-dx sets BASE_NAME=octarine-os-nvidia DX_NAME=octarine-os-nvidia-dx)
base="ghcr.io/${owner}/${BASE_NAME:-octarine-os}"
dx="ghcr.io/${owner}/${DX_NAME:-octarine-os-${variant}}"
base_tag="${channel}"
l_base="org.opencontainers.image.base.digest"
l_inputs="io.github.redcodeworks.octarine-os.${variant}-inputs"

tmp=$(mktemp)
trap 'rm -f "${tmp}"' EXIT

# Registry reads follow ONE contract (registry-read.sh): exit 3 = the tag does not exist, exit 4 = the registry could not be read (retried). An unreadable registry is an
# ERROR here wherever a "missing" answer would send the plan down another path (a different base, a rebuild instead of a promotion); it never means "absent".
rr="${here}/registry-read.sh"
# The digest of the raw manifest of <image ref>; exit 3 absent, 4 unreadable
raw_digest_of() {
    local rc=0
    "${rr}" raw "$1" > "${tmp}" || rc=$?
    [[ "${rc}" == 0 ]] || return "${rc}"
    echo "sha256:$(sha256sum "${tmp}" | sed 's/ .*//')"
}
base_digest_of() { raw_digest_of "${base}:$1"; }
# cosign verify with the verdict told apart: 0 verified, 5 not verified, 4 could not be completed (retried)
verify() { "${here}/cosign-check.sh" --key cosign.pub "$1"; }

if [[ "${channel}" == testing ]]; then
    # nearest_image_for_inputs (inputs-hash.sh) asks REGISTRY_LOOKUP for the digest of testing-<sha>
    REGISTRY_LOOKUP=base_digest_of
    mine="testing-$(git rev-parse --short=7 HEAD)"
    rc=0; base_digest_of "${mine}" > /dev/null || rc=$?
    if [[ "${rc}" == 0 ]]; then
        base_tag="${mine}"
    elif [[ "${rc}" != 3 ]]; then
        echo "::error::Could not read ${base}:${mine} (a registry read error, not a missing tag): not falling back to another base"; exit 1
    else
        rc=0; found=$(nearest_image_for_inputs HEAD 2> /dev/null) || rc=$?
        if [[ "${rc}" == 0 ]]; then
            read -r base_tag _ <<< "${found}"
            echo "No ${base}:${mine} (the default build was reused): using the nearest earlier ${base_tag}, built from the same default-image inputs"
        elif [[ "${rc}" == 2 ]]; then
            echo "::error::Could not read the registry while looking for an earlier testing image (a read error, not a missing image): not falling back to the floating tag"; exit 1
        else
            base_tag="testing"
            echo "::warning::No ${base}:${mine} and no earlier testing image with the same default-image inputs: falling back to the floating ${base}:testing"
        fi
    fi
fi
pin="${BASE_DIGEST_PIN:-}"
if [[ -n "${pin}" ]]; then
    # The default image this run is meant for, handed over by the pipeline that just published it (channel latest on main). `latest`
    # is not moved before dx has passed, so it is NOT the base here: the base is exactly this digest, which must exist as the image
    # of the default repository and hash to itself. The signature is verified below like any other base.
    [[ "${channel}" == latest ]] || { echo "::error::BASE_DIGEST_PIN is only for the channel latest (got ${channel})"; exit 1; }
    [[ "${pin}" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "::error::BASE_DIGEST_PIN '${pin}' is not sha256:<64 hex>"; exit 1; }
    "${rr}" raw "${base}@${pin}" > "${tmp}" || { echo "::error::Cannot read ${base}@${pin}"; exit 1; }
    [[ "sha256:$(sha256sum "${tmp}" | sed 's/ .*//')" == "${pin}" ]] || { echo "::error::${base}@${pin} does not hash to its digest"; exit 1; }
    digest="${pin}"
    base_tag="latest"
    echo "Base pinned by the pipeline: ${base}@${digest}"
else
    digest=$(base_digest_of "${base_tag}") || { echo "::error::Cannot read ${base}:${base_tag}"; exit 1; }
fi
verify "${base}@${digest}" || { echo "::error::The base ${base}@${digest} did not verify (or could not be checked: see the message above): nothing is built on it"; exit 1; }
echo "Base image ${base}:${base_tag} = ${digest} (signature valid)"

inputs=$("${variant}_inputs" HEAD)
echo "${variant} inputs of this commit: ${inputs}"

# labels of a published tag: prints "<base digest> <dx inputs>" (either may be empty) or fails
labels_of() {
    local cfg rc=0
    cfg=$("${rr}" config "${dx}:$1") || rc=$?
    [[ "${rc}" == 0 ]] || return "${rc}"
    jq -r --arg a "${l_base}" --arg b "${l_inputs}" '[.config.Labels[$a] // "-", .config.Labels[$b] // "-"] | join(" ")' <<< "${cfg}"
}

build=true
promote=false
source_tag=""
source_digest=""
rc=0; cur=$(labels_of "${channel}") || rc=$?
if [[ "${rc}" == 0 ]]; then
    read -r cur_base cur_inputs <<< "${cur}"
else
    # absent (3) or unreadable (4): both mean "build, never skip" for the PUBLISHED image of this channel (a skip needs a positive read)
    cur_base=""
    cur_inputs=""
    if [[ "${rc}" == 3 ]]; then echo "No published ${dx}:${channel} yet"; else echo "::warning::${dx}:${channel} could not be read (a read error): building, never skipping on a failed read"; fi
fi
decision=""
if [[ "${force}" == "true" ]]; then
    decision="forced: building although the published image is ${cur_base:-unknown}"
elif [[ -n "${cur_base}" && "${cur_base}" == "${digest}" && "${cur_inputs}" == "${inputs}" ]]; then
    # No signature check here: the moving tags (`testing`, and `latest` by Publish latest) are moved only AFTER their digest is signed and verified, so a
    # published tag is always a signed image (a run cancelled earlier leaves the previous one in place)
    build=false
    decision="skipped: base and ${variant} inputs unchanged (${channel}: ${digest})"
else
    if [[ -n "${cur_base}" ]]; then
        [[ "${cur_base}" == "${digest}" ]] || echo "The published ${variant} image was built from ${cur_base}, the base is now ${digest}"
        [[ "${cur_inputs}" == "${inputs}" ]] || echo "The ${variant} inputs changed since the published ${variant} image (${cur_inputs} -> ${inputs})"
    fi
    decision="building"
    if [[ "${channel}" == latest && "${PROMOTE_FROM_TESTING:-true}" == true ]]; then
        max=${MAX_WALK:-60}
        tags="testing"
        for c in $(git rev-list --max-count="${max}" HEAD); do tags+=" testing-$(git rev-parse --short=7 "${c}")"; done
        for t in ${tags}; do
            rc=0; lab=$(labels_of "${t}") || rc=$?
            if [[ "${rc}" == 3 ]]; then continue; fi   # no such candidate tag
            [[ "${rc}" == 0 ]] || { echo "::error::Could not read the labels of ${dx}:${t} (a registry read error, not a missing tag): not building instead of promoting"; exit 1; }
            read -r t_base t_inputs <<< "${lab}"
            [[ "${t_base}" == "${digest}" && "${t_inputs}" == "${inputs}" ]] || continue
            rc=0; d=$(raw_digest_of "${dx}:${t}") || rc=$?
            [[ "${rc}" == 0 ]] || { echo "::error::Could not read the manifest of ${dx}:${t} (exit ${rc}): not building instead of promoting"; exit 1; }
            rc=0; verify "${dx}@${d}" 2> /dev/null || rc=$?
            if [[ "${rc}" == 0 ]]; then
                build=false; promote=true; source_tag="${t}"; source_digest="${d}"
                decision="promoting ${t} (${source_digest}): same base digest and ${variant} inputs, signed"
                break
            fi
            [[ "${rc}" == 5 ]] || { echo "::error::Could not complete the signature check of ${dx}:${t} (a read error, not a bad signature): not building instead of promoting"; exit 1; }
            echo "::warning::${t} matches but its signature does not verify; not promoting it"
        done
        [[ "${promote}" == true ]] || decision="building (no tested testing image with this base digest and these ${variant} inputs)"
    fi
fi
echo "${variant} ${channel}: ${decision}"
[[ -z "${GITHUB_STEP_SUMMARY:-}" ]] || echo "${variant} ${channel}: ${decision}" >> "${GITHUB_STEP_SUMMARY}"
if [[ "${build}" == false && "${promote}" == false ]]; then echo "::notice::base unchanged, nothing to build (${channel}: ${digest})"; fi
{
    echo "build=${build}"
    echo "promote=${promote}"
    echo "channel=${channel}"
    echo "base_tag=${base_tag}"
    echo "base_digest=${digest}"
    echo "inputs=${inputs}"
    echo "source_tag=${source_tag}"
    echo "source_digest=${source_digest}"
} >> "${GITHUB_OUTPUT:?GITHUB_OUTPUT}"
