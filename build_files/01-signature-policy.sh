#!/usr/bin/bash
# Our own step (Bluefin has no file for it): the container signature policy for this image and its sibling repositories.

echo "::group:: ===$(basename "$0")==="

set -eoux pipefail

# Needs IMAGE_ORG and IMAGE_NAME (Containerfile build args) and cosign.pub from the repo root.
# Everything is derived from them, so a fork only changes config/image.env and cosign.pub. The default image and
# the NVIDIA variant (<name>-nvidia, built on request from the same files) and the developer image (<name>-dx, built from
# the published default image) and the NVIDIA developer image (<name>-nvidia-dx, the dx layer on the NVIDIA variant) all
# get a rule for ALL SEVEN repositories (the fifth is the gamer variant <name>-gx, the sixth <name>-nvidia-gx, the gx layer on the NVIDIA variant, the seventh <name>-dx-gx, the experimental gx layer on the dx image (alias `fx` in switch-image is no repository): their rules make a machine that boots
# this image able to switch to it later), so a machine on any of them can switch to another with
# --enforce-container-sigpolicy. A machine can switch to a repository only once it has booted an image that carries its rule.
if [[ -n "${IMAGE_ORG:-}" && -n "${IMAGE_NAME:-}" && -f /ctx/cosign.pub ]]; then
	org="${IMAGE_ORG,,}"
	name="${IMAGE_NAME,,}"
	base_name="${name%-dx}"
	base_name="${base_name%-gx}"
	base_name="${base_name%-nvidia}"
	refs="ghcr.io/${org}/${base_name} ghcr.io/${org}/${base_name}-nvidia ghcr.io/${org}/${base_name}-dx ghcr.io/${org}/${base_name}-nvidia-dx ghcr.io/${org}/${base_name}-gx ghcr.io/${org}/${base_name}-nvidia-gx ghcr.io/${org}/${base_name}-dx-gx"
	key="/etc/pki/containers/${org}-${name}.pub"
	install -Dm644 /ctx/cosign.pub "${key}"
	printf 'docker:\n  ghcr.io/%s:\n    use-sigstore-attachments: true\n' "${org}" \
		>"/etc/containers/registries.d/${org}-${name}.yaml"
	python3 - "${key}" ${refs} <<'PY'
import json
import sys

key, refs = sys.argv[1], sys.argv[2:]
path = "/etc/containers/policy.json"
policy = json.load(open(path))
scopes = policy["transports"]["docker"]
catch_all = scopes.pop("", None)
for ref in refs:
    scopes[ref] = [{"type": "sigstoreSigned", "keyPath": key, "signedIdentity": {"type": "matchRepository"}}]
if catch_all is not None:
    scopes[""] = catch_all
with open(path, "w") as f:
    json.dump(policy, f, indent=4)
    f.write("\n")
PY
else
	echo "IMAGE_ORG, IMAGE_NAME or cosign.pub missing: not adding a signature policy for this image"
fi

echo "::endgroup::"
