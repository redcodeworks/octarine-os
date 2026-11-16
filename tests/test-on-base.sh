#!/usr/bin/env bash
# Checks that the repository's tests run in the base the images are built on: test.yml (the required `test` check) on the stable base, build-beta.yml on the beta base,
# both through the shared test-suite action, with the digest resolved by base-pin.sh in a job of the same workflow. Run: tests/test-on-base.sh
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
python3 -I - "$here" <<'PY'
import re, sys, yaml
h = sys.argv[1]
load = lambda f: yaml.safe_load(open("%s/.github/workflows/%s.yml" % (h, f)))
t, b, beta = load("test"), load("build"), load("build-beta")
# the stable base: the defaults and the repository variables are those of build.yml (one place to change a Fedora major upgrade: the variables)
assert t["jobs"]["base"]["env"] == {"BASE_IMAGE": b["env"]["BASE_IMAGE"], "FEDORA_VERSION": b["env"]["FEDORA_VERSION"]}, (t["jobs"]["base"]["env"], b["env"])
assert t["jobs"]["test"]["container"] == "${{ needs.base.outputs.image }}"
assert t["jobs"]["test"]["name"] == "test"   # the required check name
# the beta base: the workflow env of build-beta.yml, resolved by the same script
assert beta["env"]["FEDORA_VERSION"] == "beta" and beta["env"]["BASE_IMAGE"].startswith("ghcr.io/ublue-os/silverblue-main")
bb = beta["jobs"]["tests"]
assert bb["container"] == "${{ needs.base.outputs.image }}" and bb["needs"] == "base"
assert "base-pin.sh" in "\n".join(s.get("run", "") for s in beta["jobs"]["base"]["steps"])
assert "tests" in beta["jobs"]["build"]["needs"], "the beta build must wait for its tests (a red test blocks the publish)"
for w, job in ((t, "test"), (beta, "tests")):
    assert any(s.get("uses") == "./.github/actions/test-suite" for s in w["jobs"][job]["steps"]), job
# no fixed image any more
for f in ("test", "build-beta"):
    assert "fedora:45" not in open("%s/.github/workflows/%s.yml" % (h, f)).read(), f
# the shared action: installs only what the base lacks, with the retry helper, and prints the versions
a = yaml.safe_load(open(h + "/.github/actions/test-suite/action.yml"))["runs"]["steps"]
run = "\n".join(s.get("run", "") for s in a)
assert "rpm -q" in run and ".github/scripts/retry.sh" in run and "niri --version" in run and "shellcheck --version" in run
names = [s["name"] for s in a]
assert names.index("Versions of the environment (read this first when a run is red)") < names.index("just check")
# base-pin.sh accepts the beta tag (it used to accept numbers only)
assert "|beta)" in open(h + "/.github/scripts/base-pin.sh").read()
print("tests run on the stable base (test.yml) and the beta base (build-beta.yml) through the shared test-suite action")
PY
