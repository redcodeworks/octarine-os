#!/usr/bin/env bash
# Check the file listing of a built binaries image (`podman export | tar -t`) against the layout the installer expects.
#
#   binaries-layout.sh [--assembled] <listing file> <schedulers.tsv> <component>...
#
# Per component: scx needs scx/bin/<name> for every scheduler of the manifest and scx/schedulers.tsv; extest both libraries; every
# component needs <c>/SOURCE, <c>/BUILDINFO and <c>/LICENSES/*. The assembled image is checked with --assembled, which also needs the top-level SOURCE, BUILDINFO, LICENSES/ and COMPONENTS and
# exactly the named components. Nothing else is judged here (the build already ran the smoke tests and the ELF checks).
set -euo pipefail
assembled=0
if [[ "${1:-}" == --assembled ]]; then assembled=1; shift; fi
listing=${1:?listing}
tsv=${2:?schedulers.tsv}
shift 2
[[ $# -gt 0 ]] || { echo "binaries-layout.sh: name at least one component" >&2; exit 2; }
# The normalized listing goes to a file ONCE: a `norm | grep -q` pipeline under pipefail fails with a SIGPIPE of sed as soon as grep -q finds its match
# early in a long listing (the ghostty component lists 900 files: every need() reported the file as missing although it was there).
normfile=$(mktemp); trap 'rm -f "${normfile}"' EXIT
sed 's#^\./##' "${listing}" > "${normfile}"
norm() { cat "${normfile}"; }
status=0
need() { grep -qxF -- "$1" "${normfile}" || { echo "::error::the binaries image lacks $1" >&2; status=1; }; }
for c in "$@"; do
    case "${c}" in
        scx)
            names=$(grep -vE '^[[:space:]]*(#|$)' "${tsv}" | cut -f1)
            [[ -n "${names}" ]] || { echo "::error::no scheduler in ${tsv}" >&2; exit 1; }
            for n in ${names}; do need "scx/bin/${n}"; done
            need scx/schedulers.tsv ;;
        extest) need extest/lib/libextest.so; need extest/lib64/libextest.so ;;
        ghostty) need ghostty/root/usr/bin/ghostty; need ghostty/root/usr/share/applications/com.mitchellh.ghostty.desktop; need ghostty/FILES ;;
        *) echo "::error::binaries-layout.sh does not know the component '${c}'" >&2; exit 1 ;;
    esac
    need "${c}/SOURCE"; need "${c}/BUILDINFO"
    grep -q "^${c}/LICENSES/." "${normfile}" || { echo "::error::the binaries image has no ${c}/LICENSES" >&2; status=1; }
done
if [[ "${assembled}" == 1 ]]; then
    need SOURCE; need BUILDINFO; need COMPONENTS
    grep -q '^LICENSES/.' "${normfile}" || { echo "::error::the binaries image has no top-level LICENSES" >&2; status=1; }
    extra=$(norm | cut -d/ -f1 | sort -u | grep -vxE 'SOURCE|BUILDINFO|COMPONENTS|LICENSES' | grep -vxF -f <(printf '%s\n' "$@") || true)
    [[ -z "${extra}" ]] || { echo "::error::the binaries image holds unexpected top-level entries: ${extra//$'\n'/ }" >&2; status=1; }
fi
[[ "${status}" == 0 ]] && echo "binaries image layout ok: $*"
exit "${status}"
