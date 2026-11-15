#!/usr/bin/env bash
# The decision of ONE component of the prebuilt binaries (the `result` job of binaries-component.yml): what became of it, and the one
# line the assemble job reads. Writes <RESULT_DIR>/<component>.tsv with the tab separated fields
#   name  status  digest  key  created  reason
# status is one of
#   reused      a signed image of this component's content key already existed (digest = that image)
#   built       built, pushed and signed by this run (digest = the signed image)
#   validated   built on a ref that cannot publish, or a rehearsal: nothing is pushed, there is no digest
#   fallback    the build failed and the last good image of the component is used (digest, key and created are THAT image's)
#   absent      OPTIONAL component whose build failed and that has no usable last good image: left out of the image
#   failed      anything else (the script exits 1 after writing the line, so the leg is red)
# A required component that is neither built nor reused nor validly fallen back fails; an optional one never does once the build job
# itself ran (a refused or missing last good image means `absent`). A fallback job that was skipped means no fallback applies on this
# run (the workflow decides that): a failed build is then `failed`, optional or not.
# Environment: COMPONENT OPTIONAL CHECK USABLE CHECK_DIGEST KEY BUILD BUILD_OK PUBLISHED SIGN SIGN_DIGEST FALLBACK FB_OK FB_DIGEST FB_KEY
# FB_CREATED DRY_RUN EVENT RESULT_DIR; GITHUB_OUTPUT and GITHUB_STEP_SUMMARY when set.
set -euo pipefail
comp=${COMPONENT:?component}
dir=${RESULT_DIR:-.}
mkdir -p "${dir}"
sum() { [[ -z "${GITHUB_STEP_SUMMARY:-}" ]] || echo "$*" >> "${GITHUB_STEP_SUMMARY}"; echo "$*"; }
finish() { # status digest key created reason
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "${comp}" "$1" "$2" "$3" "$4" "$5" > "${dir}/${comp}.tsv"
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then { echo "status=$1"; echo "digest=$2"; echo "key=$3"; } >> "${GITHUB_OUTPUT}"; fi
    echo "status=$1 digest=$2 key=$3"
}
fail() { echo "::error::component ${comp}: $*"; finish failed "" "${KEY:-}" "" "$*"; exit 1; }

[[ "${CHECK:-}" == success ]] || fail "the lookup of the ${comp} image failed (${CHECK:-unset})"
if [[ "${USABLE:-}" == true ]]; then
    sum "Component ${comp}: reused \`${KEY}\` (digest \`${CHECK_DIGEST}\`, signature verified, no build)"
    finish reused "${CHECK_DIGEST}" "${KEY}" "" "signed image of this key exists"
    exit 0
fi
[[ "${BUILD:-}" == success ]] || fail "the build job did not run to its end (${BUILD:-unset})"
if [[ "${BUILD_OK:-}" == true ]]; then
    if [[ "${PUBLISHED:-}" == true ]]; then
        [[ "${SIGN:-}" == success ]] || fail "signing the ${comp} image failed (${SIGN:-unset})"
        sum "Component ${comp}: built \`${KEY}\`, signed and published (digest \`${SIGN_DIGEST}\`)"
        finish built "${SIGN_DIGEST}" "${KEY}" "" "built and signed"
    else
        sum "Component ${comp}: built \`${KEY}\` for validation only (this ref does not publish), nothing was pushed or signed"
        finish validated "" "${KEY}" "" "validation build"
    fi
    exit 0
fi
# the build failed
if [[ "${FALLBACK:-}" != success ]]; then
    fail "the build failed and no fallback applies on this run (only the daily build on main for a required component; any publishing run for an optional one)"
fi
if [[ "${DRY_RUN:-}" == true && "${EVENT:-}" == workflow_dispatch ]]; then
    if [[ "${FB_OK:-}" == true ]]; then
        sum "FALLBACK (dry run) ${comp}: the last good image ${FB_DIGEST} (key ${FB_KEY}, built ${FB_CREATED}) is signed and satisfies this tree's installer; nothing is used or changed"
    elif [[ "${OPTIONAL:-}" == true ]]; then
        sum "FALLBACK (dry run) ${comp}: no usable last good image; this optional component would be LEFT OUT of the image; nothing is used or changed"
    else
        sum "FALLBACK (dry run) ${comp}: no usable last good image and the component is required: the run would FAIL; nothing is used or changed"
    fi
    finish validated "" "${KEY}" "" "dry run"
    exit 0
fi
if [[ "${FB_OK:-}" == true ]]; then
    msg="FALLBACK: component ${comp} uses its last good image ${FB_DIGEST} (key ${FB_KEY}, built ${FB_CREATED}) because its build failed"
    echo "::warning::${msg}"
    sum "## ${msg}"
    finish fallback "${FB_DIGEST}" "${FB_KEY}" "${FB_CREATED}" "build failed, last good image used"
    exit 0
fi
if [[ "${OPTIONAL:-}" == true ]]; then
    msg="OMITTED: optional component ${comp} is left out of the image: its build failed and it has no usable last good image"
    echo "::warning::${msg}"
    sum "## ${msg}"
    finish absent "" "" "" "build failed, no last good image"
    exit 0
fi
fail "the build failed and the last good ${comp} image was refused or does not exist (see the fallback job): the component is required"
