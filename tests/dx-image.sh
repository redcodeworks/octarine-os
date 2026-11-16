#!/usr/bin/env bash
# Behavior checks of the developer image (octarine-os-dx) that no build shows early: the signature policy of all three repositories and the dx.sh bundle policy block.
# Nothing here builds an image. Run: tests/dx-image.sh
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
keys_doc=$here/docs/signing-keys.md   # the one place that names the keys document
wf="$here/.github/workflows/build-dx.yml"
root=$(mktemp -d)
trap 'rm -rf -- "$root"' EXIT
pass=0
failn=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { failn=$((failn + 1)); echo "FAIL $1"; [ -f "$root/out" ] && sed 's/^/     /' "$root/out"; }
check() { local d=$1; shift; if "$@" >"$root/out" 2>&1; then ok "$d"; else bad "$d"; fi; }

# ---- signature policy: all three repositories, from any image name
policy_run() { # image name
    local t="$root/pol-$1"
    mkdir -p "$t/etc/containers/registries.d" "$t/etc/pki/containers"
    echo '{"default":[{"type":"insecureAcceptAnything"}],"transports":{"docker":{"":[{"type":"insecureAcceptAnything"}]}}}' >"$t/etc/containers/policy.json"
    sed -n '/^# --- Container signature policy/,/^# --- end signature policy ---/p' "$here/build_files/build.sh" \
        | sed -e "s#/etc/#$t/etc/#g" -e "s#/ctx/cosign.pub#$here/cosign.pub#g" >"$t/block.sh"
    IMAGE_ORG=redcodeworks IMAGE_NAME="$1" bash -e "$t/block.sh" >"$root/out" 2>&1
}
for n in octarine-os octarine-os-nvidia octarine-os-dx octarine-os-nvidia-dx; do
    policy_run "$n"
    for r in octarine-os octarine-os-nvidia octarine-os-dx octarine-os-nvidia-dx; do
        check "policy ($n image): sigstoreSigned rule for ghcr.io/redcodeworks/$r" python3 -c "
import json
d = json.load(open('$root/pol-$n/etc/containers/policy.json'))['transports']['docker']['ghcr.io/redcodeworks/$r']
assert d[0]['type'] == 'sigstoreSigned' and d[0]['signedIdentity'] == {'type': 'matchRepository'} and d[0]['keyPath'].endswith('.pub')"
    done
    check "policy ($n image): the catch-all stays last" python3 -c "import json; d=json.load(open('$root/pol-$n/etc/containers/policy.json'))['transports']['docker']; assert list(d)[-1]==''"
    check "policy ($n image): sigstore attachments enabled for the namespace" grep -q 'use-sigstore-attachments: true' "$root"/pol-$n/etc/containers/registries.d/*.yaml
done
# the dx.sh block that adds the policy for the datastore bundle: run on a copy of the default policy
bt="$root/bundlepol"; mkdir -p "$bt/etc/containers/registries.d" "$bt/etc/pki/containers"
echo '{"default":[{"type":"insecureAcceptAnything"}],"transports":{"docker":{"ghcr.io/redcodeworks/octarine-os":[{"type":"sigstoreSigned","keyPath":"/k","signedIdentity":{"type":"matchRepository"}}],"":[{"type":"insecureAcceptAnything"}]}}}' >"$bt/etc/containers/policy.json"
sed -n '/^# --- datastore bundle signature policy ---/,/^# --- end datastore bundle signature policy ---/p' "$here/variants/dx/dx.sh" | sed -e "s#/etc/#$bt/etc/#g" -e "s#/ctx/toolbox-cosign.pub#$here/keys/redcodeworks-toolbox-cosign.pub#g" >"$bt/block.sh"
check "dx.sh bundle policy: the block runs" bash -e "$bt/block.sh"
check "dx.sh bundle policy: a sigstoreSigned rule for the bundle repository with the toolbox key, the image's own rules and the catch-all kept, catch-all last" python3 -I - "$bt" "$here/keys/redcodeworks-toolbox-cosign.pub" <<'PY'
import json, sys
bt, pub = sys.argv[1:]
d = json.load(open(bt + "/etc/containers/policy.json"))["transports"]["docker"]
r = d["ghcr.io/redcodeworks/datastore-images"]
assert len(r) == 1 and r[0]["type"] == "sigstoreSigned" and r[0]["signedIdentity"] == {"type": "matchRepository"}
assert open(r[0]["keyPath"]).read() == open(pub).read()
assert "ghcr.io/redcodeworks/octarine-os" in d and list(d)[-1] == ""
PY
check "dx.sh bundle policy: registries.d reads the signature attachments of exactly the bundle repository" bash -c "grep -q 'ghcr.io/redcodeworks/datastore-images:' '$bt'/etc/containers/registries.d/*.yaml && grep -q 'use-sigstore-attachments: true' '$bt'/etc/containers/registries.d/*.yaml"

echo "passed: $pass, failed: $failn"
[ "$failn" = 0 ]
