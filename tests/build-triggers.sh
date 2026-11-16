#!/usr/bin/env bash
# Behavior that first runs on main or schedule: which refs publish (the channel step is run with each ref), the final plan decision (promote, reuse, build,
# never skip on a failed verification), and one lint that GitHub never reports as an error: a job whose if reads a needed result needs its own status
# function. Trigger lists, names, schedules and step order are not asserted. Run: tests/build-triggers.sh
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
root=$(mktemp -d)
trap 'rm -rf -- "$root"' EXIT
pass=0
failn=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { failn=$((failn + 1)); echo "FAIL $1"; [ -f "$root/out" ] && sed 's/^/     /' "$root/out"; }
check() { local d=$1; shift; if "$@" >"$root/out" 2>&1; then ok "$d"; else bad "$d"; fi; }

check "build.yml: only main and testing publish (channel step); a dispatch from any other ref is validation only" bash -s -- "$here" "$root" <<'SH'
python3 - "$1" "$2" <<'PY'
import sys, yaml
w = yaml.safe_load(open(sys.argv[1] + "/.github/workflows/build.yml"))
run = {s.get("id"): s for s in w["jobs"]["build_push"]["steps"]}["channel"]["run"]
open(sys.argv[2] + "/channel-step.sh", "w").write(run)
PY
f="$2/channel-step.sh"
for ref in refs/heads/feat/x refs/heads/some-dev refs/tags/v1; do
  rm -f "$2/out"; out=$(EVENT=workflow_dispatch REF=$ref GITHUB_OUTPUT="$2/out" bash "$f" >/dev/null </dev/null && grep -x "publish=.*" "$2/out")
  [ "$out" = "publish=false" ] || { echo "$ref: $out"; exit 1; }
done
for ref in refs/heads/main refs/heads/testing; do
  rm -f "$2/out"; out=$(EVENT=workflow_dispatch REF=$ref GITHUB_OUTPUT="$2/out" bash "$f" >/dev/null </dev/null && grep -x "publish=.*" "$2/out")
  [ "$out" = "publish=true" ] || { echo "$ref: $out"; exit 1; }
done
SH
check "a job whose if reads a needed job's RESULT has its own status function (always() or !cancelled()): GitHub adds an implicit success() otherwise, which is false when ANY ancestor was skipped" python3 - "$here" <<'PY'
import sys, glob, re, yaml
status = re.compile(r"always\(\)|!cancelled\(\)|failure\(\)|success\(\)|cancelled\(\)")
bad = []
for f in glob.glob(sys.argv[1] + "/.github/workflows/*.yml"):
    for n, j in yaml.safe_load(open(f))["jobs"].items():
        cond = str(j.get("if", ""))
        if re.search(r"needs\.[\w-]+\.result", cond) and not status.search(cond):
            bad.append((f.split("/")[-1], n))
# these two sign jobs are meant to be skipped together with a skipped build
bad = [b for b in bad if b not in (('binaries.yml', 'sign'), ('binaries-component.yml', 'sign'), ('build-nvidia-dx.yml', 'sign'))]
assert not bad, bad
PY
check "the final decision of the plan: promote, reuse (nothing to build), build, never skip on a failed verification" bash -s -- "$here" "$root" <<'SH'
python3 - "$1" "$2" <<'PY'
import sys, yaml
w = yaml.safe_load(open(sys.argv[1] + "/.github/workflows/build.yml"))
run = next(s["run"] for s in w["jobs"]["plan"]["steps"] if "BUILD_PLAN" in str(s.get("env")))
open(sys.argv[2] + "/final-step.sh", "w").write(run)
PY
f="$2/final-step.sh"
root=$2
t() { local want=$1; shift; got=$(rm -f "$root/o"; BUILD_PLAN=$1 SCHED_SKIP=$2 CANDIDATE=$3 REUSE=$4 VERIFY=$5 GITHUB_OUTPUT="$root/o" GITHUB_STEP_SUMMARY="$root/sum" bash "$f" >/dev/null 2>&1 </dev/null; echo "$(sed -n 's/^build=//p' "$root/o") $(sed -n 's/^promote=//p' "$root/o")"); [ "$got" = "$want" ] || { echo "$*: got '$got' want '$want'"; exit 1; }; }
t "false true"  true "" true  ""    success   # promote, verified
t "true false"  true "" true  ""    failure   # promote candidate, verification failed: build
t "false false" true "" ""    true  success   # dx-only change on testing: reused image verified, nothing to build
t "true false"  true "" ""    true  failure   # reused image failed verification: build
t "true false"  true "" ""    ""    skipped   # vanilla change: build
t "false false" false "" ""   ""    skipped   # docs-only: plan said no
t "false false" true true ""  ""    skipped   # scheduled skip
SH

echo "passed: $pass, failed: $failn"
[ "$failn" = 0 ]
