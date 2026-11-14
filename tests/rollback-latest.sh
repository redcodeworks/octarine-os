#!/usr/bin/env bash
# Tests the shape of .github/workflows/rollback-latest.yml (the decision logic is publish-latest.sh with ALLOW_BACKWARDS, tested in tests/publish-latest.sh).
# Run: tests/rollback-latest.sh. Needs: bash, python3 with PyYAML.
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
root=$(mktemp -d); trap 'rm -rf -- "$root"' EXIT
pass=0; failn=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { failn=$((failn + 1)); echo "FAIL $1"; sed 's/^/     /' "$root/out"; }
check() { local d=$1; shift; if "$@" >"$root/out" 2>&1; then ok "$d"; else bad "$d"; fi; }
check "rollback-latest.yml: only a dispatch; the tag and the reason are required, dry_run defaults to true, default_only to false" python3 -I - "$here" <<'PY'
import sys, yaml
w = yaml.safe_load(open(sys.argv[1] + "/.github/workflows/rollback-latest.yml")); on = w.get(True) or w.get("on")
assert set(on) == {"workflow_dispatch"}
i = on["workflow_dispatch"]["inputs"]
assert set(i) == {"vanilla_tag", "reason", "default_only", "dry_run"}
assert i["vanilla_tag"]["required"] is True and i["reason"]["required"] is True
assert i["dry_run"]["default"] is True and i["default_only"]["default"] is False
PY
check "rollback-latest.yml: the first job is a 30-second cancel window (none in a dry run) and the move waits for it" python3 -I - "$here" <<'PY'
import sys, yaml
w = yaml.safe_load(open(sys.argv[1] + "/.github/workflows/rollback-latest.yml"))
j = w["jobs"]
assert j["window"]["name"] == "Cancel window" and "sleep 30" in str(j["window"]["steps"])
assert j["rollback"]["needs"] == "window"
PY
check "rollback-latest.yml: it runs publish-latest.sh with ALLOW_BACKWARDS, in publish-latest's concurrency group without cancelling, writes only on main, has no signing environment and never signs" python3 -I - "$here" <<'PY'
import sys, yaml
t = open(sys.argv[1] + "/.github/workflows/rollback-latest.yml").read()
w = yaml.safe_load(t); j = w["jobs"]["rollback"]
assert 'ALLOW_BACKWARDS: "true"' in t and ".github/scripts/publish-latest.sh" in t
assert j["concurrency"] == {"group": "publish-latest", "cancel-in-progress": False}
assert "github.ref == 'refs/heads/main'" in t and "environment" not in j
assert "cosign sign" not in t and "SIGNING_SECRET" not in t
assert j["permissions"] == {"contents": "read", "packages": "write"}
assert "inputs.default_only && 'vanilla-only' || 'both'" in t
PY
check "rollback-latest.yml: a failed (not dry-run) rollback on main opens or updates the ONE ci-failure-dx issue" python3 -I - "$here" <<'PY'
import sys, yaml
t = open(sys.argv[1] + "/.github/workflows/rollback-latest.yml").read()
w = yaml.safe_load(t); a = w["jobs"]["alert"]
c = " ".join(a["if"].split())
assert "needs.rollback.result == 'failure'" in c and "github.ref == 'refs/heads/main'" in c and "inputs.dry_run != true" in c
assert ".github/scripts/ci-issue.sh fail" in t and "LABEL" not in t, "the default label ci-failure-dx"
assert a["permissions"]["issues"] == "write"
PY
echo; echo "passed: $pass, failed: $failn"; [ "$failn" = 0 ]
