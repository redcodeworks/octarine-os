#!/usr/bin/env bash
# The decision of ONE component of the prebuilt binaries (the `result` job of binaries-component.yml): what became of it, and the one
# JSON object the assemble job reads. Writes <RESULT_DIR>/<component>.json, one object with the named fields
#   name, status, digest, key, reason
# status is one of
#   reused      a signed image of this component's content key already existed (digest = that image)
#   built       built, pushed and signed by this run (digest = the signed image)
#   validated   built on a ref that cannot publish: nothing is pushed, there is no digest
#   failed      anything else (the script exits 1 after writing the line, so the leg is red)
# A component that is neither built nor reused fails the run (every component is required). There is
# no fallback to an older image: a failed required build is a red run and the previous `latest` stays.
# Environment: COMPONENT CHECK USABLE CHECK_DIGEST KEY BUILD BUILD_OK PUBLISHED SIGN SIGN_DIGEST RESULT_DIR;
# GITHUB_OUTPUT and GITHUB_STEP_SUMMARY when set.
set -euo pipefail
comp=${COMPONENT:?component}
dir=${RESULT_DIR:-.}
mkdir -p "${dir}"
sum() { [[ -z "${GITHUB_STEP_SUMMARY:-}" ]] || echo "$*" >> "${GITHUB_STEP_SUMMARY}"; echo "$*"; }
finish() { # status digest key reason
    jq -n --arg name "${comp}" --arg status "$1" --arg digest "$2" --arg key "$3" --arg reason "$4" '$ARGS.named' > "${dir}/${comp}.json"
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then { echo "status=$1"; echo "digest=$2"; echo "key=$3"; } >> "${GITHUB_OUTPUT}"; fi
    echo "status=$1 digest=$2 key=$3"
}
fail() { echo "::error::component ${comp}: $*"; finish failed "" "${KEY:-}" "$*"; exit 1; }

[[ "${CHECK:-}" == success ]] || fail "the lookup of the ${comp} image failed (${CHECK:-unset})"
if [[ "${USABLE:-}" == true ]]; then
    sum "Component ${comp}: reused \`${KEY}\` (digest \`${CHECK_DIGEST}\`, signature verified, no build)"
    finish reused "${CHECK_DIGEST}" "${KEY}" "signed image of this key exists"
    exit 0
fi
[[ "${BUILD:-}" == success ]] || fail "the build job did not run to its end (${BUILD:-unset})"
if [[ "${BUILD_OK:-}" == true ]]; then
    if [[ "${PUBLISHED:-}" == true ]]; then
        [[ "${SIGN:-}" == success ]] || fail "signing the ${comp} image failed (${SIGN:-unset})"
        sum "Component ${comp}: built \`${KEY}\`, signed and published (digest \`${SIGN_DIGEST}\`)"
        finish built "${SIGN_DIGEST}" "${KEY}" "built and signed"
    else
        sum "Component ${comp}: built \`${KEY}\` for validation only (this ref does not publish), nothing was pushed or signed"
        finish validated "" "${KEY}" "validation build"
    fi
    exit 0
fi
fail "the build failed"
