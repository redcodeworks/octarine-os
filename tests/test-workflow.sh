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

check "test.yml: push on every dev branch (not main, not testing), dispatch, no pull_request" python3 - "$here" <<'PY'
import sys, yaml
w = yaml.safe_load(open(sys.argv[1] + "/.github/workflows/test.yml"))
on = w.get(True) or w.get("on")
assert set(on) == {"push", "workflow_dispatch"}, set(on)
assert on["push"] == {"branches-ignore": ["main", "testing"]}, on["push"]
PY
check "test.yml: jobs are exactly test and secrets, named so" python3 - "$here" <<'PY'
import sys, yaml
w = yaml.safe_load(open(sys.argv[1] + "/.github/workflows/test.yml"))
assert set(w["jobs"]) == {"test", "secrets"}, set(w["jobs"])
for k in ("test", "secrets"):
    assert w["jobs"][k]["name"] == k, k
    assert w["jobs"][k]["runs-on"] == "ubuntu-26.04", k
assert w["jobs"]["test"]["container"] == "fedora:45"
PY
check "test.yml: read-only permissions, one concurrency group per ref, cancel in progress" python3 - "$here" <<'PY'
import sys, yaml
w = yaml.safe_load(open(sys.argv[1] + "/.github/workflows/test.yml"))
assert w["permissions"] == {"contents": "read"}, w["permissions"]
c = w["concurrency"]
assert "github.ref" in c["group"] and "github.workflow" in c["group"], c
assert c["cancel-in-progress"] is True, c
PY
check "test.yml: every external action is pinned by SHA with a version comment" python3 - "$here" <<'PY'
import re, sys
n = 0
for line in open(sys.argv[1] + "/.github/workflows/test.yml"):
    m = re.search(r"uses:\s*(\S+)", line)
    if not m or m.group(1).startswith("./"):
        continue
    n += 1
    assert re.fullmatch(r"[\w./-]+@[0-9a-f]{40}", m.group(1)), line
    assert re.search(r"#\s*v\d", line), "no version comment: " + line
assert n >= 1
PY
check "test.yml: the test job uses the setup-tool just and runs just check and bash -n" python3 - "$here" <<'PY'
import sys, yaml
w = yaml.safe_load(open(sys.argv[1] + "/.github/workflows/test.yml"))
steps = w["jobs"]["test"]["steps"]
assert any(s.get("uses") == "./.github/actions/setup-tool" and s["with"] == {"tool": "just"} for s in steps)
runs = "\n".join(s.get("run", "") for s in steps)
assert "just check" in runs and "bash -n" in runs
PY
check "test.yml: tests/*.sh run by a glob, no hard-coded test list" python3 - "$here" <<'PY'
import re, sys, yaml
w = yaml.safe_load(open(sys.argv[1] + "/.github/workflows/test.yml"))
runs = "\n".join(s.get("run", "") for s in w["jobs"]["test"]["steps"])
assert "for t in tests/*.sh" in runs, runs
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
check "build.yml: untouched by this change (still has its pull_request trigger; no diff against origin/testing when available)" bash -c '
  cd "$1" && grep -q "pull_request:" .github/workflows/build.yml || exit 1
  if git rev-parse -q --verify refs/remotes/origin/testing >/dev/null && ! git diff --quiet origin/testing...HEAD -- . 2>/dev/null; then
    base=$(git merge-base origin/testing HEAD) && [ -z "$(git diff --name-only "$base" HEAD -- .github/workflows/build.yml)" ] || { echo "build.yml differs from the merge base"; exit 1; }
  fi' _ "$here"

echo
echo "${pass} passed, ${failn} failed"
[ "$failn" -eq 0 ]
