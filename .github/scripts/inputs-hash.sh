#!/usr/bin/env bash
# The two input hashes that decide which image has to be built (one place, tested by tests/test_plan.py).
#
#   inputs-hash.sh vanilla|dx [<rev>]     print the hash of <rev> (default HEAD)
#
# Sourced, it provides is_dx_only, vanilla_inputs <rev>, dx_inputs <rev> and nearest_image_for_inputs.
#
#   dx_inputs       hash of the committed files that only the developer image uses (is_dx_only)
#   vanilla_inputs  hash of every other committed file, docs-only files (docs-only.sh) left out too
#
# Both hash the sorted `git ls-tree -r` entries (mode, blob id, path) that pass the filter, so they are stable and
# do not depend on commit ids, dates or the order of anything. A change that touches only dx files leaves
# vanilla_inputs equal; a change that touches only the default image leaves dx_inputs equal.
set -euo pipefail
# shellcheck source=docs-only.sh
source "$(dirname "${BASH_SOURCE[0]}")/docs-only.sh"

# The dx-only paths: the variant directory, the dx workflow (and the NVIDIA dx one, which builds the same layer) and its scripts, the key the
# dev-packages pin is verified with. The tests are no input of either image (docs-only.sh lists tests/** with the docs). Everything else (Containerfile, build_files, system_files, Justfile, the other
# workflows and scripts) belongs to the default image: a change there rebuilds it, and then dx follows its new digest.
is_dx_only() {
    case "$1" in
        variants/dx/* | .github/workflows/build-dx.yml | .github/scripts/dx-smoke.sh | .github/scripts/plan-dx.sh) return 0 ;;
        .github/scripts/aggregate-dx.sh | keys/redcodeworks-toolbox-cosign.pub) return 0 ;;
        .github/workflows/build-nvidia-dx.yml) return 0 ;;
        *) return 1 ;;
    esac
}

# <kind> <rev>: print the hash
_inputs() {
    local kind=$1 rev=${2:-HEAD} meta path
    git rev-parse --verify --quiet "${rev}^{tree}" > /dev/null || { echo "inputs-hash: unknown revision '${rev}'" >&2; return 1; }
    {
        while IFS=$'\t' read -r meta path; do
            if is_dx_only "${path}"; then
                [[ "${kind}" == dx ]] || continue
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

# <tip>: walk the first-parent history back from <tip> (itself included) and find the nearest commit that has a
# published image `testing-<short sha>` (lookup: `$REGISTRY_LOOKUP <tag>` prints the digest or fails). The walk
# stops, without a match, at the first commit whose vanilla_inputs differ from <tip>'s (a default-image change lies
# between). Prints `<tag> <digest>` and returns 0, or prints the reason on stderr and returns 1.
nearest_image_for_inputs() {
    local tip=$1 want c n=0 sha digest
    local max=${MAX_WALK:-50}
    want=$(vanilla_inputs "${tip}")
    for c in $(git rev-list --first-parent "${tip}"); do
        ((n++ > max)) && { echo "no image within ${max} commits" >&2; return 1; }
        if [[ "$(vanilla_inputs "${c}")" != "${want}" ]]; then
            echo "a default-image change lies between ${tip} and the nearest commit with an image" >&2
            return 1
        fi
        for sha in "$(git rev-parse --short "${c}")" "$(git rev-parse --short=7 "${c}")"; do
            if digest=$("${REGISTRY_LOOKUP:?REGISTRY_LOOKUP}" "testing-${sha}" 2> /dev/null) && [[ -n "${digest}" ]]; then
                echo "testing-${sha} ${digest}"
                return 0
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
        *) echo "usage: inputs-hash.sh vanilla|dx [rev]" >&2; exit 2 ;;
    esac
fi
