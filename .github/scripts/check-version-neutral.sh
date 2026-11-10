#!/usr/bin/env bash
# Fail when an image version (read from stdin, one `key=value` line each) names a channel:
# - every label whose key contains `version` (org.opencontainers.image.version, ostree version labels) must not
#   contain `testing` or `latest`, and org.opencontainers.image.version must be present;
# - the line `IMAGE_VERSION=<value>` (os-release, the CI appends it to the labels) is required and follows the same rule;
#   a stable image's IMAGE_VERSION also names no `beta`, and with BETA=true (the beta channel builds, never promoted) it
#   must start with `beta-`. Quotes around a value are ignored.
set -euo pipefail
found=false; found_os=false; bad=0
while IFS='=' read -r k v; do
    [[ "${k,,}" == *version* ]] || continue
    v="${v%\"}"; v="${v#\"}"
    [[ "${k}" != org.opencontainers.image.version ]] || found=true
    if [[ "${v,,}" == *testing* || "${v,,}" == *latest* ]]; then echo "ERROR: ${k}=${v} names a channel"; bad=1; fi
    if [[ "${k}" == IMAGE_VERSION ]]; then
        found_os=true
        if [[ "${BETA:-false}" == true ]]; then
            [[ "${v}" == beta-* ]] || { echo "ERROR: ${k}=${v} must start with beta- on a beta build"; bad=1; }
        elif [[ "${v,,}" == *beta* ]]; then
            echo "ERROR: ${k}=${v} names a channel"; bad=1
        fi
    fi
    echo "${k}=${v}"
done
[[ "${found}" == true ]] || { echo "ERROR: org.opencontainers.image.version is missing"; exit 1; }
[[ "${found_os}" == true ]] || { echo "ERROR: os-release IMAGE_VERSION is missing"; exit 1; }
exit "${bad}"
