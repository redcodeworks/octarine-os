#!/usr/bin/env bash
# Run the shell tests (tests/*.sh, or the files named) in parallel with plain shell and report them in a fixed order.
#
#   run-tests.sh [--jobs N] [FILE...]
#
# Each test runs as `bash FILE` with its output buffered in a temp file (never interleaved), under `timeout` (TEST_TIMEOUT seconds,
# default 900: a test that hangs fails instead of holding the job for its whole time limit). When all are done the results are printed in
# the order of the file list: one PASS or FAIL line with the duration per test, the buffered output of every failing one, and a final
# `Summary: N passed, M failed` line. The exit status is 1 when any test failed or timed out. N defaults to TEST_JOBS or 4 (the CI
# runner has four vCPUs). Every test makes its own temp directory and shares no fixed path or port, so they are independent. The runner
# exports ONE variable to them, RUN_TESTS_OUT, with a name no test uses (a first version exported `out`, which a test took for its own).
set -uo pipefail
jobs=${TEST_JOBS:-4}
files=()
while (($#)); do
    case "$1" in
        --jobs) jobs=${2:?--jobs needs a number}; shift ;;
        --jobs=*) jobs=${1#--jobs=} ;;
        *) files+=("$1") ;;
    esac
    shift
done
[[ "${jobs}" =~ ^[0-9]+$ ]] && ((jobs >= 1)) || { echo "--jobs needs a positive number" >&2; exit 2; }
if ((${#files[@]} == 0)); then
    shopt -s nullglob
    files=(tests/*.sh)
fi
((${#files[@]} > 0)) || { echo "no tests to run" >&2; exit 2; }

RUN_TESTS_OUT=$(mktemp -d)
trap 'rm -rf -- "${RUN_TESTS_OUT}"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
export RUN_TESTS_OUT
export TEST_TIMEOUT=${TEST_TIMEOUT:-900}

run_one() {
    local f=$1 id start rc
    id=$(printf '%s' "${f}" | tr '/ ' '__')
    start=$(date +%s)
    timeout "${TEST_TIMEOUT}" bash "${f}" > "${RUN_TESTS_OUT}/${id}.log" 2>&1
    rc=$?
    echo "${rc} $(($(date +%s) - start))" > "${RUN_TESTS_OUT}/${id}.rc"
}
export -f run_one

begin=$(date +%s)
printf '%s\0' "${files[@]}" | xargs -0 -P "${jobs}" -I{} bash -c 'run_one "$1"' _ {}

pass=0
failed=()
for f in "${files[@]}"; do
    id=$(printf '%s' "${f}" | tr '/ ' '__')
    if [[ -f "${RUN_TESTS_OUT}/${id}.rc" ]]; then read -r rc secs < "${RUN_TESTS_OUT}/${id}.rc"; else rc=255; secs=0; fi
    if ((rc == 0)); then
        pass=$((pass + 1))
        echo "PASS ${f} (${secs} s)"
    else
        failed+=("${f}")
        if ((rc == 124)); then echo "FAIL ${f} (timed out after ${TEST_TIMEOUT} s)"; else echo "FAIL ${f} (exit ${rc}, ${secs} s)"; fi
        sed 's/^/     /' "${RUN_TESTS_OUT}/${id}.log" 2> /dev/null
    fi
done
echo "Summary: ${pass} passed, ${#failed[@]} failed, $(($(date +%s) - begin)) s in total (${jobs} at a time)"
if ((${#failed[@]} > 0)); then
    echo "::error::failed: ${failed[*]}"
    exit 1
fi
