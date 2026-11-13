#!/usr/bin/env bash
# The result of the dx aggregate job `Build dx and push image` from the results of the jobs before it.
# Environment: PLAN, BUILD, PROMOTE, SIGN (job results: success, failure, cancelled, skipped), BUILD_WANTED and
# PROMOTE_WANTED (plan outputs); BASE (optional: the result of the base build's aggregate job, set by build.yml; when it is
# set and not success the dx image was not built and this fails). Exit 0 = pass.
#   plan empty          the reusable dx workflow reported nothing (it did not start or was skipped): fails
#   plan skipped        the dx workflow is not one that builds for this event or ref (see build-dx.yml): nothing to
#                       report, the job passes
#   build wanted        build and sign must have succeeded
#   promote wanted      promote and sign (which verifies the signature of the retagged digest) must have succeeded
#   neither             legitimate skip (base and dx inputs unchanged): build, promote and sign must all be skipped
set -euo pipefail
err() { echo "::error::$*"; exit 1; }
if [[ -n "${BASE+x}" && "${BASE}" != success ]]; then err "The base build did not succeed (${BASE:-no result}): the dx image was not built on it"; fi
[[ -n "${PLAN-}" ]] || err "The dx workflow reported no result (it did not start, or it was skipped)"
: "${BUILD:?}" "${PROMOTE:?}" "${SIGN:?}"
echo "plan=${PLAN} build wanted=${BUILD_WANTED-} build=${BUILD} promote wanted=${PROMOTE_WANTED-} promote=${PROMOTE} sign=${SIGN}"
if [[ "${PLAN}" == skipped ]]; then
    [[ "${BUILD}" == skipped && "${PROMOTE}" == skipped && "${SIGN}" == skipped ]] || err "Plan skipped but later jobs ran"
    echo "Not a run the dx image is built for: nothing to do"
    exit 0
fi
[[ "${PLAN}" == success ]] || err "The plan job did not succeed (${PLAN})"
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
