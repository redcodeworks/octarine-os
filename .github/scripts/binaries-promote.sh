#!/usr/bin/env bash
# Promote the prebuilt binaries: retag the TESTED, signed octarine-binaries:testing to :latest (no rebuild, the same digest and the same signature), like the
# image's own promotion. Runs on main only (binaries.yml). Nothing else moves `latest`.
#
#   binaries-promote.sh <registry-image>        env: GITHUB_OUTPUT (changed=true|false, digest=<digest of latest>)
#
# Fails, and changes nothing, unless `testing` exists, verifies with cosign.pub and was built from exactly the binaries/ tree of this checkout (its
# version label is the assembled key, `binaries-key.sh`): content that was not built and signed on testing is never put on latest. A failed or still
# running build on testing therefore fails the promotion; re-run it when the build on testing is green.
set -euo pipefail
image=${1:?registry image}
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
fail() { echo "::error::$*" >&2; exit 1; }
emit() { echo "$1=$2"; [[ -z "${GITHUB_OUTPUT:-}" ]] || echo "$1=$2" >> "${GITHUB_OUTPUT}"; }

want=$("${here}/binaries-key.sh")
rc=0
tested=$(IMAGE="${image}" "${here}/registry-digest.sh" testing) || rc=$?
[[ "${rc}" == 0 ]] || fail "${image}:testing could not be read (exit ${rc}; 3 = it does not exist): build the binaries on testing first"
cfg=$("${here}/registry-read.sh" config "${image}@${tested}") || fail "the config of ${image}@${tested} could not be read"
have=$(jq -r '.config.Labels["org.opencontainers.image.version"] // empty' <<< "${cfg}")
[[ "${have}" == "${want}" ]] || fail "${image}:testing was built from binaries key ${have:-unknown}, this tree has ${want}: it is not the tested content (the build on testing failed, has not finished, or testing moved on)"
"${here}/cosign-check.sh" --key cosign.pub "${image}@${tested}" || fail "${image}@${tested} is not signed with cosign.pub"

rc=0
current=$(IMAGE="${image}" "${here}/registry-digest.sh" latest) || rc=$?
[[ "${rc}" == 0 || "${rc}" == 3 ]] || fail "${image}:latest could not be read (exit ${rc})"
if [[ "${rc}" == 0 && "${current}" == "${tested}" ]]; then
    echo "latest already is the tested image ${tested}: nothing to promote"
    emit changed false; emit digest "${tested}"
    exit 0
fi
"${here}/retry.sh" skopeo copy --all --preserve-digests "docker://${image}@${tested}" "docker://${image}:latest"
"${here}/registry-settled.sh" "${image}" latest "${tested}"
"${here}/cosign-check.sh" --key cosign.pub "${image}:latest" || fail "${image}:latest does not verify after the retag"
echo "promoted ${image}:latest ${current:-<none>} -> ${tested} (key ${want})"
emit changed true; emit digest "${tested}"
