#!/usr/bin/env bash
# Prints the dated tag (<YYYYMMDD>-<sha7>, a name for humans) of an octarine-bins image (octarine-bins, -dx or -gx) that points at a given digest.
# The tag comes from the registry, not from an image label: the bins images are reproducible, so they carry no version/revision/created labels
# (a label would change the digest) and the build identity lives in tags. Several dated tags may point at one digest (a byte-identical rebuild):
# the newest one wins (by date, then the later one in the registry's list). Works for images with or without the old version label.
#
#   bins-tag.sh <image reference without tag, e.g. ghcr.io/redcodeworks/octarine-bins> <sha256:digest>        env: RETRY_TRIES, RETRY_DELAY (retry.sh)
# Exit status: 0 the tag is on stdout; 1 no dated tag points at the digest (or the list/manifests cannot be read), with a plain message on stderr.
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ref=${1:?image reference}; digest=${2:?digest}
[[ "${digest}" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "bins-tag: malformed digest '${digest}'" >&2; exit 1; }
list=$("${here}/retry.sh" skopeo list-tags "docker://${ref}" 2> /dev/null | jq -r '.Tags[]' 2> /dev/null) || list=""
[[ -n "${list}" ]] || { echo "bins-tag: cannot list the tags of ${ref}" >&2; exit 1; }
# dated tags only, newest first: reverse the registry order, then a stable reverse sort on the date keeps the later-listed tag first within a date
while IFS= read -r tag; do
    [[ -n "${tag}" ]] || continue
    raw=$("${here}/retry.sh" skopeo inspect --raw "docker://${ref}:${tag}" 2> /dev/null) || raw=""
    [[ -n "${raw}" ]] || continue
    if [[ "sha256:$(printf '%s' "${raw}" | sha256sum | sed 's/ .*//')" == "${digest}" ]]; then echo "${tag}"; exit 0; fi
done < <(grep -E '^[0-9]{8}-[0-9a-f]{7}$' <<< "${list}" | tac | sort -s -r -t- -k1,1)
echo "bins-tag: no dated tag (<YYYYMMDD>-<sha7>) of ${ref} points at ${digest}" >&2
exit 1
