#!/usr/bin/env bash
# Checks .github/zizmor.yml (ignores name FILES, never file:line:col: line numbers shift with every edit) and .github/dependabot.yml (covers the composite
# actions, keeps the cooldown and the testing target). Run: tests/zizmor-config.sh
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
python3 -I - "$here" <<'PY'
import os, re, sys, yaml
h = sys.argv[1]
z = yaml.safe_load(open(h + "/.github/zizmor.yml"))
bad = []
for rule, cfg in z["rules"].items():
    for ig in cfg.get("ignore", []):
        if re.search(r":\d+(:\d+)?$", str(ig)):
            bad.append("%s: %s is a line based ignore" % (rule, ig))
            continue
        found = [d for d in (".github/workflows", ".github/actions") for r, _, fs in os.walk(os.path.join(h, d)) if ig in fs]
        if not found:
            bad.append("%s: %s matches no workflow or action file" % (rule, ig))
assert not bad, bad
d = yaml.safe_load(open(h + "/.github/dependabot.yml"))
u = [x for x in d["updates"] if x["package-ecosystem"] == "github-actions"]
assert len(u) == 1, u
u = u[0]
assert "directory" not in u and "/" in u["directories"], u
for name in os.listdir(h + "/.github/actions"):
    if os.path.exists("%s/.github/actions/%s/action.yml" % (h, name)):
        assert "/.github/actions/%s" % name in u["directories"], name
assert u["target-branch"] == "testing" and u["cooldown"]["default-days"] >= 7, u
print("zizmor ignores name files that exist; dependabot covers the workflows and every composite action")
PY
