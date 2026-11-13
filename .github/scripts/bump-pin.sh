#!/usr/bin/env bash
# Decides whether the digest pin of an external image (today only dev-packages, built by the fedora-toolbox repository) has to move to its
# `latest` tag, and rewrites the pin when it has. Used by the weekly workflow bump-pins.yml; tested with fake skopeo and
# cosign by tests/bump-pins.sh. Run from the repository root.
#
#   bump-pin.sh dev-packages
#
# Steps: resolve the digest of <image>:latest (skopeo inspect --raw, sha256 of the manifest, the way the pins are made),
# verify its cosign signature with keys/redcodeworks-toolbox-cosign.pub, compare it with the pin, and when it differs
# rewrite the pin's digest line and its tag line (the dated tag with the same digest, else `latest`; the tag is only
# a label for humans). Nothing else in the file changes. With GITHUB_OUTPUT set it writes result, digest, tag and previous.
#
# Exit status and result (the decision table):
#   0  equal         the pin already is `latest`, the file is not touched
#   10 different     `latest` is signed and newer, the pin was rewritten
#   1  unreachable   `latest` could not be resolved (registry down, tag missing, empty answer): no decision possible
#   2  badsignature  `latest` is not signed by the key: the file is not touched
#   3  badpin        the pin in the file is missing or malformed, or an unknown image name
set -uo pipefail
image=${1:-}
case "${image}" in
    dev-packages) file=variants/dx/Containerfile; prefix=DEV_PACKAGES ;;
    *) echo "::error::unknown image '${image}' (dev-packages)"; exit 3 ;;
esac
key=${COSIGN_KEY_FILE:-keys/redcodeworks-toolbox-cosign.pub}
repo=ghcr.io/redcodeworks/${image}
out() { [[ -z "${GITHUB_OUTPUT:-}" ]] || echo "$1=$2" >> "${GITHUB_OUTPUT}"; }

current=$(sed -n "s/^ARG ${prefix}_DIGEST=//p" "${file}")
current_tag=$(sed -n "s/^ARG ${prefix}_TAG=//p" "${file}")
if ! [[ "${current}" =~ ^sha256:[0-9a-f]{64}$ ]]; then
    echo "::error::${prefix}_DIGEST missing or malformed in ${file}"; out result badpin; exit 3
fi
out previous "${current}"

manifest=$(skopeo inspect --raw "docker://${repo}:latest" 2>/dev/null) || manifest=""
if [[ -z "${manifest}" ]]; then
    echo "::error::cannot resolve ${repo}:latest (registry unreachable or the tag does not exist yet)"
    out result unreachable; exit 1
fi
hex=$(printf '%s' "${manifest}" | sha256sum | sed 's/ .*//')
[[ "${hex}" =~ ^[0-9a-f]{64}$ ]] || { echo "::error::cannot compute the digest of ${repo}:latest"; out result unreachable; exit 1; }
latest="sha256:${hex}"
out digest "${latest}"

if ! cosign verify --key "${key}" "${repo}@${latest}" > /dev/null; then
    echo "::error::cosign verification failed for ${repo}@${latest} (${file} is unchanged)"
    out result badsignature; exit 2
fi
echo "${repo}:latest = ${latest} (signature valid)"

if [[ "${latest}" == "${current}" ]]; then
    echo "nothing to bump: ${image} is pinned to ${latest} (${current_tag})"
    out result equal; out tag "${current_tag}"; exit 0
fi

# the pin keeps a dated tag for humans: find the one that points at the same digest, else fall back to latest
tag=latest
tags=$(skopeo list-tags "docker://${repo}" 2>/dev/null | python3 -I -c 'import json,re,sys
try:
    t = json.load(sys.stdin)["Tags"]
except Exception:
    t = []
print("\n".join(sorted((x for x in t if re.fullmatch(r"latest-\d{8}-[0-9a-f]{7}", x)), reverse=True)[:10]))') || tags=""
for t in ${tags}; do
    d=$(skopeo inspect --raw "docker://${repo}:${t}" 2>/dev/null | sha256sum | sed 's/ .*//')
    if [[ "sha256:${d}" == "${latest}" ]]; then tag=${t}; break; fi
done
sed -i -e "s/^ARG ${prefix}_TAG=.*/ARG ${prefix}_TAG=${tag}/" -e "s/^ARG ${prefix}_DIGEST=.*/ARG ${prefix}_DIGEST=${latest}/" "${file}"
echo "${file} now pins ${repo}:${tag}@${latest} (was ${current_tag}@${current})"
out result different; out tag "${tag}"
exit 10
