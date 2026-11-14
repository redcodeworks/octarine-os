#!/usr/bin/env bash
# Renders the datastore Quadlets of the dx image: copies variants/dx/datastore/quadlets/* to <outdir> and replaces every
# @<NAME>_IMAGE@ with <image>:<tag>@<digest> from datastore.env (the one file that holds the pins). Fails on a bad pin, a missing
# pin or a placeholder that is left over. Used by dx.sh at image build and by the tests.
#   render.sh <outdir> [<datastore dir>]
set -euo pipefail
out="${1:?outdir}"
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
src="${2:-${here}}"
env_file="${src}/datastore.env"
[[ -f "${env_file}" ]] || { echo "render: ${env_file} not found" >&2; exit 1; }
declare -A V=()
while IFS= read -r line || [[ -n "${line}" ]]; do
    line=${line%%#*}
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    [[ -n "${line}" ]] || continue
    [[ "${line}" =~ ^([A-Z_]+)=(.*)$ ]] || { echo "render: not KEY=VALUE: '${line}'" >&2; exit 1; }
    V["${BASH_REMATCH[1]}"]=${BASH_REMATCH[2]}
done < "${env_file}"
mkdir -p "${out}"
for f in "${src}"/quadlets/*; do cp "${f}" "${out}/$(basename "${f}")"; done
for name in POSTGRESQL VALKEY SEAWEEDFS KAFKA; do
    image=${V[${name}_IMAGE]:-} tag=${V[${name}_TAG]:-} digest=${V[${name}_DIGEST]:-} major=${V[${name}_MAJOR]:-}
    [[ "${image}" =~ ^[a-z0-9.-]+(:[0-9]+)?(/[a-z0-9._-]+)+$ ]] || { echo "render: bad ${name}_IMAGE '${image}'" >&2; exit 1; }
    [[ "${tag}" =~ ^[0-9]+(\.[0-9]+)+(-[a-z0-9.]+)?$ && "${tag}" != latest ]] || { echo "render: ${name}_TAG '${tag}' is not an exact version tag" >&2; exit 1; }
    [[ "${digest}" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "render: bad ${name}_DIGEST '${digest}'" >&2; exit 1; }
    [[ "${major}" =~ ^[0-9]+$ && "${tag%%.*}" == "${major}" ]] || { echo "render: ${name}_TAG '${tag}' is not in major ${major}" >&2; exit 1; }
    sed -i "s|@${name}_IMAGE@|${image}:${tag}@${digest}|g" "${out}"/*.container
done
if grep -q '@[A-Z_]*@' "${out}"/*; then echo "render: a placeholder is left over" >&2; exit 1; fi
echo "rendered $(ls "${out}" | wc -l) files into ${out}"
