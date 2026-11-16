#!/usr/bin/env bash
# Sourced by the binaries tests: write the COMPONENTS file of an assembled image with the REAL writers (binaries-decide.sh makes each component's result line,
# binaries-assemble.sh writes the file), so the tests never carry a hand-written copy of the file format.
#   write_components <dir> <component>...
_components_scripts=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.github/scripts" && pwd)
write_components() {
    local dir=$1 c i=0 t; shift
    local scripts=${_components_scripts}
    t=$(mktemp -d)
    : > "${t}/components.tsv"
    for c in "$@"; do
        i=$((i + 1))
        printf '%s\n' "${c}" >> "${t}/components.tsv"
        COMPONENT="${c}" CHECK=success USABLE=true CHECK_DIGEST="sha256:$(printf '%064d' "${i}")" KEY="$(printf '%040d' "${i}")" \
            RESULT_DIR="${t}/res" bash "${scripts}/binaries-decide.sh" > /dev/null
    done
    bash "${scripts}/binaries-assemble.sh" "${t}/components.tsv" "${t}/res" "${t}/out" > /dev/null || { echo "write_components: binaries-assemble.sh failed" >&2; rm -rf "${t}"; return 1; }
    cp "${t}/out/COMPONENTS" "${dir}/COMPONENTS"
    rm -rf "${t}"
}
