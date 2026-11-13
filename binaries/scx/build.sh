#!/usr/bin/env bash
# Build every scheduler named in binaries/scx/schedulers.tsv from the checked-out scx source and stage the image content.
#
#   build.sh <schedulers.tsv> <upstream.env> <source dir> <out dir>
#
# One cargo invocation for all of them: cargo build --release --locked -p <a> -p <b> ... Then stage.sh installs
# target/release/<name> as /bin/<name>, copies the LICENSE of the scheduler's directory (found under scheds/, when it has
# one) next to the repository LICENSE, and runs <name> --version. Finally /schedulers.tsv is written: one line per scheduler, FOUR tab
# separated fields, no header, in the order of the source file:  name  binary path  minimum kernel  description
# (minimum kernel may be empty; the other fields never are). Adding a scheduler is a line in schedulers.tsv, not code.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
list="${1:?schedulers.tsv}"
envfile="${2:?upstream.env}"
srcdir="${3:?source dir}"
out="${4:?out dir}"
stage="${STAGE_SH:-${here}/../lib/stage.sh}"

mapfile -t rows < <(grep -vE '^[[:space:]]*(#|$)' "${list}" || true)
[[ ${#rows[@]} -gt 0 ]] || { echo "build.sh: no scheduler in ${list}" >&2; exit 1; }

names=() pkgs=() args=() manifest=()
for row in "${rows[@]}"; do
    fields=$(awk -F'\t' '{print NF}' <<<"${row}")
    [[ "${fields}" == 3 ]] || { echo "build.sh: '${row}' must have exactly three tab separated fields (name, minimum kernel, description)" >&2; exit 1; }
    n=$(awk -F'\t' '{print $1}' <<<"${row}")
    kernel=$(awk -F'\t' '{print $2}' <<<"${row}")
    desc=$(awk -F'\t' '{print $3}' <<<"${row}")
    [[ "${n}" =~ ^[a-z0-9_]+$ ]] || { echo "build.sh: bad scheduler name '${n}'" >&2; exit 1; }
    [[ " ${names[*]:-} " != *" ${n} "* ]] || { echo "build.sh: duplicate scheduler: ${n}" >&2; exit 1; }
    [[ -z "${kernel}" || "${kernel}" =~ ^[0-9]+\.[0-9]+$ ]] || { echo "build.sh: ${n}: minimum kernel must be MAJOR.MINOR or empty (got '${kernel}')" >&2; exit 1; }
    [[ -n "${desc}" && "${desc}" != " "* && "${desc}" != *" " && ${#desc} -le 120 ]] || { echo "build.sh: ${n}: the description must be one non-empty line of at most 120 characters" >&2; exit 1; }
    names+=("${n}")
    pkgs+=(-p "${n}")
    args+=(--bin "target/release/${n}:bin/${n}" --smoke "bin/${n}:--version")
    sdir=$(find "${srcdir}/scheds" -mindepth 2 -maxdepth 2 -type d -name "${n}" | head -n1)
    [[ -n "${sdir}" ]] || { echo "build.sh: ${n} is not a scheduler directory under scheds/ of the source" >&2; exit 1; }
    # most scheduler directories carry their own LICENSE (copied next to the repository LICENSE); scx_cake's does not, and the
    # repository LICENSE (GPL-2.0) covers it, so a missing file is a note, not an error
    if [[ -s "${sdir}/LICENSE" ]]; then
        args+=(--license "${sdir#"${srcdir}/"}/LICENSE:${n}-LICENSE")
    else
        echo "build.sh: ${n} has no LICENSE of its own; the repository LICENSE covers it"
    fi
    manifest+=("$(printf '%s\t%s\t%s\t%s' "${n}" "bin/${n}" "${kernel}" "${desc}")")
done

(cd "${srcdir}" && cargo build --release --locked "${pkgs[@]}")
"${stage}" --out "${out}" --env "${envfile}" --src "${srcdir}" --license "LICENSE:scx-LICENSE" "${args[@]}" \
    --info "schedulers: ${names[*]}"
printf '%s\n' "${manifest[@]}" > "${out}/schedulers.tsv"
echo "schedulers.tsv: ${#manifest[@]} schedulers"
