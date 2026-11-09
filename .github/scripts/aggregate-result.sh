#!/usr/bin/env bash
# Decide the result of the aggregate job `Build and push image` from the results of the jobs before it.
# Environment: PLAN, BUILD, PROMOTE, SIGN (job results: success, failure, cancelled, skipped),
# BUILD_WANTED, PROMOTE_WANTED (plan outputs), PUBLISH (build_push output `publish`).
# Exit 0 = pass. It means: planned, built (or promoted, or docs-only skipped) and, when anything was
# published, signed and verified. A skipped sign job is fine only when nothing was published.
set -euo pipefail
: "${PLAN:?}" "${BUILD:?}" "${PROMOTE:?}" "${SIGN:?}"
echo "plan=${PLAN} build wanted=${BUILD_WANTED-} build=${BUILD} promote wanted=${PROMOTE_WANTED-} promote=${PROMOTE} publish=${PUBLISH-} sign=${SIGN}"
err() { echo "::error::$*"; exit 1; }
[[ "${PLAN}" == success ]] || err "The plan job did not succeed"
sign_expected=false
if [[ "${BUILD_WANTED-}" == true ]]; then
    [[ "${BUILD}" == success && "${PROMOTE}" == skipped ]] || err "The image build did not succeed (${BUILD}, promote ${PROMOTE})"
    [[ "${PUBLISH-}" != true ]] || sign_expected=true
elif [[ "${PROMOTE_WANTED-}" == true ]]; then
    [[ "${PROMOTE}" == success && "${BUILD}" == skipped ]] || err "The promotion did not succeed (${PROMOTE}, build ${BUILD})"
    sign_expected=true
    echo "Promoted a tested image: no rebuild"
else
    [[ "${BUILD}" == skipped && "${PROMOTE}" == skipped ]] || err "Unexpected results (build ${BUILD}, promote ${PROMOTE})"
    echo "Docs-only change or unchanged scheduled run: heavy build skipped"
fi
if [[ "${sign_expected}" == true ]]; then
    [[ "${SIGN}" == success ]] || err "Signing and verification did not succeed (${SIGN})"
else
    [[ "${SIGN}" == skipped ]] || err "Unexpected sign result ${SIGN} with nothing published"
fi
echo "ok"
