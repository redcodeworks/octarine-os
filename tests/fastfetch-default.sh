#!/usr/bin/env bash
# Tests the default fastfetch configuration shipped in system_files (fastfetch itself is a Homebrew install and is not
# in the image): the file exists, parses as JSON once the full-line // comments are removed, has the Image command
# module, and nothing in the build installs fastfetch.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
f=$here/system_files/etc/xdg/fastfetch/config.jsonc
fail=0
check() { if "${@:2}" >/dev/null 2>&1; then echo "PASS $1"; else echo "FAIL $1"; fail=1; fi; }
json() { grep -vE '^[[:space:]]*//' "$f"; }
check "the file exists in system_files" test -s "$f"
check "it parses as JSON without the comment lines" bash -c "grep -vE '^[[:space:]]*//' '$f' | jq -e . "
check "it has the Image command module" bash -c "grep -vE '^[[:space:]]*//' '$f' | jq -e '.modules[] | select(type==\"object\" and .type==\"command\" and .key==\"Image\" and (.text|contains(\"IMAGE_ID\")))'"
check "the Image module reads IMAGE_VERSION too" bash -c "grep -vE '^[[:space:]]*//' '$f' | jq -e '.modules[] | select(type==\"object\" and .key==\"Image\") | .text | contains(\"IMAGE_VERSION\")'"
check "no script is shipped next to it" bash -c "[ \$(ls '$(dirname "$f")' | wc -l) = 1 ]"
check "fastfetch is not installed by the build or a Brewfile" bash -c "! grep -rIl fastfetch '$here/build_files' '$here/Containerfile' '$here/variants' '$here'/system_files/usr/share/ublue-os 2>/dev/null | grep -q ."
exit "$fail"
