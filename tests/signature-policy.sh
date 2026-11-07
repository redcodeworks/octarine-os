#!/usr/bin/env bash
# Tests for build_files/signature-policy.sh against a fake root with a stand-in policy.json (shaped like
# the one silverblue-main ships: a signed ublue-os scope and an accept-anything catch-all).
# No network, nothing outside a temp dir. Needs: bash, python3. Run: tests/signature-policy.sh
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
script="$here/../build_files/signature-policy.sh"
root=$(mktemp -d)
trap 'rm -rf -- "$root"' EXIT
pass=0
failn=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { failn=$((failn + 1)); echo "FAIL $1"; }
check() { local d=$1; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }

echo "fake public key" >"$root/cosign.pub"
fresh() {
    rm -rf "$root/fs"
    mkdir -p "$root/fs/etc/containers"
    cat >"$root/fs/etc/containers/policy.json" <<'JSON'
{"default": [{"type": "reject"}], "transports": {"docker": {
  "ghcr.io/ublue-os": [{"type": "sigstoreSigned", "keyPath": "/etc/pki/containers/ublue-os.pub"}],
  "": [{"type": "insecureAcceptAnything"}]}}}
JSON
}
has_scope() { # scope
    python3 -I -c '
import json, sys
d = json.load(open(sys.argv[1]))["transports"]["docker"]
e = d.get(sys.argv[2])
sys.exit(not (e and e[0]["type"] == "sigstoreSigned" and e[0]["keyPath"].startswith("/etc/pki/containers/")))' \
        "$root/fs/etc/containers/policy.json" "$1"
}
catch_all_last() {
    python3 -I -c '
import json, sys
d = json.load(open(sys.argv[1]))["transports"]["docker"]
sys.exit(not (list(d)[-1] == "" and "ghcr.io/ublue-os" in d))' "$root/fs/etc/containers/policy.json"
}
run() { ROOT="$root/fs" COSIGN_PUB="$root/cosign.pub" "$script" >"$root/out" 2>&1; }

fresh
IMAGE_ORG=RedCodeWorks IMAGE_NAME=octarine-os IMAGE_NAMES="octarine-os octarine-os-stable" run
check "script succeeds" test $? -eq 0
check "policy covers octarine-os" has_scope ghcr.io/redcodeworks/octarine-os
check "policy covers octarine-os-stable" has_scope ghcr.io/redcodeworks/octarine-os-stable
check "catch-all stays last, base scope kept" catch_all_last
check "key installed for the stable image" test -f "$root/fs/etc/pki/containers/redcodeworks-octarine-os-stable.pub"
check "registries.d entry for the stable image" grep -q use-sigstore-attachments "$root/fs/etc/containers/registries.d/redcodeworks-octarine-os-stable.yaml"

# Building the stable image alone (IMAGE_NAME is the stable one) still covers both when listed
fresh
IMAGE_ORG=redcodeworks IMAGE_NAME=octarine-os-stable IMAGE_NAMES="octarine-os octarine-os-stable" run
check "stable build covers octarine-os" has_scope ghcr.io/redcodeworks/octarine-os
check "stable build covers itself" has_scope ghcr.io/redcodeworks/octarine-os-stable

# IMAGE_NAMES missing: falls back to IMAGE_NAME; a name left out of the list is added
fresh
IMAGE_ORG=redcodeworks IMAGE_NAME=octarine-os run
check "no IMAGE_NAMES: covers IMAGE_NAME" has_scope ghcr.io/redcodeworks/octarine-os
fresh
IMAGE_ORG=redcodeworks IMAGE_NAME=octarine-os-stable IMAGE_NAMES="octarine-os" run
check "the image being built is always covered" has_scope ghcr.io/redcodeworks/octarine-os-stable

# Running it twice does not break the policy
IMAGE_ORG=redcodeworks IMAGE_NAME=octarine-os-stable IMAGE_NAMES="octarine-os octarine-os-stable" run
check "idempotent" has_scope ghcr.io/redcodeworks/octarine-os

# Missing inputs: no policy change, success (as build.sh always did)
fresh
before=$(cat "$root/fs/etc/containers/policy.json")
IMAGE_ORG="" IMAGE_NAME=octarine-os run
check "missing IMAGE_ORG leaves the policy alone" test "$(cat "$root/fs/etc/containers/policy.json")" = "$before"

# The names in image-template.env are the ones the workflow plans
for v in IMAGE_NAME IMAGE_NAME_STABLE; do
    check "$v is set in image-template.env" grep -qE "^$v=[a-z0-9-]+$" "$here/../image-template.env"
done

echo
echo "$pass passed, $failn failed"
(( failn == 0 ))
