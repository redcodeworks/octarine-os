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
ok "neutral version" bash -c "printf 'org.opencontainers.image.version=20261108-b8a6aba\\nIMAGE_VERSION=20261108-b8a6aba\\n' | '${d}/check-version-neutral.sh'"
no "testing in version" bash -c "echo org.opencontainers.image.version=testing.20261108-b8a6aba | '${d}/check-version-neutral.sh'"
no "latest in version" bash -c "echo org.opencontainers.image.version=latest.20261108-b8a6aba | '${d}/check-version-neutral.sh'"
no "channel in an ostree version label" bash -c "printf 'org.opencontainers.image.version=1\nostree.version=testing.1\n' | '${d}/check-version-neutral.sh'"
no "missing label" bash -c "echo a=b | '${d}/check-version-neutral.sh'"
# os-release IMAGE_VERSION
iv() { printf 'org.opencontainers.image.version=20261108-b8a6aba\nIMAGE_VERSION=%s\n' "$1"; }
ok "stable IMAGE_VERSION" bash -c "$(declare -f iv); iv 20261108-b8a6aba | '${d}/check-version-neutral.sh'"
ok "quoted IMAGE_VERSION" bash -c "$(declare -f iv); iv '\"20261108-b8a6aba\"' | '${d}/check-version-neutral.sh'"
no "latest in IMAGE_VERSION" bash -c "$(declare -f iv); iv latest-20261108-b8a6aba | '${d}/check-version-neutral.sh'"
no "testing in IMAGE_VERSION" bash -c "$(declare -f iv); iv testing-20261108-b8a6aba | '${d}/check-version-neutral.sh'"
no "beta in a stable IMAGE_VERSION" bash -c "$(declare -f iv); iv beta-20261108-b8a6aba | '${d}/check-version-neutral.sh'"
ok "beta-prefixed IMAGE_VERSION on a beta build" bash -c "$(declare -f iv); iv beta-20261108-b8a6aba | BETA=true '${d}/check-version-neutral.sh'"
no "unprefixed IMAGE_VERSION on a beta build" bash -c "$(declare -f iv); iv 20261108-b8a6aba | BETA=true '${d}/check-version-neutral.sh'"
no "missing IMAGE_VERSION" bash -c "echo org.opencontainers.image.version=20261108-b8a6aba | '${d}/check-version-neutral.sh'"
# set_os_release_field of build.sh and the variant scripts: replace, append (also after a missing final newline), keep the file sourceable
root=$(mktemp -d); trap 'rm -rf "${root}"' EXIT
top=$(dirname "${d}")/..
for s in build_files/build.sh variants/nvidia/nvidia.sh variants/dx/dx.sh; do
    sed -n '/^set_os_release_field() {/,/^}/p' "${top}/${s}" >"${root}/fn.sh"
    [[ -s "${root}/fn.sh" ]] || { echo "FAIL ${s}: no set_os_release_field"; fail=1; continue; }
    f="${root}/os-release"
    printf 'NAME="Fedora Linux"\nID=fedora\nVERSION_ID=45\nPRETTY_NAME="octarineOS"\nIMAGE_ID="old"' >"${f}"   # no final newline
    run() { OS_RELEASE_FILE="${f}" bash -c ". '${root}/fn.sh'; set -e; set_os_release_field IMAGE_ID octarine-os-dx; set_os_release_field IMAGE_VERSION beta-20261110-abc1234; set_os_release_field IMAGE_VERSION 20261110-abc1234"; }
    ok "${s}: sets both fields" run
    ok "${s}: replaces instead of duplicating" bash -c "[ \$(grep -c '^IMAGE_ID=' '${f}') = 1 ] && [ \$(grep -c '^IMAGE_VERSION=' '${f}') = 1 ] && grep -qx 'IMAGE_ID=\"octarine-os-dx\"' '${f}' && grep -qx 'IMAGE_VERSION=\"20261110-abc1234\"' '${f}'"
    ok "${s}: other fields untouched and the file sources" bash -c "grep -qx 'PRETTY_NAME=\"octarineOS\"' '${f}' && grep -qx 'ID=fedora' '${f}' && grep -qx 'VERSION_ID=45' '${f}' && ( . '${f}'; [ \"\${IMAGE_ID}\" = octarine-os-dx ] && [ \"\${NAME}\" = 'Fedora Linux' ] )"
done
exit "${fail}"
