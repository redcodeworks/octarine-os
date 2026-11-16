#!/usr/bin/env bash
# Tests .github/scripts/prune-testing.py: a version that carries a `latest*` tag next to `testing*` tags (a
# promoted image) must never be deleted, however old; plain old testing builds are.
set -euo pipefail
py=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.github/scripts/prune-testing.py
d1=$(printf 'a%.0s' {1..64}); d2=$(printf 'b%.0s' {1..64}); d3=$(printf 'c%.0s' {1..64})
json=$(cat <<EOJ
[
 {"id":1,"name":"sha256:${d1}","created_at":"2026-01-01T00:00:00Z","metadata":{"container":{"tags":["testing-1111111","latest","latest-20260101-2222222","20260101"]}}},
 {"id":2,"name":"sha256:${d2}","created_at":"2026-01-02T00:00:00Z","metadata":{"container":{"tags":["testing-3333333","latest-20260102"]}}},
 {"id":3,"name":"sha256:${d3}","created_at":"2026-01-03T00:00:00Z","metadata":{"container":{"tags":["testing-4444444"]}}},
 {"id":4,"name":"sha256:$(printf 'd%.0s' {1..64})","created_at":"2026-01-04T00:00:00Z","metadata":{"container":{"tags":["testing-5555555"]}}}
]
EOJ
)
out=$(KEEP=1 DRY_RUN=true python3 -I "${py}" <<< "${json}")
echo "${out}"
fail=0
grep -q "DELETE image id=3 " <<< "${out}" && echo "PASS old testing-only build is deleted" || { echo "FAIL old testing-only build kept"; fail=1; }
if grep -E "DELETE image id=(1|2) " <<< "${out}"; then echo "FAIL a version with a latest tag would be deleted"; fail=1; else echo "PASS versions with latest tags are kept"; fi
# the safety cap: a LIVE plan over MAX_DELETES is refused (exit non-zero) before anything is deleted; a DRY run over the limit prints the plan, warns and exits 0
# (it deletes nothing, and a red dry run stopped the passes after it); the default is large enough for a week of builds
ghdir=$(mktemp -d); printf '#!/usr/bin/env bash\necho "gh $*" >> "%s/calls"\n' "${ghdir}" > "${ghdir}/gh"; chmod +x "${ghdir}/gh"
if MAX_DELETES=0 KEEP=1 DRY_RUN=false API_BASE=users/o/packages/container/i PATH="${ghdir}:${PATH}" python3 -I "${py}" <<< "${json}" >/dev/null 2>&1; then echo "FAIL a live plan over MAX_DELETES was not refused"; fail=1; else echo "PASS a live plan over MAX_DELETES is refused"; fi
[[ ! -e "${ghdir}/calls" ]] && echo "PASS ...and nothing was deleted" || { echo "FAIL the refused live run called gh"; fail=1; }
dry=$(MAX_DELETES=0 KEEP=1 DRY_RUN=true python3 -I "${py}" <<< "${json}" 2>&1); rc=$?
[[ ${rc} == 0 && "${dry}" == *"Dry run:"* && "${dry}" == *"::warning::the plan has"* ]] && echo "PASS a dry run over MAX_DELETES prints the plan, warns and exits 0" || { echo "FAIL dry run over the limit (rc ${rc}): ${dry}"; fail=1; }
rm -rf "${ghdir}"
grep -q 'or 400)' "${py}" && echo "PASS the default cap is 400" || { echo "FAIL the default cap is not 400"; fail=1; }
exit "${fail}"
