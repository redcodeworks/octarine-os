#!/usr/bin/env bash
# Checks the `alert` jobs that turn a failed scheduled build into ONE issue (ci-issue.sh, deduplicated on the label): the default build, the beta and
# NVIDIA builds and the weekly prune. A cancelled run raises nothing and closes nothing. Run: tests/alert-jobs.sh
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
python3 -I - "$here" <<'PY'
import sys, yaml
h = sys.argv[1]
labels = {}
for f, main in (("build", "build_result"), ("build-beta", "sign"), ("build-nvidia", "sign"), ("prune-testing", "prune")):
    w = yaml.safe_load(open("%s/.github/workflows/%s.yml" % (h, f)))
    a = w["jobs"]["alert"]
    assert a["permissions"] == {"contents": "read", "issues": "write"}, (f, a["permissions"])
    assert "always()" in a["if"] and "github.ref == 'refs/heads/main'" in a["if"], (f, a["if"])
    needs = a["needs"] if isinstance(a["needs"], list) else [a["needs"]]
    assert main in needs and all(n in w["jobs"] for n in needs), (f, needs)
    fail = next(s for s in a["steps"] if "ci-issue.sh fail" in s.get("run", ""))
    rec = next(s for s in a["steps"] if "ci-issue.sh recover" in s.get("run", ""))
    assert fail["if"] == "contains(needs.*.result, 'failure')", fail["if"]
    assert "needs.%s.result == 'success'" % main in rec["if"] and "!contains(needs.*.result, 'cancelled')" in rec["if"] and "!contains(needs.*.result, 'failure')" in rec["if"], rec["if"]
    for s in (fail, rec):
        assert s["env"]["LABEL"].startswith("ci-failure-") and "GH_TOKEN" in s["env"] and "SHA" in s["env"], (f, s)
        assert "${{" not in s["run"], f
    assert fail["env"]["ISSUE_TITLE"] and fail["env"]["ISSUE_BODY"] and fail["env"]["LABEL_DESC"] and fail["env"]["FAIL_COMMENT"] and rec["env"]["RECOVER_COMMENT"], f
    assert fail["env"]["LABEL"] == rec["env"]["LABEL"], f
    labels[f] = fail["env"]["LABEL"]
assert len(set(labels.values())) == len(labels), labels  # one label (one open issue) per workflow
for f in ("build-dx", "publish-latest", "rollback-latest"):
    t = open("%s/.github/workflows/%s.yml" % (h, f)).read()
    assert "ci-issue.sh fail" in t, f
print("alert jobs: %s" % labels)
PY
