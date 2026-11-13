#!/usr/bin/env bash
# Checks the pins of the prebuilt binary images in the Containerfile (scx-bin and extest-bin, built by the fedora-toolbox
# repository): tag and digest format, and with --verify the cosign signature of each pinned digest against
# keys/redcodeworks-toolbox-cosign.pub (the same key as the dev-packages pin). Logs what the build uses and, when
# GITHUB_ENV is set, exports SCX_BIN_REF and EXTEST_BIN_REF. Run from the repository root; CONTAINERFILE overrides the file.
#   check-binary-pins.sh [--verify]
set -euo pipefail
file=${CONTAINERFILE:-Containerfile}
key=${COSIGN_KEY_FILE:-keys/redcodeworks-toolbox-cosign.pub}
verify=false
[[ "${1:-}" == --verify ]] && verify=true
status=0
for spec in "scx-bin:SCX_BIN" "extest-bin:EXTEST_BIN"; do
    image=${spec%%:*}
    prefix=${spec##*:}
    tag=$(sed -n "s/^ARG ${prefix}_TAG=//p" "${file}")
    digest=$(sed -n "s/^ARG ${prefix}_DIGEST=//p" "${file}")
    if ! [[ "${tag}" =~ ^(latest|testing)(-[0-9]{8})?(-[0-9a-f]{7})?$ ]]; then
        echo "::error::${prefix}_TAG missing or not latest, testing or <latest|testing>[-YYYYMMDD][-<sha7>] in ${file}"
        status=1
        continue
    fi
    if ! [[ "${digest}" =~ ^sha256:[0-9a-f]{64}$ ]]; then
        echo "::error::${prefix}_DIGEST missing or not sha256:<64 hex> in ${file}"
        status=1
        continue
    fi
    ref="ghcr.io/redcodeworks/${image}@${digest}"
    if ${verify}; then
        if ! cosign verify --key "${key}" "${ref}" > /dev/null; then
            echo "::error::cosign verification failed for ${ref}"
            status=1
            continue
        fi
        echo "${image} pinned: ${tag} ${ref} (signature valid)"
    else
        echo "${image} pinned: ${tag} ${ref}"
    fi
    [[ -z "${GITHUB_ENV:-}" ]] || echo "${prefix}_REF=${ref}" >> "${GITHUB_ENV}"
done
exit "${status}"
