#!/usr/bin/env bash
# Decides whether one datastore image pin (variants/dx/datastore/datastore.env) has a newer patch or minor tag inside its pinned
# MAJOR, and rewrites the tag and digest lines when it has. Used by the weekly workflow bump-pins.yml next to bump-pin.sh; tested
# by tests/datastore-bump.sh with a fake skopeo. Run from the repository root.
#
#   datastore-pin-bump.sh postgresql|valkey|seaweedfs|kafka
#
# The newest candidate is the highest version among the registry's tags that look like the current one (same major, the same suffix:
# 17.12-alpine -> 17.<n>-alpine; a bare 4.3.2 -> 4.<n>.<n>); release candidates and other suffixes never match. The digest is
# sha256 of `skopeo inspect --raw` of that tag. A NEWER MAJOR is only reported ("newer major available, manual decision", also written
# as the output major_note for the pull request body) and never changes the pin: a database or broker major needs a dump and restore.
# Public registry images are not signed with our key: the digest comes from the registry's manifest and the build pulls by that digest.
#
# Exit status and result: 0 equal (nothing newer), 10 different (the file was rewritten), 1 unreachable (the tag list or a manifest
# could not be read: no decision), 3 bad pin or unknown service. With GITHUB_OUTPUT set: result, previous, digest, tag, major_note.
set -uo pipefail
svc=${1:-}
case "${svc}" in postgresql | valkey | seaweedfs | kafka) ;; *) echo "::error::unknown service '${svc}'"; exit 3 ;; esac
file=${DATASTORE_ENV:-variants/dx/datastore/datastore.env}
upper=$(tr '[:lower:]' '[:upper:]' <<<"${svc}")
get() { sed -n "s/^${upper}_$1=//p" "${file}" | head -n1; }
out() { [[ -z "${GITHUB_OUTPUT:-}" ]] || echo "$1=$2" >> "${GITHUB_OUTPUT}"; }
image=$(get IMAGE) tag=$(get TAG) digest=$(get DIGEST) major=$(get MAJOR)
if ! [[ "${image}" =~ ^[a-z0-9.-]+(/[a-z0-9._-]+)+$ && "${tag}" =~ ^[0-9]+(\.[0-9]+)+(-[a-z0-9.]+)?$ && "${digest}" =~ ^sha256:[0-9a-f]{64}$ && "${major}" =~ ^[0-9]+$ && "${tag%%.*}" == "${major}" ]]; then
    echo "::error::the ${upper} pin in ${file} is missing or malformed"; out result badpin; exit 3
fi
out previous "${digest}"
suffix=""
[[ "${tag}" == *-* ]] && suffix="-${tag#*-}"
shape=$(tr -cd '.' <<<"${tag%%-*}" | wc -c)   # the number of dots in the version part: 17.12 has one, 4.3.2 has two

list=$(skopeo list-tags "docker://${image}" 2> /dev/null) || list=""
tags=$(python3 -I -c 'import json,sys
try:
    print("\n".join(json.load(sys.stdin)["Tags"]))
except Exception:
    pass' <<<"${list}")
if [[ -z "${tags}" ]]; then echo "::error::cannot read the tags of ${image} (registry unreachable)"; out result unreachable; exit 1; fi

# candidates of the same shape and suffix, as "<version> <tag>", sorted by version
cands=$(while IFS= read -r t; do
    [[ -n "${suffix}" && "${t}" != *"${suffix}" ]] && continue
    [[ -z "${suffix}" && "${t}" == *-* ]] && continue
    v=${t%"${suffix}"}
    [[ "${v}" =~ ^[0-9]+(\.[0-9]+)+$ ]] || continue
    [[ "$(tr -cd '.' <<<"${v}" | wc -c)" == "${shape}" ]] || continue
    echo "${v} ${t}"
done <<<"${tags}" | sort -V)
if [[ -z "${cands}" ]]; then echo "::error::no tag of ${image} looks like ${tag}"; out result unreachable; exit 1; fi
newest_major_any=$(awk '{ split($1, a, "."); print a[1] }' <<<"${cands}" | sort -n | tail -n1)
within=$(awk -v m="${major}" '{ split($1, a, "."); if (a[1] == m) print }' <<<"${cands}" | tail -n1)
best_tag=${within##* }
major_note=""
if (( newest_major_any > major )); then
    major_note="newer major available (${newest_major_any}), manual decision: the pin stays in major ${major}"
    echo "note: ${major_note}"
fi
out major_note "${major_note}"
[[ -n "${best_tag}" ]] || { echo "::error::no tag of ${image} in major ${major}"; out result unreachable; exit 1; }

current_v=${tag%"${suffix}"}
best_v=${best_tag%"${suffix}"}
newest=$(printf '%s\n%s\n' "${current_v}" "${best_v}" | sort -V | tail -n1)
if [[ "${best_v}" == "${current_v}" || "${newest}" == "${current_v}" ]]; then
    echo "nothing to bump: ${svc} ${tag} is the newest tag in major ${major}"
    out result equal; out tag "${tag}"; out digest "${digest}"
    exit 0
fi
raw=$(skopeo inspect --raw "docker://${image}:${best_tag}" 2> /dev/null) || raw=""
if [[ -z "${raw}" ]]; then echo "::error::cannot read the manifest of ${image}:${best_tag}"; out result unreachable; exit 1; fi
new_digest="sha256:$(printf '%s' "${raw}" | sha256sum | sed 's/ .*//')"
sed -i -e "s/^${upper}_TAG=.*/${upper}_TAG=${best_tag}/" -e "s/^${upper}_DIGEST=.*/${upper}_DIGEST=${new_digest}/" "${file}"
echo "${file} now pins ${image}:${best_tag}@${new_digest} (was ${tag})"
out result different; out tag "${best_tag}"; out digest "${new_digest}"
exit 10
