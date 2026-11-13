#!/usr/bin/env bash
# Check the file listing of a built binaries image (`podman export | tar -t`) against the layout the installer expects.
#
#   binaries-layout.sh <listing file> <schedulers.tsv>
#
# Every scheduler of the manifest as scx/bin/<name>, scx/schedulers.tsv, both extest libraries, and for each component and at the
# top LICENSES/, SOURCE and BUILDINFO. Nothing else is judged here (the build already ran each --version and the ELF checks).
set -euo pipefail
listing=${1:?listing}
tsv=${2:?schedulers.tsv}
norm() { sed 's#^\./##' "${listing}"; }
status=0
need() { norm | grep -qxF -- "$1" || { echo "::error::the binaries image lacks $1" >&2; status=1; }; }
names=$(grep -vE '^[[:space:]]*(#|$)' "${tsv}" | cut -f1)
[[ -n "${names}" ]] || { echo "::error::no scheduler in ${tsv}" >&2; exit 1; }
for n in ${names}; do need "scx/bin/${n}"; done
need scx/schedulers.tsv
need extest/lib/libextest.so
need extest/lib64/libextest.so
for c in scx extest; do need "${c}/SOURCE"; need "${c}/BUILDINFO"; done
need SOURCE
need BUILDINFO
norm | grep -q '^LICENSES/.' || { echo "::error::the binaries image has no top-level LICENSES" >&2; status=1; }
for c in scx extest; do norm | grep -q "^${c}/LICENSES/." || { echo "::error::the binaries image has no ${c}/LICENSES" >&2; status=1; }; done
[[ "${status}" == 0 ]] && echo "binaries image layout ok: $(echo ${names})"
exit "${status}"
