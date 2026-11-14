#!/usr/bin/env bash
# The result of the dx aggregate job `Build dx and push image` from the results of the jobs before it.
# Environment: PLAN, BUILD, PROMOTE, SIGN (job results: success, failure, cancelled, skipped), BUILD_WANTED and
# PROMOTE_WANTED (plan outputs). Exit 0 = pass.
#   plan skipped        the triggering run is not one dx builds for (a failed or cancelled vanilla run, the beta build on
#                       testing): nothing to report, the job passes and posts no commit status (see build-dx.yml)
#   build wanted        build and sign must have succeeded
#   promote wanted      promote and sign (which verifies the signature of the retagged digest) must have succeeded
#   DRY_RUN=true        plan only: build, promote and sign must all be skipped, always passes then
#   neither             legitimate skip (base and dx inputs unchanged): build, promote and sign must all be skipped
set -euo pipefail
: "${PLAN:?}" "${BUILD:?}" "${PROMOTE:?}" "${SIGN:?}"
echo "plan=${PLAN} build wanted=${BUILD_WANTED-} build=${BUILD} promote wanted=${PROMOTE_WANTED-} promote=${PROMOTE} sign=${SIGN}"
err() { echo "::error::$*"; exit 1; }
if [[ "${PLAN}" == skipped ]]; then
    [[ "${BUILD}" == skipped && "${PROMOTE}" == skipped && "${SIGN}" == skipped ]] || err "Plan skipped but later jobs ran"
    echo "Not a run the dx image is built for: nothing to do"
    exit 0
fi
[[ "${PLAN}" == success ]] || err "The plan job did not succeed (${PLAN})"
if [[ "${DRY_RUN-}" == true ]]; then
    # a dry run plans and reports only: nothing may have been built, promoted or signed
    [[ "${BUILD}" == skipped && "${PROMOTE}" == skipped && "${SIGN}" == skipped ]] || err "Dry run, but later jobs ran (build ${BUILD}, promote ${PROMOTE}, sign ${SIGN})"
    echo "Dry run: planned build=${BUILD_WANTED-} promote=${PROMOTE_WANTED-}; nothing was built, pushed or signed"
    exit 0
fi
if [[ "${BUILD_WANTED-}" == true ]]; then
    [[ "${BUILD}" == success && "${PROMOTE}" == skipped && "${SIGN}" == success ]] || err "The dx build did not succeed (build ${BUILD}, promote ${PROMOTE}, sign ${SIGN})"
elif [[ "${PROMOTE_WANTED-}" == true ]]; then
    [[ "${PROMOTE}" == success && "${BUILD}" == skipped && "${SIGN}" == success ]] || err "The dx promotion did not succeed (promote ${PROMOTE}, build ${BUILD}, sign ${SIGN})"
    echo "Promoted the tested dx image: no rebuild"
else
    [[ "${BUILD}" == skipped && "${PROMOTE}" == skipped && "${SIGN}" == skipped ]] || err "Unexpected results (build ${BUILD}, promote ${PROMOTE}, sign ${SIGN})"
    echo "Base and dx inputs unchanged: nothing to build"
fi
echo "ok"
