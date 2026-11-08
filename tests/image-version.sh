#!/usr/bin/env bash
# Tests image-version.sh and check-version-neutral.sh.
set -euo pipefail
d=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.github/scripts
fail=0
ok() { if "${@:2}" >/dev/null 2>&1; then echo "PASS $1"; else echo "FAIL $1"; fail=1; fi; }
no() { if "${@:2}" >/dev/null 2>&1; then echo "FAIL $1"; fail=1; else echo "PASS $1"; fi; }
v=$(VERSION_DATE=20261108 VERSION_SHA=b8a6aba "${d}/image-version.sh")
[[ "${v}" == 20261108-b8a6aba ]] && echo "PASS version format" || { echo "FAIL version format (${v})"; fail=1; }
[[ "$("${d}/image-version.sh")" =~ ^[0-9]{8}-[0-9a-f]{7,}$ ]] && echo "PASS version of this checkout" || { echo "FAIL version of this checkout"; fail=1; }
ok "neutral version" bash -c "echo org.opencontainers.image.version=20261108-b8a6aba | '${d}/check-version-neutral.sh'"
no "testing in version" bash -c "echo org.opencontainers.image.version=testing.20261108-b8a6aba | '${d}/check-version-neutral.sh'"
no "latest in version" bash -c "echo org.opencontainers.image.version=latest.20261108-b8a6aba | '${d}/check-version-neutral.sh'"
no "channel in an ostree version label" bash -c "printf 'org.opencontainers.image.version=1\nostree.version=testing.1\n' | '${d}/check-version-neutral.sh'"
no "missing label" bash -c "echo a=b | '${d}/check-version-neutral.sh'"
exit "${fail}"
