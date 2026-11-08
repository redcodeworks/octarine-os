#!/usr/bin/env bash
# Decide whether `testing` needs a build now and print `due` or `skip <reason>`.
#
#   testing-due.sh <testing-sha> <files-vs-main> [<run-sha>...]
#
# <testing-sha>    head commit of the testing branch (empty: the branch does not exist)
# <files-vs-main>  number of files that differ between main and testing (0: same content or nothing ahead)
# <run-sha>...     head shas of the build.yml runs on testing that count: queued, in progress or finished,
#                  but not cancelled (the caller filters cancelled runs out)
set -euo pipefail
sha="${1-}"
files="${2-}"
shift 2 || true

if [[ -z "${sha}" ]]; then echo "skip no testing branch"; exit 0; fi
if ! [[ "${files}" =~ ^[0-9]+$ ]]; then echo "skip unusable file count '${files}'"; exit 0; fi
if ((files == 0)); then echo "skip testing has no changes against main"; exit 0; fi
for r in "$@"; do
    if [[ "${r}" == "${sha}" ]]; then echo "skip a build of ${sha:0:7} already exists"; exit 0; fi
done
echo due
