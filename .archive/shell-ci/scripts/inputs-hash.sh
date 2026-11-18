#!/usr/bin/env bash
# The three input hashes that decide which image has to be built (one place, tested by tests/pipeline/inputs-hash.sh).
#
#   inputs-hash.sh vanilla|dx|gx [<rev>]     print the hash of <rev> (default HEAD)
#
# Sourced, it provides is_dx_only, is_gx_only, is_variant_shared, is_pipeline_only, vanilla_inputs <rev>, dx_inputs <rev>, gx_inputs <rev> and nearest_image_for_inputs.
#
#   dx_inputs       hash of the committed files that only the developer image uses (is_dx_only) plus the ones both variants share (is_variant_shared)
#   gx_inputs       hash of the committed files that only the gamer image uses (is_gx_only) plus the ones both variants share (is_variant_shared)
#   vanilla_inputs  hash of every other committed file (neither dx-only, gx-only nor shared), docs-only files (docs-only.sh) left out too
#
# All hash the sorted `git ls-tree -r` entries (mode, blob id, path) that pass the filter, so they are stable and
# do not depend on commit ids, dates or the order of anything. A change that touches only dx files leaves
# vanilla_inputs and gx_inputs equal; a change that touches only the default image leaves dx_inputs and gx_inputs equal; a change to a shared file (the reusable
# workflow, the plan script, the toolbox key) moves both variant hashes and not vanilla_inputs.
set -euo pipefail
# shellcheck source=docs-only.sh
source "$(dirname "${BASH_SOURCE[0]}")/docs-only.sh"

# The paths of ONE variant: the dx directory, its package lists (packages/dx) and its smoke test; the gx directory, its package lists (packages/gx) and its smoke test (the workflow files are shared since 2026-11-17, see below). The tests are no input of any image (docs-only.sh lists tests/** with the docs). Everything else (Containerfile, build_files, system_files, packages/default, Justfile, the other
# workflows and scripts) belongs to the default image: a change there rebuilds it, and then the variants follow its new digest.
is_dx_only() {
    case "$1" in
        variants/dx/* | packages/dx/* | .github/scripts/dx-smoke.sh) return 0 ;;
        *) return 1 ;;
    esac
}
is_gx_only() {
    case "$1" in
        variants/gx/* | packages/gx/* | .github/scripts/gx-smoke.sh) return 0 ;;
        *) return 1 ;;
    esac
}
# The paths BOTH variants are built with: the reusable workflow (dx-image.yml, parameterized by the variant), the one caller of the two required variants (build-variant.yml, added 2026-11-17: editing it rebuilds dx AND gx), its plan and result scripts, the key the list-image pins are verified
# with. They count in dx_inputs and in gx_inputs, never in vanilla_inputs.
is_variant_shared() {
    case "$1" in
        .github/workflows/dx-image.yml | .github/workflows/build-variant.yml | .github/scripts/plan-dx.sh | .github/scripts/aggregate-dx.sh | keys/redcodeworks-toolbox-cosign.pub) return 0 ;;
        *) return 1 ;;
    esac
}

# The pipeline-only paths: files that run in CI but are not read by any image build, so changing one rebuilds neither image: the publication of `latest`
# and the rollback, the variant dispatch, the failure issue, the bump automation, the daily prune, the required-branch and test workflows, the audit and secret-scan
# config, the git hooks, and the NVIDIA variant and the extra variants (built by their own dispatch-only workflows from a published image). (build.yml, build-variant.yml and the scripts they call still count: they contain the builds.) The prebuilt binaries are no special case any more
# (2026-11-16): the digest pin of octarine-bins in the Containerfile is an ordinary image input, so a bump rebuilds the image on testing.
is_pipeline_only() {
    case "$1" in
        .github/scripts/dispatch_variant.py | .github/scripts/publish_latest.py | .github/scripts/ci_issue.py | .github/scripts/sanity.sh | .github/scripts/prune-daily.py) return 0 ;;
        .github/scripts/bump-*.sh) return 0 ;;
        .github/workflows/publish-latest.yml | .github/workflows/rollback-latest.yml | .github/workflows/bump-pins.yml | .github/workflows/prune-daily.yml) return 0 ;;
        .github/workflows/require-testing-branch.yml | .github/workflows/test.yml) return 0 ;;
        .github/workflows/build-nvidia.yml | .github/workflows/build-extra.yml | .github/scripts/nvidia-smoke.sh | .github/scripts/nvidia_akmods_ref.py | variants/nvidia/*) return 0 ;;
        .github/zizmor.yml | .github/dependabot.yml | .gitleaks.toml | githooks/*) return 0 ;;
        *) return 1 ;;
    esac
}

# <kind> <rev>: print the hash
_inputs() {
    local kind=$1 rev=${2:-HEAD} meta path
    git rev-parse --verify --quiet "${rev}^{tree}" > /dev/null || { echo "inputs-hash: unknown revision '${rev}'" >&2; return 1; }
    {
        while IFS=$'\t' read -r meta path; do
            ! is_pipeline_only "${path}" || continue
            if is_variant_shared "${path}"; then
                [[ "${kind}" == dx || "${kind}" == gx ]] || continue
            elif is_dx_only "${path}"; then
                [[ "${kind}" == dx ]] || continue
            elif is_gx_only "${path}"; then
                [[ "${kind}" == gx ]] || continue
            else
                [[ "${kind}" == vanilla ]] || continue
                ! is_docs "${path}" || continue
            fi
            printf '%s\t%s\n' "${meta}" "${path}"
        done < <(git ls-tree -r --full-tree "${rev}")
    } | LC_ALL=C sort | sha256sum | sed 's/ .*//'
}
vanilla_inputs() { _inputs vanilla "$@"; }
dx_inputs() { _inputs dx "$@"; }
gx_inputs() { _inputs gx "$@"; }

# <tip>: walk the first-parent history back from <tip> (itself included) and find the nearest commit that has a
# published image `testing-<short sha>` (lookup: `$REGISTRY_LOOKUP <tag>` prints the digest or fails). The walk
# stops, without a match, at the first commit whose vanilla_inputs differ from <tip>'s (a default-image change lies
# between). Prints `<tag> <digest>` and returns 0, or prints the reason on stderr and returns 1.
nearest_image_for_inputs() {
    local tip=$1 want c n=0 sha digest rc
    local max=${MAX_WALK:-50}
    want=$(vanilla_inputs "${tip}")
    for c in $(git rev-list --first-parent "${tip}"); do
        ((n++ > max)) && { echo "no image within ${max} commits" >&2; return 1; }
        if [[ "$(vanilla_inputs "${c}")" != "${want}" ]]; then
            echo "a default-image change lies between ${tip} and the nearest commit with an image" >&2
            return 1
        fi
        for sha in "$(git rev-parse --short "${c}")" "$(git rev-parse --short=7 "${c}")"; do
            rc=0
            digest=$("${REGISTRY_LOOKUP:?REGISTRY_LOOKUP}" "testing-${sha}" 2> /dev/null) || rc=$?
            if [[ "${rc}" == 0 && -n "${digest}" ]]; then
                echo "testing-${sha} ${digest}"
                return 0
            fi
            # the lookup contract: 3 = the tag does not exist (keep walking), anything else = the registry could not be read: that is an ERROR (return 2), never "no image"
            if [[ "${rc}" != 0 && "${rc}" != 3 ]]; then
                echo "could not read the registry while looking for testing-${sha} (lookup exit ${rc}): not treating that as a missing image" >&2
                return 2
            fi
        done
    done
    echo "no testing image found" >&2
    return 1
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-}" in
        vanilla) vanilla_inputs "${2:-HEAD}" ;;
        dx) dx_inputs "${2:-HEAD}" ;;
        gx) gx_inputs "${2:-HEAD}" ;;
        *) echo "usage: inputs-hash.sh vanilla|dx|gx [rev]" >&2; exit 2 ;;
    esac
fi
