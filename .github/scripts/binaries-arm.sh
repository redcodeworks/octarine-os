#!/usr/bin/env bash
# Arms the fallback of the prebuilt binaries: points `last-good-<component>` at the signed c-<component>-<key> image of the CURRENT tree for every component
# of binaries/components.tsv. The tags used to move only in the `track` job of binaries.yml, which runs when a main run builds; a promotion (the usual main
# run: the tested image is retagged, build=false) never calls binaries.yml, so on 2026-11-15 no last-good tag existed and the daily's fallback was unarmed.
# build.yml's promote job calls this script, so every promotion to main arms or refreshes the tags without a hand step.
#
#   binaries-arm.sh <registry image>        env: COSIGN_KEY_FILE (tests); run from the repository root on the promoted commit
#
# Per component: binaries-lookup.sh decides whether c-<component>-<key> is published AND verifies with cosign.pub (the same verification the build uses);
# only then the tag is copied (skopeo copy --all --preserve-digests) and read back (the sha256 of the raw manifest must be the digest). A component whose
# image is missing or unsigned (an optional one that was left out, or a tree that was never built) is skipped with a warning and keeps its old tag. Always
# exits 0 (it must never fail a promotion); the summary lines say what moved.
set -uo pipefail
image=${1:?registry image}
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
note() { echo "$*"; [[ -z "${GITHUB_STEP_SUMMARY:-}" ]] || echo "- $*" >> "${GITHUB_STEP_SUMMARY}" || true; }
for c in $("${here}/binaries-key.sh" --components); do
    key=$("${here}/binaries-key.sh" "${c}") || { echo "::warning::no key for ${c}"; continue; }
    res=$(GITHUB_OUTPUT="" "${here}/binaries-lookup.sh" "${image}" "c-${c}-${key}" 2> /dev/null) || res=""
    usable=$(sed -n 's/^usable=//p' <<<"${res}" | tail -n1); digest=$(sed -n 's/^digest=//p' <<<"${res}" | tail -n1)
    if [[ "${usable}" != true || ! "${digest}" =~ ^sha256:[0-9a-f]{64}$ ]]; then
        echo "::warning::last-good-${c} not moved: c-${c}-${key} is not published and signed ($(sed -n 's/^reason=//p' <<<"${res}" | tail -n1))"
        continue
    fi
    cur=$(skopeo inspect --raw "docker://${image}:last-good-${c}" 2> /dev/null | sha256sum | sed 's/ .*//') || cur=""
    if [[ "sha256:${cur}" == "${digest}" ]]; then note "last-good-${c} already is ${digest:0:19}"; continue; fi
    if skopeo copy --all --preserve-digests "docker://${image}@${digest}" "docker://${image}:last-good-${c}" > /dev/null 2>&1; then
        got="sha256:$(skopeo inspect --raw "docker://${image}:last-good-${c}" 2> /dev/null | sha256sum | sed 's/ .*//')"
        if [[ "${got}" == "${digest}" ]]; then note "last-good-${c} -> ${digest:0:19} (c-${c}-${key})"; else echo "::warning::last-good-${c} reads ${got}, expected ${digest}"; fi
    else
        echo "::warning::could not copy c-${c}-${key} to last-good-${c}"
    fi
done
exit 0
