#!/usr/bin/env bash
# Checks that the repository's tests run in the base the images are built on: test.yml (the required `test` check) through the shared test-suite action, with the digest resolved by base-pin.sh in a job of the same workflow. Run: tests/test-on-base.sh
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
python3 -I - "$here" <<'PY'
import re, sys, yaml
h = sys.argv[1]
load = lambda f: yaml.safe_load(open("%s/.github/workflows/%s.yml" % (h, f)))
t, b = load("test"), load("build")
# the base: the defaults and the repository variables are those of build.yml (one place to change a Fedora major upgrade: the variables)
assert t["jobs"]["base"]["env"] == {"BASE_IMAGE": b["env"]["BASE_IMAGE"], "FEDORA_VERSION": b["env"]["FEDORA_VERSION"]}, (t["jobs"]["base"]["env"], b["env"])
assert t["jobs"]["test"]["container"] == "${{ needs.base.outputs.image }}"
assert t["jobs"]["test"]["name"] == "test"   # the required check name
assert any(s.get("uses") == "./.github/actions/test-suite" for s in t["jobs"]["test"]["steps"])
# no fixed image any more
assert "fedora:45" not in open("%s/.github/workflows/test.yml" % h).read()
# the shared action: installs only what the base lacks, with the retry helper, and prints the versions
a = yaml.safe_load(open(h + "/.github/actions/test-suite/action.yml"))["runs"]["steps"]
run = "\n".join(s.get("run", "") for s in a)
assert "rpm -q" in run and ".github/scripts/retry.sh" in run and "niri --version" in run and "shellcheck --version" in run
names = [s["name"] for s in a]
assert names.index("Versions of the environment (read this first when a run is red)") < names.index("just check")
print("tests run on the base the images are built on (test.yml) through the shared test-suite action")
PY
