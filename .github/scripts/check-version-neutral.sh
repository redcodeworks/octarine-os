#!/usr/bin/env bash
# Fail when an image version (read from stdin, one `key=value` label per line) names a channel:
# every label whose key contains `version` (org.opencontainers.image.version, ostree version labels) must
# not contain `testing` or `latest`, and org.opencontainers.image.version must be present.
set -euo pipefail
found=false; bad=0
while IFS='=' read -r k v; do
    [[ "${k,,}" == *version* ]] || continue
    [[ "${k}" != org.opencontainers.image.version ]] || found=true
    if [[ "${v,,}" == *testing* || "${v,,}" == *latest* ]]; then echo "ERROR: ${k}=${v} names a channel"; bad=1; fi
    echo "${k}=${v}"
done
[[ "${found}" == true ]] || { echo "ERROR: org.opencontainers.image.version is missing"; exit 1; }
exit "${bad}"
