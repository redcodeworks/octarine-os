#!/usr/bin/env bash
# Content keys of the prebuilt binaries (content-addressed, so the same content is built once and reused by testing, main
# and the daily rebuild).
#
#   binaries-key.sh <component>          key of one component: 40 hex, sha1 of "<tree of binaries/<c>> <tree of binaries/lib> <blob of
#                                        binaries/builder.env>". A change inside the component, in lib/ or in the builder pin changes it; a
#                                        change inside ANOTHER component does not.
#   binaries-key.sh --assembled name=key...   key of an assembled image: 40 hex, sha1 of the sorted lines "<name> <key>"
#   binaries-key.sh                      assembled key of the whole tree (every component of binaries/components.tsv built from it): the
#                                        tag a local `just build` expects and the tag CI publishes when nothing fell back
#   binaries-key.sh --components         the component names of binaries/components.tsv, one per line
# Run from the repository root (or set REPO_ROOT); reads HEAD of the git checkout.
set -euo pipefail
root=${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}
cd "${root}"
names() { grep -vE '^[[:space:]]*(#|$)' binaries/components.tsv | cut -f1; }
component_key() {
    local c=$1
    [[ "${c}" =~ ^[a-z0-9]+$ ]] || { echo "binaries-key.sh: bad component name '${c}'" >&2; exit 1; }
    printf '%s %s %s\n' "$(git rev-parse "HEAD:binaries/${c}")" "$(git rev-parse HEAD:binaries/lib)" "$(git rev-parse HEAD:binaries/builder.env)" | sha1sum | cut -c1-40
}
assembled_key() { printf '%s\n' "${@/=/ }" | LC_ALL=C sort | sha1sum | cut -c1-40; }
case "${1:-}" in
    --components) names ;;
    --assembled) shift; [[ $# -gt 0 ]] || { echo "binaries-key.sh: --assembled needs name=key pairs" >&2; exit 1; }; assembled_key "$@" ;;
    "") pairs=(); for c in $(names); do pairs+=("${c}=$(component_key "${c}")"); done; assembled_key "${pairs[@]}" ;;
    *) component_key "$1" ;;
esac
