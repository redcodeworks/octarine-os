#!/bin/bash
# Container signature policy for this repo's images.
#
# Adds one sigstoreSigned scope to policy.json (and a registries.d entry that reads the cosign
# signatures from the registry) for every image in IMAGE_NAMES, or for IMAGE_NAME when IMAGE_NAMES is
# empty. All images are signed with the same key, so one cosign.pub serves every scope; listing all of
# them in every image is what lets a host `bootc switch` between octarine-os and octarine-os-stable
# with signature checking in both directions.
#
# Environment: IMAGE_ORG, IMAGE_NAME, IMAGE_NAMES (space separated), COSIGN_PUB (default
# /ctx/cosign.pub), ROOT (default /, only the tests change it).
set -euo pipefail

root="${ROOT:-/}"
root="${root%/}"
pub="${COSIGN_PUB:-/ctx/cosign.pub}"

if [[ -z "${IMAGE_ORG:-}" || -z "${IMAGE_NAME:-}${IMAGE_NAMES:-}" || ! -f "${pub}" ]]; then
    echo "IMAGE_ORG, IMAGE_NAME or cosign.pub missing: not adding a signature policy for this image"
    exit 0
fi

org="${IMAGE_ORG,,}"
names="${IMAGE_NAMES:-${IMAGE_NAME}}"
# The image being built is always covered, even if IMAGE_NAMES forgot it
if [[ -n "${IMAGE_NAME:-}" && " ${names,,} " != *" ${IMAGE_NAME,,} "* ]]; then
    names+=" ${IMAGE_NAME}"
fi

refs=()
keys=()
install -d "${root}/etc/containers/registries.d"
for name in ${names,,}; do
    key="/etc/pki/containers/${org}-${name}.pub"
    install -Dm644 "${pub}" "${root}${key}"
    printf 'docker:\n  ghcr.io/%s:\n    use-sigstore-attachments: true\n' "${org}" \
        >"${root}/etc/containers/registries.d/${org}-${name}.yaml"
    refs+=("ghcr.io/${org}/${name}")
    keys+=("${key}")
done

python3 - "${root}/etc/containers/policy.json" "${refs[@]}" -- "${keys[@]}" <<'PY'
import json
import sys

path = sys.argv[1]
args = sys.argv[2:]
split = args.index("--")
refs, keys = args[:split], args[split + 1:]
policy = json.load(open(path))
scopes = policy["transports"]["docker"]
catch_all = scopes.pop("", None)
for ref, key in zip(refs, keys):
    scopes[ref] = [{"type": "sigstoreSigned", "keyPath": key, "signedIdentity": {"type": "matchRepository"}}]
if catch_all is not None:
    scopes[""] = catch_all
with open(path, "w") as f:
    json.dump(policy, f, indent=4)
    f.write("\n")
PY
echo "Signature policy scopes: ${refs[*]}"
