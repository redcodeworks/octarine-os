#!/usr/bin/env bash
# Quick checks of the Test workflow (.github/workflows/test.yml): triggers, job names, permissions, pins,
# concurrency, that every tests/*.sh runs by globbing, and that build.yml is not part of this change.
# Run: tests/test-workflow.sh
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
root=$(mktemp -d)
trap 'rm -rf -- "$root"' EXIT
pass=0
failn=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { failn=$((failn + 1)); echo "FAIL $1"; [ -f "$root/out" ] && sed 's/^/     /' "$root/out"; }
check() { local d=$1; shift; if "$@" >"$root/out" 2>&1; then ok "$d"; else bad "$d"; fi; }

check "test.yml: no pull_request trigger, and a run on the testing tip is never cancelled" python3 - "$here" <<'PY'
import sys, yaml
w = yaml.safe_load(open(sys.argv[1] + "/.github/workflows/test.yml"))
on = w.get(True) or w.get("on")
assert "pull_request" not in on and "pull_request_target" not in on, set(on)
assert "refs/heads/testing" in w["concurrency"]["cancel-in-progress"], w["concurrency"]
PY
check "test.yml: test and secrets keep their required names, secrets needs nothing, test always runs and runs inside the base the images are built on" python3 - "$here" <<'PY'
import sys, yaml
w = yaml.safe_load(open(sys.argv[1] + "/.github/workflows/test.yml"))
assert "needs" not in w["jobs"]["secrets"], "secrets must not wait for anything"
assert "always()" in w["jobs"]["test"]["if"]
for k in ("test", "secrets"):
    assert w["jobs"][k]["name"] == k, k
# the test job runs INSIDE the base the images are built on: its container is the digest the base job resolved (base-pin.sh), never a fixed image
assert "needs.base.outputs.image" in str(w["jobs"]["test"]["container"]), w["jobs"]["test"]["container"]
PY
check "test.yml: read-only permissions, one concurrency group per workflow and ref" python3 - "$here" <<'PY'
import sys, yaml
w = yaml.safe_load(open(sys.argv[1] + "/.github/workflows/test.yml"))
assert w["permissions"] == {"contents": "read"}, w["permissions"]
c = w["concurrency"]
assert "github.ref" in c["group"] and "github.workflow" in c["group"], c
PY
check "every external action in every workflow and composite action is pinned by a full commit SHA, with a version comment (one exception pins without)" python3 - "$here" <<'PY'
import glob, re, sys
files = glob.glob(sys.argv[1] + "/.github/workflows/*.yml") + glob.glob(sys.argv[1] + "/.github/actions/*/action.yml")
n = 0
for f in files:
    for line in open(f):
        m = re.search(r"^\s*(?:- )?uses:\s*(\S+)", line)
        if not m or m.group(1).startswith("./"):
            continue
        n += 1
        assert re.fullmatch(r"[\w./-]+@[0-9a-f]{40}", m.group(1)), (f, line)
        if "ublue-os/remove-unwanted-software" not in line:  # the workflows pin this one without a comment too
            assert re.search(r"#\s*\S", line), "no version comment: %s %s" % (f, line)
assert n >= 10, n
PY
check "test.yml: tests/*.sh run by a glob, no hard-coded test list" python3 - "$here" <<'PY'
import re, sys, yaml
w = yaml.safe_load(open(sys.argv[1] + "/.github/workflows/test.yml"))
runs = "\n".join(s.get("run", "") for s in yaml.safe_load(open(sys.argv[1] + "/.github/actions/test-suite/action.yml"))["runs"]["steps"])
assert ".github/scripts/run-tests.sh --jobs 4" in runs and "--doc-tests" in runs, runs
assert not re.search(r"tests/[\w-]+\.sh", runs.replace("tests/*.sh", "")), "a test is named by hand"
PY
check "test.yml: the secrets job scans the full history with a pinned gitleaks and checksum" python3 - "$here" <<'PY'
import re, sys, yaml
w = yaml.safe_load(open(sys.argv[1] + "/.github/workflows/test.yml"))
steps = w["jobs"]["secrets"]["steps"]
assert any(s.get("with", {}).get("fetch-depth") == 0 for s in steps)
inst = next(s for s in steps if "gitleaks" in s.get("name", "") and "Install" in s["name"])
assert re.fullmatch(r"\d+\.\d+\.\d+", inst["env"]["GITLEAKS_VERSION"])
assert re.fullmatch(r"[0-9a-f]{64}", inst["env"]["GITLEAKS_SHA256"])
assert "--retry" in inst["run"] and "sha256sum -c" in inst["run"]
PY

echo
echo "${pass} passed, ${failn} failed"
[ "$failn" -eq 0 ]
