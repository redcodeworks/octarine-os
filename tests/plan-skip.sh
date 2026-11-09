#!/usr/bin/env bash
# Tests for .github/scripts/plan-skip.sh (the scheduled-run skip decision) with fixed inputs. Run: tests/plan-skip.sh
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
script="$here/../.github/scripts/plan-skip.sh"
pass=0
failn=0
now=$(date -u -d '2026-11-08T10:05:00Z' +%s)
t() { # description, expected prefix, VAR=value...
    local d=$1 want=$2 out
    shift 2
    out=$(env -i PATH="$PATH" EVENT=schedule REF=refs/heads/main BASE_NOW=sha256:aa LATEST_BASE=sha256:aa REPO_SAME=true \
        LATEST_CREATED=2026-11-05T10:05:00Z NOW_EPOCH="$now" MAX_AGE_DAYS=7 SIGNED=true "$@" "$script")
    if [[ "$out" == "$want"* ]]; then pass=$((pass + 1)); echo "ok   $d"; else failn=$((failn + 1)); echo "FAIL $d: got '$out'"; fi
}
t "all unchanged: skip" "skipped: base, repo and age unchanged"
t "push event builds" "build: not a scheduled run" EVENT=push
t "workflow_dispatch builds" "build: not a scheduled run" EVENT=workflow_dispatch
t "testing ref builds" "build: not main" REF=refs/heads/testing
t "base changed builds" "build: base image changed" BASE_NOW=sha256:bb
t "label missing (old image) builds" "build: base digest unknown" LATEST_BASE=
t "base lookup failed builds" "build: base digest unknown" BASE_NOW=
t "repo changed builds" "build: repository content differs" REPO_SAME=false
t "repo unknown builds" "build: repository content differs" REPO_SAME=
t "8 days old builds" "build: latest is 8 days old" LATEST_CREATED=2026-10-31T10:05:00Z
t "exactly 7 days old builds" "build: latest is 7 days old" LATEST_CREATED=2026-11-01T10:05:00Z
t "6 days old skips" "skipped" LATEST_CREATED=2026-11-02T10:05:01Z
t "unsigned builds" "build: latest is not verified as signed" SIGNED=false
t "signature check failed builds" "build: latest is not verified as signed" SIGNED=
t "no created date builds" "build: age of latest unknown" LATEST_CREATED=
t "garbage date builds" "build: cannot read created date" LATEST_CREATED=garbage
t "age limit variable respected" "skipped" MAX_AGE_DAYS=30 LATEST_CREATED=2026-10-20T10:05:00Z
echo "passed: $pass, failed: $failn"
[ "$failn" = 0 ]
