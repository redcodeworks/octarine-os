"""The build-pipeline decisions: which jobs run, what is skipped, reused or promoted.

Covers aggregate-result, aggregate-dx, plan-build, plan-skip, plan-promote, plan-dx and inputs-hash (with
plan-vanilla-reuse). Registry answers come from stubs (skopeo, cosign, a lookup command); histories are real git
repositories. Assertions are on decisions, outputs and stub calls, never on message wording.
"""
from __future__ import annotations

import datetime as dt
import re
from pathlib import Path

import pytest

from conftest import SCRIPTS
from helpers.gitrepo import GitRepo
from helpers.stubs import FakeRegistry

# =====================================================================================================================
# aggregate-result and aggregate-dx: the result table of the required checks
# =====================================================================================================================

# (id, expected rc==0, plan, build_wanted, promote_wanted, publish, build, promote, sign)
AGG = [
    ("validation build (dispatch from a dev branch), nothing published", True, "success", "true", "false", "false", "success", "skipped", "skipped"),
    ("testing/main build published and signed", True, "success", "true", "false", "true", "success", "skipped", "success"),
    ("published but sign failed", False, "success", "true", "false", "true", "success", "skipped", "failure"),
    ("published but sign cancelled", False, "success", "true", "false", "true", "success", "skipped", "cancelled"),
    ("published but sign skipped", False, "success", "true", "false", "true", "success", "skipped", "skipped"),
    ("build failed", False, "success", "true", "false", "true", "failure", "skipped", "skipped"),
    ("docs-only plan", True, "success", "false", "false", "", "skipped", "skipped", "skipped"),
    ("docs-only plan but sign ran", False, "success", "false", "false", "", "skipped", "skipped", "success"),
    ("promote signed", True, "success", "false", "true", "", "skipped", "success", "success"),
    ("promote, sign failed", False, "success", "false", "true", "", "skipped", "success", "failure"),
    ("promote, sign skipped", False, "success", "false", "true", "", "skipped", "success", "skipped"),
    ("promote failed", False, "success", "false", "true", "", "skipped", "failure", "skipped"),
    ("plan failed", False, "failure", "", "", "", "skipped", "skipped", "skipped"),
    ("build and promote both ran", False, "success", "true", "false", "true", "success", "success", "success"),
]


@pytest.mark.security
@pytest.mark.parametrize("row", AGG, ids=[r[0] for r in AGG])
def test_aggregate_result_table(sandbox, row):
    """The required check `Build and push image`: anything published must be signed, a skipped sign job passes
    only when nothing was published.

    OLD: aggregate-result: validation build (dispatch from a dev branch), nothing published
    OLD: aggregate-result: testing/main build published and signed
    OLD: aggregate-result: published but sign failed
    OLD: aggregate-result: published but sign cancelled
    OLD: aggregate-result: published but sign skipped
    OLD: aggregate-result: build failed
    OLD: aggregate-result: docs-only plan
    OLD: aggregate-result: docs-only plan but sign ran
    OLD: aggregate-result: promote signed
    OLD: aggregate-result: promote, sign failed
    OLD: aggregate-result: promote, sign skipped
    OLD: aggregate-result: promote failed
    OLD: aggregate-result: plan failed
    OLD: aggregate-result: build and promote both ran
    """
    _, ok, plan, bw, pw, publish, build, promote, sign = row
    env = dict(PLAN=plan, BUILD_WANTED=bw, PROMOTE_WANTED=pw, PUBLISH=publish, BUILD=build, PROMOTE=promote, SIGN=sign)
    r = sandbox.bash(SCRIPTS / "aggregate-result.sh", env=env)
    assert (r.rc == 0) is ok, r.out + r.err


# (id, expected ok, plan, build, promote, sign, build_wanted, promote_wanted)
AGG_DX = [
    ("built and signed", True, "success", "success", "skipped", "success", "true", "false"),
    ("built, sign failed", False, "success", "success", "skipped", "failure", "true", "false"),
    ("build failed", False, "success", "failure", "skipped", "skipped", "true", "false"),
    ("build cancelled", False, "success", "cancelled", "skipped", "skipped", "true", "false"),
    ("promoted and verified", True, "success", "skipped", "success", "success", "false", "true"),
    ("promotion failed", False, "success", "skipped", "failure", "skipped", "false", "true"),
    ("promotion not verified", False, "success", "skipped", "success", "failure", "false", "true"),
    ("legitimate skip: nothing ran", True, "success", "skipped", "skipped", "skipped", "false", "false"),
    ("skip but something ran", False, "success", "success", "skipped", "success", "false", "false"),
    ("plan failed", False, "failure", "skipped", "skipped", "skipped", "", ""),
    ("plan cancelled", False, "cancelled", "skipped", "skipped", "skipped", "", ""),
    ("run dx is not built for (plan skipped)", True, "skipped", "skipped", "skipped", "skipped", "", ""),
    ("plan skipped but a job ran", False, "skipped", "success", "skipped", "skipped", "", ""),
]


@pytest.mark.security
@pytest.mark.parametrize("row", AGG_DX, ids=[r[0] for r in AGG_DX])
def test_aggregate_dx_table(sandbox, row):
    """The dx result check: built+signed, promoted+verified or a legitimate skip pass; a skipped plan passes
    only when nothing ran.

    OLD: plan-dx: aggregate: built and signed
    OLD: plan-dx: aggregate: built, sign failed
    OLD: plan-dx: aggregate: build failed
    OLD: plan-dx: aggregate: build cancelled
    OLD: plan-dx: aggregate: promoted and verified
    OLD: plan-dx: aggregate: promotion failed
    OLD: plan-dx: aggregate: promotion not verified
    OLD: plan-dx: aggregate: legitimate skip: nothing ran
    OLD: plan-dx: aggregate: skip but something ran
    OLD: plan-dx: aggregate: plan failed
    OLD: plan-dx: aggregate: plan cancelled
    OLD: plan-dx: aggregate: run dx is not built for (plan skipped)
    OLD: plan-dx: aggregate: plan skipped but a job ran
    """
    _, ok, plan, build, promote, sign, bw, pw = row
    env = dict(PLAN=plan, BUILD=build, PROMOTE=promote, SIGN=sign, BUILD_WANTED=bw, PROMOTE_WANTED=pw)
    r = sandbox.bash(SCRIPTS / "aggregate-dx.sh", env=env)
    assert (r.rc == 0) is ok, r.out + r.err


# =====================================================================================================================
# plan-build: is a push docs-only?
# =====================================================================================================================

ZERO = "0" * 40


@pytest.fixture(scope="module")
def build_history(tmp_path_factory):
    repo = GitRepo(tmp_path_factory.mktemp("plan-build"), "main")
    ids = {"base": repo.commit("base", **{"README.md": "a", "docs/a.txt": "a", "system_files/x": "a", "LICENSE": "a"})}
    ids["docs"] = repo.commit("docs", **{"README.md": "b", "docs/a.txt": "b", "CLAUDE.md": "b", ".gitignore": "b"})
    ids["deepdoc"] = repo.commit("deepdoc", **{"docs/sub/deep.png": "b"})
    ids["code"] = repo.commit("code", **{"system_files/x": "b"})
    ids["nested_md"] = repo.commit("nested-md", **{"system_files/sub/NOTE.md": "b"})
    ids["wf"] = repo.commit("wf", **{".github/workflows/w.yml": "b"})
    ids["tests"] = repo.commit("tests only", **{"tests/test_x.py": "b", "tests/helpers/y.py": "b"})
    ids["pyproject"] = repo.commit("pyproject", **{"pyproject.toml": "b"})
    ids["tests_and_code"] = repo.commit("tests and code", **{"tests/test_x.py": "c", "system_files/x": "c"})
    return repo, ids


# (id, event, before, after, expected stdout)
BUILD_ROWS = [
    ("docs only push", "push", "base", "docs", "false"),
    ("docs/** nested", "push", "docs", "deepdoc", "false"),
    ("non-docs file", "push", "deepdoc", "code", "true"),
    ("mixed range includes a non-docs file", "push", "base", "code", "true"),
    ("nested .md is not docs", "push", "code", "nested_md", "true"),
    ("workflow change", "push", "nested_md", "wf", "true"),
    ("all-zero before", "push", ZERO, "docs", "true"),
    ("empty before", "push", "", "docs", "true"),
    ("unknown before", "push", "1" * 40, "docs", "true"),
    ("empty diff", "push", "docs", "docs", "true"),
    ("schedule", "schedule", "base", "docs", "true"),
    ("workflow_dispatch", "workflow_dispatch", "base", "docs", "true"),
    # new with the test suite: tests and pyproject.toml are not image inputs
    ("tests only", "push", "wf", "tests", "false"),
    ("pyproject only", "push", "tests", "pyproject", "false"),
    ("tests together with code", "push", "pyproject", "tests_and_code", "true"),
]


@pytest.mark.parametrize("row", BUILD_ROWS, ids=[r[0] for r in BUILD_ROWS])
def test_plan_build_decision(sandbox, build_history, row):
    """Docs-only (and, since the pytest suite, tests-only) pushes skip the heavy build; anything else, an unusable
    base commit, a schedule or a dispatch builds.

    OLD: plan-build: docs only push
    OLD: plan-build: docs/** nested
    OLD: plan-build: non-docs file
    OLD: plan-build: mixed range includes a non-docs file
    OLD: plan-build: nested .md is not docs
    OLD: plan-build: workflow change
    OLD: plan-build: all-zero before
    OLD: plan-build: empty before
    OLD: plan-build: unknown before
    OLD: plan-build: empty diff
    OLD: plan-build: schedule
    OLD: plan-build: workflow_dispatch
    """
    repo, ids = build_history
    _, event, before, after, want = row
    r = sandbox.bash(SCRIPTS / "plan-build.sh", event, ids.get(before, before), ids[after], cwd=repo.path)
    assert r.rc == 0 and r.out.strip() == want, r.err


def test_plan_build_rejects_other_events(sandbox, build_history):
    """OLD: plan-build: pull_request is not an event of the build workflow"""
    repo, ids = build_history
    r = sandbox.bash(SCRIPTS / "plan-build.sh", "pull_request", ids["base"], ids["docs"], cwd=repo.path)
    assert r.rc != 0 and r.out.strip() == ""


# =====================================================================================================================
# plan-skip: may a scheduled run skip the build?
# =====================================================================================================================

NOW = int(dt.datetime(2026, 11, 8, 10, 5, tzinfo=dt.timezone.utc).timestamp())
SKIP_BASE = dict(EVENT="schedule", REF="refs/heads/main", BASE_NOW="sha256:aa", LATEST_BASE="sha256:aa", REPO_SAME="true",
                 LATEST_CREATED="2026-11-05T10:05:00Z", NOW_EPOCH=str(NOW), MAX_AGE_DAYS="7", SIGNED="true")

# (description, expected decision, overrides). Only the decision (skip or build) is the contract: each row changes
# exactly one input, so a decision of `build` proves that gate fired.
SKIP_ROWS = [
    ("all unchanged: skip", "skipped", {}),
    ("push event builds", "build", {"EVENT": "push"}),
    ("workflow_dispatch builds", "build", {"EVENT": "workflow_dispatch"}),
    ("testing ref builds", "build", {"REF": "refs/heads/testing"}),
    ("base changed builds", "build", {"BASE_NOW": "sha256:bb"}),
    ("label missing (old image) builds", "build", {"LATEST_BASE": ""}),
    ("base lookup failed builds", "build", {"BASE_NOW": ""}),
    ("repo changed builds", "build", {"REPO_SAME": "false"}),
    ("repo unknown builds", "build", {"REPO_SAME": ""}),
    ("8 days old builds", "build", {"LATEST_CREATED": "2026-10-31T10:05:00Z"}),
    ("exactly 7 days old builds", "build", {"LATEST_CREATED": "2026-11-01T10:05:00Z"}),
    ("6 days old skips", "skipped", {"LATEST_CREATED": "2026-11-02T10:05:01Z"}),
    ("unsigned builds", "build", {"SIGNED": "false"}),
    ("signature check failed builds", "build", {"SIGNED": ""}),
    ("no created date builds", "build", {"LATEST_CREATED": ""}),
    ("garbage date builds", "build", {"LATEST_CREATED": "garbage"}),
    ("age limit variable respected", "skipped", {"MAX_AGE_DAYS": "30", "LATEST_CREATED": "2026-10-20T10:05:00Z"}),
]


@pytest.mark.parametrize("row", SKIP_ROWS, ids=[r[0] for r in SKIP_ROWS])
def test_plan_skip_decision(sandbox, row):
    """A scheduled run on main skips only when base digest, repository content, age and signature are all
    unchanged; anything unknown builds (fail safe).

    OLD: plan-skip: all unchanged: skip
    OLD: plan-skip: push event builds
    OLD: plan-skip: workflow_dispatch builds
    OLD: plan-skip: testing ref builds
    OLD: plan-skip: base changed builds
    OLD: plan-skip: label missing (old image) builds
    OLD: plan-skip: base lookup failed builds
    OLD: plan-skip: repo changed builds
    OLD: plan-skip: repo unknown builds
    OLD: plan-skip: 8 days old builds
    OLD: plan-skip: exactly 7 days old builds
    OLD: plan-skip: 6 days old skips
    OLD: plan-skip: unsigned builds
    OLD: plan-skip: signature check failed builds
    OLD: plan-skip: no created date builds
    OLD: plan-skip: garbage date builds
    OLD: plan-skip: age limit variable respected
    """
    _, want, over = row
    r = sandbox.bash(SCRIPTS / "plan-skip.sh", env={**SKIP_BASE, **over})
    decision = r.out.split(":")[0].strip()
    assert decision == want, r.out


# =====================================================================================================================
# plan-promote: promote only a tested merge
# =====================================================================================================================

@pytest.fixture(scope="module")
def promote_history(tmp_path_factory):
    """base -> testing(code, docs tip) -> merge m1 on main; then variants of main for the negative cases."""
    r = GitRepo(tmp_path_factory.mktemp("plan-promote"), "main")
    ids = {}
    r.commit("base", **{"README.md": "a", "system_files/x": "a"})
    r.git("checkout", "-q", "-b", "testing")
    ids["code"] = r.commit("code", **{"system_files/x": "b"})
    ids["docs"] = r.commit("docs-only-tip", **{"README.md": "b"})
    r.git("checkout", "-q", "main")
    r.git("merge", "-q", "--no-ff", "-m", "merge", "testing")
    ids["m1"] = r.rev()
    ids["docs_main"] = r.commit("docs-on-main", **{"README.md": "c"})          # a non-merge push to main
    r.git("checkout", "-q", "-b", "testing2", ids["m1"])
    ids["t2"] = r.commit("code2", **{"system_files/x": "d"})
    r.git("checkout", "-q", "main")
    r.commit("main-extra", **{"system_files/y": "e"})                          # main has a code commit the tip lacks
    r.git("merge", "-q", "--no-ff", "-m", "merge2", "testing2")
    ids["m2"] = r.rev()
    r.git("checkout", "-q", "-B", "main", ids["m1"])
    r.git("checkout", "-q", "-b", "testing3", ids["m1"])
    ids["t3"] = r.commit("code3", **{"system_files/x": "f"})
    r.commit("docs3", **{"README.md": "g"})
    r.git("checkout", "-q", "main")
    r.git("merge", "-q", "--no-ff", "-m", "merge3", "testing3")
    ids["m3"] = r.rev()
    return r, ids


def _lookup_stub(stubs, tmp_path, tags):
    """REGISTRY_LOOKUP: prints a digest derived from the tag when the tag is in the file, else fails."""
    f = tmp_path / "tags"
    f.write_text("".join(t + "\n" for t in tags))
    stubs.add("lookup", script='grep -qx "$1" "$FAKE_TAGS" && echo "sha256:fake-$1"')
    return {"REGISTRY_LOOKUP": "lookup", "FAKE_TAGS": str(f)}


# (id, tags (keys into ids, as testing-<short>), event, ref, after, env overrides, expected promote, expected tag key)
PROMOTE_ROWS = [
    ("merge, equal tree, image for the tip", ["docs"], "push", "refs/heads/main", "m1", {}, "true", "docs"),
    ("docs-only tip, older image behind it", ["code"], "push", "refs/heads/main", "m1", {}, "true", "code"),
    ("no image found", [], "push", "refs/heads/main", "m1", {}, "false", None),
    ("schedule", ["code"], "schedule", "refs/heads/main", "m1", {}, "false", None),
    ("dispatch", ["code"], "workflow_dispatch", "refs/heads/main", "m1", {}, "false", None),
    ("testing branch push", ["code"], "push", "refs/heads/testing", "m1", {}, "false", None),
    ("PROMOTE_ENABLED unset", ["code"], "push", "refs/heads/main", "m1", {"PROMOTE_ENABLED": None}, "false", None),
    ("PROMOTE_ENABLED false", ["code"], "push", "refs/heads/main", "m1", {"PROMOTE_ENABLED": "false"}, "false", None),
    ("non-merge push", ["code"], "push", "refs/heads/main", "docs_main", {}, "false", None),
    ("merge, main has an extra code commit", ["t2"], "push", "refs/heads/main", "m2", {}, "false", None),
    ("image is older than a code change", ["code"], "push", "refs/heads/main", "m3", {}, "false", None),
    ("image of the code commit", ["t3"], "push", "refs/heads/main", "m3", {}, "true", "t3"),
]
PROMOTE_OLD = {
    "merge, equal tree, image for the tip": "merge, equal tree, image for the tip",
    "docs-only tip, older image behind it": "docs-only tip, older image behind it",
    "no image found": "no image found",
    "schedule": "schedule", "dispatch": "dispatch", "testing branch push": "testing branch push",
    "PROMOTE_ENABLED unset": "PROMOTE_ENABLED unset", "PROMOTE_ENABLED false": "PROMOTE_ENABLED false",
    "non-merge push": "non-merge push",
    "merge, main has an extra code commit": "merge, main has an extra code commit",
    "image is older than a code change": "image is older than a code change",
    "image of the code commit": "image of the code commit",
}


@pytest.mark.security
@pytest.mark.parametrize("row", PROMOTE_ROWS, ids=[r[0] for r in PROMOTE_ROWS])
def test_plan_promote_decision(sandbox, stubs, tmp_path, promote_history, row):
    """Promote (retag, no rebuild) only a push to main that merges a tested testing tip: equal default-image
    inputs on both sides, an image reachable without crossing a default-image change, promotion enabled.

    OLD: plan-promote: merge, equal tree, image for the tip
    OLD: plan-promote: docs-only tip, older image behind it
    OLD: plan-promote: no image found
    OLD: plan-promote: schedule
    OLD: plan-promote: dispatch
    OLD: plan-promote: testing branch push
    OLD: plan-promote: PROMOTE_ENABLED unset
    OLD: plan-promote: PROMOTE_ENABLED false
    OLD: plan-promote: non-merge push
    OLD: plan-promote: merge, main has an extra code commit
    OLD: plan-promote: image is older than a code change
    OLD: plan-promote: image of the code commit
    """
    repo, ids = promote_history
    _, tags, event, ref, after, over, want, tag_key = row
    env = {"PROMOTE_ENABLED": "true", **_lookup_stub(stubs, tmp_path, [f"testing-{repo.short(ids[k])}" for k in tags])}
    for k, v in over.items():
        if v is None:
            env.pop(k)
        else:
            env[k] = v
    r = sandbox.bash(SCRIPTS / "plan-promote.sh", event, ref, ids[after], cwd=repo.path, env=env)
    assert r.output("promote") == want, r.err
    if tag_key:
        assert r.output("source_tag") == f"testing-{repo.short(ids[tag_key])}"
        assert r.output("source_digest").startswith("sha256:")
    else:
        assert r.output("source_tag") == ""


# =====================================================================================================================
# inputs-hash and plan-vanilla-reuse
# =====================================================================================================================

BASE_FILES = {
    "system_files/x": "a", "variants/dx/f": "a", "variants/dx/system_files/g": "a",
    ".github/workflows/build-dx.yml": "a", ".github/workflows/build.yml": "a", ".github/scripts/dx-smoke.sh": "a",
    "tests/test_dx.py": "a", "tests/other.sh": "a", "README.md": "a", "docs/n.md": "a",
    "keys/redcodeworks-toolbox-cosign.pub": "a", "pyproject.toml": "a",
}
HASH = SCRIPTS / "inputs-hash.sh"


class Hashes:
    def __init__(self, sandbox, repo):
        self.sbx, self.repo = sandbox, repo

    def _h(self, kind, rev="HEAD"):
        r = self.sbx.bash(HASH, kind, rev, cwd=self.repo.path)
        assert r.rc == 0, r.err
        return r.out.strip()

    def v(self, rev="HEAD"):
        return self._h("vanilla", rev)

    def d(self, rev="HEAD"):
        return self._h("dx", rev)


@pytest.fixture
def hashes(sandbox, git_repo):
    repo = git_repo("hashrepo", "testing")
    repo.commit("base", BASE_FILES)
    return Hashes(sandbox, repo)


def test_hashes_are_stable_and_independent_of_history(hashes):
    """OLD: inputs-hash: stable: the same commit twice
    OLD: inputs-hash: stable: dx hash twice
    OLD: inputs-hash: independent of the commit id and message
    OLD: inputs-hash: hashes are 64 hex characters
    OLD: inputs-hash: the two hashes differ
    """
    repo = hashes.repo
    c0 = repo.rev()
    v0, d0 = hashes.v(), hashes.d()
    assert (hashes.v(), hashes.d()) == (v0, d0)
    repo.git("commit", "-q", "--amend", "-m", "other message", "--date", "2020-01-01T00:00:00")
    assert hashes.v() == v0 and hashes.v(c0) == v0
    assert re.fullmatch(r"[0-9a-f]{64}", v0) and re.fullmatch(r"[0-9a-f]{64}", d0)
    assert v0 != d0


# (id, files changed, vanilla changes, dx changes)
CHANGE_ROWS = [
    ("dx directory", {"variants/dx/f": "b"}, False, True),
    ("dx workflow, smoke script and key", {".github/workflows/build-dx.yml": "b", ".github/scripts/dx-smoke.sh": "b",
                                           "keys/redcodeworks-toolbox-cosign.pub": "b"}, False, True),
    ("docs only", {"README.md": "b", "docs/n.md": "b"}, False, False),
    ("tests are not image inputs", {"tests/other.sh": "b", "tests/test_dx.py": "b", "tests/new/deep.py": "b"}, False, False),
    ("pyproject.toml is not an image input", {"pyproject.toml": "b"}, False, False),
    ("default image file", {"system_files/x": "b"}, True, False),
    ("build.yml is a default image change", {".github/workflows/build.yml": "b"}, True, False),
    ("a new default image file", {"system_files/new": "c"}, True, False),
    ("nested markdown outside docs is an input", {"system_files/sub/NOTE.md": "c"}, True, False),
]


@pytest.mark.parametrize("row", CHANGE_ROWS, ids=[r[0] for r in CHANGE_ROWS])
def test_which_hash_a_change_moves(hashes, row):
    """A change moves the vanilla (default image) hash, the dx hash, or neither (docs, tests, pyproject).

    OLD: inputs-hash: dx-only change (variants/dx): vanilla_inputs equal
    OLD: inputs-hash: dx-only change: dx_inputs differ
    OLD: inputs-hash: dx workflow, smoke script, dx test and key: vanilla_inputs equal
    OLD: inputs-hash: docs-only change: vanilla_inputs equal
    OLD: inputs-hash: docs-only change: dx_inputs equal to the commit before
    OLD: inputs-hash: vanilla change: vanilla_inputs differ
    OLD: inputs-hash: vanilla change: dx_inputs equal
    OLD: inputs-hash: a change to build.yml is a vanilla change
    OLD: inputs-hash: a new vanilla file changes vanilla_inputs
    """
    _, files, v_moves, d_moves = row
    v0, d0 = hashes.v(), hashes.d()
    hashes.repo.commit("change", files)
    assert (hashes.v() != v0) is v_moves
    assert (hashes.d() != d0) is d_moves


def test_rename_inside_dx_dir_moves_only_dx(hashes):
    """OLD: inputs-hash: renaming inside variants/dx leaves vanilla_inputs equal
    OLD: inputs-hash: ...and changes dx_inputs
    """
    v0, d0 = hashes.v(), hashes.d()
    hashes.repo.git("mv", "variants/dx/f", "variants/dx/f2")
    hashes.repo.commit("rename")
    assert hashes.v() == v0 and hashes.d() != d0


def _dx_only(sandbox, path):
    r = sandbox.run(["bash", "-c", f'source "{HASH}"; is_dx_only "$1"', "x", path])
    return r.rc == 0


def _is_docs(sandbox, path):
    r = sandbox.run(["bash", "-c", f'source "{SCRIPTS / "docs-only.sh"}"; is_docs "$1"', "x", path])
    return r.rc == 0


def test_dx_only_list_names_existing_files(sandbox, repo_root):
    """Every literal path of is_dx_only exists (a rename must update the list) and is classified dx-only; files of
    the default image are not.

    OLD: inputs-hash: dx-only path exists: *
    OLD: inputs-hash: is_dx_only *
    OLD: inputs-hash: default-image files are not dx-only
    """
    src = HASH.read_text()
    body = src[src.index("is_dx_only() {"):src.index("# <kind> <rev>")]
    literals = [p for arm in re.findall(r"^\s+([^\n]*?)\) return 0 ;;", body, re.M) for p in arm.split(" | ") if "*" not in p]
    assert literals, "parsed no literal paths out of is_dx_only"
    for p in literals:
        assert (repo_root / p).is_file(), f"is_dx_only names a missing file: {p}"
        assert _dx_only(sandbox, p), p
    for p in (".github/workflows/build.yml", "Justfile", "build_files/build.sh", "Containerfile", "tests/test_plan.py"):
        assert not _dx_only(sandbox, p), p
    assert _dx_only(sandbox, "variants/dx/anything/at/all")


def test_tests_and_pyproject_are_not_image_inputs(sandbox, repo_root):
    """The files of the test suite never rebuild an image: tests/** and pyproject.toml are listed with the docs
    (the shell tests used to be vanilla inputs, five of them dx-only inputs).

    OLD: inputs-hash: a test file is not an image input (tests/** is listed with the docs)
    OLD: inputs-hash: ...and not a dx input either
    """
    for p in ("tests/test_plan.py", "tests/helpers/stubs.py", "tests/aggregate-result.sh", "pyproject.toml"):
        assert _is_docs(sandbox, p), p
    for p in ("Containerfile", "build_files/build.sh", "system_files/etc/x", ".github/workflows/test.yml", "Justfile"):
        assert not _is_docs(sandbox, p), p
    # whatever the shell tests were, the real tests directory contributes nothing to either hash
    listed = sandbox.run(["git", "ls-files", "tests", "pyproject.toml"], cwd=repo_root).out.split()
    assert listed and all(_is_docs(sandbox, p) and not _dx_only(sandbox, p) for p in listed)


def test_inputs_hash_usage_and_unknown_revision(sandbox, hashes):
    """OLD: inputs-hash: unknown kind: usage, exit 2
    OLD: inputs-hash: unknown revision fails
    """
    assert sandbox.bash(HASH, "sideways", cwd=hashes.repo.path).rc == 2
    assert sandbox.bash(HASH, "vanilla", "nosuchrev", cwd=hashes.repo.path).rc != 0


# ---- plan-vanilla-reuse: a push to testing; the registry holds testing-<sha> for the tags in the table

@pytest.fixture(scope="module")
def reuse_history(tmp_path_factory):
    r = GitRepo(tmp_path_factory.mktemp("reuse"), "testing")
    r.commit("base", BASE_FILES)
    c0 = r.rev()
    r.git("checkout", "-q", "-b", "t2", c0)
    ids = {"c0": c0}
    ids["img"] = r.commit("imagecommit", **{"system_files/x": "x"})
    ids["dxonly"] = r.commit("dxonly", **{"variants/dx/f": "y"})
    ids["docsonly"] = r.commit("docsonly", **{"README.md": "y"})
    ids["testsonly"] = r.commit("testsonly", **{"tests/test_dx.py": "y"})
    ids["vanilla"] = r.commit("vanillachange", **{"system_files/x": "y"})
    r.git("checkout", "-q", "-b", "t3", ids["img"])
    ids["dxonly2"] = r.commit("dxonly2", **{"variants/dx/f": "z"})
    r.git("checkout", "-q", "-b", "t4", ids["img"])
    r.commit("v2", **{"system_files/x": "q"})
    ids["d3"] = r.commit("d3", **{"variants/dx/f": "r"})
    r.git("checkout", "-q", "-b", "t5", ids["img"])
    ids["d5"] = r.commit("d5", **{"variants/dx/f": "s"})
    r.git("checkout", "-q", "-B", "main", ids["img"])
    r.git("merge", "-q", "--no-ff", "-m", "merge t5", "t5")
    ids["merge"] = r.rev()
    return r, ids


# (id, tags, after, event, ref, expected reuse, tag key)
REUSE_ROWS = [
    ("the commit itself has an image (re-run)", ["img"], "img", "push", "refs/heads/testing", "true", "img"),
    ("dx-only change on top of a published image", ["img"], "dxonly", "push", "refs/heads/testing", "true", "img"),
    ("docs-only change on top of that", ["img"], "docsonly", "push", "refs/heads/testing", "true", "img"),
    ("tests-only change on top of that", ["img"], "testsonly", "push", "refs/heads/testing", "true", "img"),
    ("vanilla change: build", ["img"], "vanilla", "push", "refs/heads/testing", "false", None),
    ("dx-only change but no image published: build (first run)", [], "dxonly2", "push", "refs/heads/testing", "false", None),
    ("event schedule", ["img"], "dxonly2", "schedule", "refs/heads/testing", "false", None),
    ("event dispatch", ["img"], "dxonly2", "workflow_dispatch", "refs/heads/testing", "false", None),
    ("push to main (promotion has its own script)", ["img"], "dxonly2", "push", "refs/heads/main", "false", None),
    ("push to a feature branch", ["img"], "dxonly2", "push", "refs/heads/feat/x", "false", None),
    ("an image exists only behind a vanilla change: build", ["img"], "d3", "push", "refs/heads/testing", "false", None),
]


@pytest.mark.parametrize("row", REUSE_ROWS, ids=[r[0] for r in REUSE_ROWS])
def test_plan_vanilla_reuse_decision(sandbox, stubs, tmp_path, reuse_history, row):
    """A push to testing reuses the nearest published image when the default-image inputs are equal; a default-image
    change in between, a missing image or another event builds.

    OLD: inputs-hash: reuse: the commit itself has an image (re-run)
    OLD: inputs-hash: reuse: dx-only change on top of a published image
    OLD: inputs-hash: reuse: docs-only change on top of that
    OLD: inputs-hash: reuse: vanilla change: build
    OLD: inputs-hash: reuse: dx-only change but no image published: build (first run)
    OLD: inputs-hash: reuse: event schedule
    OLD: inputs-hash: reuse: event dispatch
    OLD: inputs-hash: reuse: push to main (promotion has its own script)
    OLD: inputs-hash: reuse: push to a feature branch
    OLD: inputs-hash: reuse: an image exists only behind a vanilla change: build
    """
    repo, ids = reuse_history
    _, tags, after, event, ref, want, tag_key = row
    env = _lookup_stub(stubs, tmp_path, [f"testing-{repo.short(ids[k])}" for k in tags])
    r = sandbox.bash(SCRIPTS / "plan-vanilla-reuse.sh", event, ref, ids[after], cwd=repo.path, env=env)
    assert r.output("reuse") == want, r.err
    assert r.output("source_tag") == (f"testing-{repo.short(ids[tag_key])}" if tag_key else "")


def test_reuse_output_carries_the_vanilla_inputs(sandbox, stubs, tmp_path, reuse_history):
    """OLD: inputs-hash: the output carries the vanilla_inputs of the commit"""
    repo, ids = reuse_history
    env = _lookup_stub(stubs, tmp_path, [])
    r = sandbox.bash(SCRIPTS / "plan-vanilla-reuse.sh", "push", "refs/heads/testing", ids["d3"], cwd=repo.path, env=env)
    h = sandbox.bash(HASH, "vanilla", ids["d3"], cwd=repo.path)
    assert r.output("inputs") == h.out.strip() != ""


@pytest.mark.security
def test_promote_of_a_dx_only_tip_promotes_the_default_image_behind_it(sandbox, stubs, tmp_path, reuse_history):
    """OLD: inputs-hash: promote: a dx-only testing tip promotes the default image behind it"""
    repo, ids = reuse_history
    env = {"PROMOTE_ENABLED": "true", **_lookup_stub(stubs, tmp_path, [f"testing-{repo.short(ids['img'])}"])}
    r = sandbox.bash(SCRIPTS / "plan-promote.sh", "push", "refs/heads/main", ids["merge"], cwd=repo.path, env=env)
    assert r.output("promote") == "true"
    assert r.output("source_tag") == f"testing-{repo.short(ids['img'])}"


# =====================================================================================================================
# plan-dx: skip, promote or build per channel (stub registry: skopeo + cosign)
# =====================================================================================================================

DX_PLAN = SCRIPTS / "plan-dx.sh"
OWNER = "ghcr.io/redcodeworks"


class Dx:
    """A dx plan scenario: a three-commit repo (the last commit touches only dx files), a fake registry and `plan`."""

    def __init__(self, sandbox, repo, reg):
        self.sbx, self.repo, self.reg = sandbox, repo, reg
        self.out_file = sandbox.tmp / "gh-output"
        self.inputs = sandbox.bash(HASH, "dx", "HEAD", cwd=repo.path).out.strip()
        self.sha7, self.older7 = repo.short("HEAD"), repo.short("HEAD~1")
        self.third7 = repo.short("HEAD~2")
        d = FakeRegistry.digest
        self.bt = "sha256:" + d(f"{OWNER}/octarine-os:testing-{self.sha7}")   # base of the testing build of this commit
        self.bf = "sha256:" + d(f"{OWNER}/octarine-os:testing")               # the floating testing tag
        self.bl = "sha256:" + d(f"{OWNER}/octarine-os:latest")
        self.bb = "sha256:" + d(f"{OWNER}/octarine-os:beta")
        self.older = "sha256:" + d(f"{OWNER}/octarine-os:testing-{self.older7}")
        self.other = "sha256:" + "a" * 64

    def dxd(self, tag, name="octarine-os-dx"):
        return FakeRegistry.digest(f"{OWNER}/{name}:{tag}")

    def plan(self, channel, force=False, **env):
        self.out_file.write_text("")
        env = {"CHANNEL": channel, "FORCE": "true" if force else "false", "GITHUB_REPOSITORY_OWNER": "RedCodeWorks",
               "GITHUB_OUTPUT": str(self.out_file), **env}
        self.r = self.sbx.bash(DX_PLAN, cwd=self.repo.path, env=env)
        self.out = dict(l.split("=", 1) for l in self.out_file.read_text().splitlines() if "=" in l)
        return self

    @property
    def decision(self):
        return (self.out.get("build"), self.out.get("promote"), self.out.get("source_tag"))

    @property
    def warned(self):
        return any(l.startswith("::warning::") for l in self.r.out.splitlines())


@pytest.fixture
def dx(sandbox, stubs, git_repo):
    repo = git_repo("dxrepo", "testing")
    repo.commit("one", {"variants/dx/f": "a", "x": "a"})
    repo.commit("two", {"x": "b"})
    repo.commit("three (dx only)", {"variants/dx/f": "c"})
    return Dx(sandbox, repo, FakeRegistry(stubs))


def test_dx_testing_base_is_the_immutable_tag_of_the_commit(dx):
    """With nothing published the dx build is wanted, on the base testing-<sha7> of the commit (the digest of its
    raw manifest, not the floating testing tag's), and the dx inputs of the commit are passed on.

    OLD: plan-dx: testing, first run (nothing published): build
    OLD: plan-dx: testing builds on octarine-os:testing-<sha7> of the commit, not the floating testing tag (digest of the raw manifest)
    OLD: plan-dx: the dx inputs of the commit are passed on
    OLD: plan-dx: testing, dx image unreadable: build
    """
    p = dx.plan("testing")
    assert p.decision == ("true", "false", "")
    assert p.out["base_tag"] == f"testing-{dx.sha7}" and p.out["base_digest"] == dx.bt != dx.bf
    assert p.out["dx_inputs"] == dx.inputs


# (id, testing labels (base key, inputs key) or None, force, expected build)
DX_TESTING_ROWS = [
    ("same base digest and dx inputs: skip", ("bt", "inputs"), False, "false"),
    ("dx inputs changed (dx-only change): build", ("bt", "different"), False, "true"),
    ("vanilla base changed (vanilla-only change): build", ("other", "inputs"), False, "true"),
    ("both changed: build", ("other", "different"), False, "true"),
    ("force builds", ("bt", "inputs"), True, "true"),
    ("nothing published: build", None, False, "true"),
]


@pytest.mark.parametrize("row", DX_TESTING_ROWS, ids=[r[0] for r in DX_TESTING_ROWS])
def test_dx_testing_channel_decision(dx, row):
    """testing: skip only when both labels equal the base digest and dx inputs; never promote.

    OLD: plan-dx: testing, same base digest and dx inputs: skip
    OLD: plan-dx: testing, dx inputs changed (dx-only change): build
    OLD: plan-dx: testing, vanilla base changed (vanilla-only change): build
    OLD: plan-dx: testing, both changed: build
    OLD: plan-dx: testing, force: build
    OLD: plan-dx: the skip notice is printed
    """
    _, labels, force, build = row
    if labels:
        base = {"bt": dx.bt, "other": dx.other}[labels[0]]
        dx.reg.config("testing", base, {"inputs": dx.inputs, "different": "different"}[labels[1]])
    p = dx.plan("testing", force=force)
    assert p.decision == (build, "false", "")
    if build == "false":
        assert any(l.startswith("::notice::") for l in p.r.out.splitlines())


def test_dx_testing_reads_only_the_testing_tag(dx, stubs):
    """OLD: plan-dx: testing never promotes and reads only the testing tag"""
    dx.reg.config("testing", dx.bt, dx.inputs)
    dx.reg.config("latest", dx.other, "different")          # would force a build if it were consulted
    p = dx.plan("testing")
    assert p.decision == ("false", "false", "")
    asked = [c for c in stubs["skopeo"].calls if "--config" in c]
    assert asked and all(c[-1].endswith(":testing") for c in asked)


def test_dx_testing_base_walks_back_when_the_default_build_was_reused(dx):
    """No octarine-os:testing-<sha7> for the commit (its default build was reused): the base is the nearest earlier
    testing-<sha> built from the same default-image inputs; the dx image on that base is skipped.

    OLD: plan-dx: testing, reused default build: build on the nearest earlier testing-<sha>
    OLD: plan-dx: ...the base is testing-<sha7> of the nearest commit with the same default-image inputs
    OLD: plan-dx: testing, reused default build, dx image on that base: skip
    """
    dx.reg.missing(f"{OWNER}/octarine-os:testing-{dx.sha7}")
    p = dx.plan("testing")
    assert p.decision == ("true", "false", "")
    assert p.out["base_tag"] == f"testing-{dx.older7}" and p.out["base_digest"] == dx.older
    dx.reg.config("testing", dx.older, dx.inputs)
    assert dx.plan("testing").decision == ("false", "false", "")


def test_dx_testing_falls_back_to_the_floating_tag_with_a_warning(dx):
    """OLD: plan-dx: testing, no usable testing-<sha> (a default-image change in between): build
    OLD: plan-dx: ...falls back to the floating testing tag
    OLD: plan-dx: ...and says so
    """
    dx.reg.missing(*[f"{OWNER}/octarine-os:testing-{s}" for s in (dx.sha7, dx.older7, dx.third7)])
    p = dx.plan("testing")
    assert p.decision == ("true", "false", "")
    assert p.out["base_tag"] == "testing" and p.out["base_digest"] == dx.bf
    assert p.warned


@pytest.mark.security
def test_dx_promotion_sequence_shares_one_digest(dx):
    """testing build, then the default promote retags testing-<sha7> to latest: the dx plan on latest finds the
    tested dx image because latest and the recorded base are one digest. When latest only equals the floating
    tag the promotion never matches (the bug this sequence guards).

    OLD: plan-dx: step 1, dx plan on testing: build
    OLD: plan-dx: step 3, dx plan on latest after the default promote: promote the tested dx image
    OLD: plan-dx: ...latest and the base the dx testing image was built on share one digest
    OLD: plan-dx: contrast: latest equal to the floating tag only, not to testing-<sha7>: no promotion (the bug)
    """
    assert dx.plan("testing").decision == ("true", "false", "")
    built_on = dx.out["base_digest"]
    dx.reg.config("testing", built_on, dx.out["dx_inputs"])
    dx.reg.alias(f"{OWNER}/octarine-os:latest", f"{OWNER}/octarine-os:testing-{dx.sha7}")
    p = dx.plan("latest")
    assert p.decision == ("false", "true", "testing")
    assert p.out["base_digest"] == built_on
    dx.reg.clear_alias()
    dx.reg.alias(f"{OWNER}/octarine-os:latest", f"{OWNER}/octarine-os:testing")
    assert dx.plan("latest").decision == ("true", "false", "")


def _setup_latest(dx, row):
    reg = dx.reg
    key = {"bl": dx.bl, "other": dx.other}
    for tag, (base, inputs) in row.get("configs", {}).items():
        reg.config(tag, key[base], dx.inputs if inputs == "inputs" else inputs)
    reg.unsigned(*[f"{OWNER}/octarine-os-dx@sha256:{dx.dxd(t)}" for t in row.get("unsigned", [])])


# (id, setup, force, expected (build, promote, tag), expects a warning)
DX_LATEST_ROWS = [
    ("nothing published, no testing image: build", {}, False, ("true", "false", ""), False),
    ("same base and dx inputs: skip", {"configs": {"latest": ("bl", "inputs")}}, False, ("false", "false", ""), False),
    ("same base and inputs but the published image is NOT signed: build, never skip",
     {"configs": {"latest": ("bl", "inputs")}, "unsigned": ["latest"]}, False, ("true", "false", ""), True),
    ("old base, no testing image: build", {"configs": {"latest": ("other", "inputs")}}, False, ("true", "false", ""), False),
    ("tested testing image with the same base and dx inputs: promote",
     {"configs": {"latest": ("other", "inputs"), "testing": ("bl", "inputs")}}, False, ("false", "true", "testing"), False),
    ("testing image on another base digest: build", {"configs": {"testing": ("other", "inputs")}}, False, ("true", "false", ""), False),
    ("testing image with other dx inputs: build", {"configs": {"testing": ("bl", "different")}}, False, ("true", "false", ""), False),
    ("match found by testing-<sha> of an older commit: promote that tag",
     {"configs": {"testing-OLDER": ("bl", "inputs")}}, False, ("false", "true", "testing-OLDER"), False),
    ("matching testing image but unsigned: build, not promoted",
     {"configs": {"testing": ("bl", "inputs")}, "unsigned": ["testing"]}, False, ("true", "false", ""), True),
    ("force builds even with a promotable image", {"configs": {"testing": ("bl", "inputs")}}, True, ("true", "false", ""), False),
    ("force builds although unchanged", {"configs": {"latest": ("bl", "inputs")}}, True, ("true", "false", ""), False),
    ("published image without the dx-inputs label: not a skip, promotes the tested one",
     {"configs": {"latest": ("bl", "-"), "testing": ("bl", "inputs")}}, False, ("false", "true", "testing"), False),
]


@pytest.mark.security
@pytest.mark.parametrize("row", DX_LATEST_ROWS, ids=[r[0] for r in DX_LATEST_ROWS])
def test_dx_latest_channel_decision(dx, row):
    """latest: skip when both labels match and the published image verifies; else promote a tested, signed testing
    image with the same labels; else build. Force and every lookup that fails build, never skip.

    OLD: plan-dx: latest, nothing published, no testing image: build
    OLD: plan-dx: latest, same base and dx inputs: skip
    OLD: plan-dx: latest, same base and inputs but the published image is NOT signed (a cancelled run): build, never skip
    OLD: plan-dx: the unsigned skip candidate is named in a warning
    OLD: plan-dx: latest, old base, no testing image: build
    OLD: plan-dx: latest, tested testing image with the same base and dx inputs: promote
    OLD: plan-dx: the promoted digest is the raw manifest digest of the testing tag
    OLD: plan-dx: latest, testing image on another base digest: build
    OLD: plan-dx: latest, testing image with other dx inputs: build
    OLD: plan-dx: latest, match found by testing-<sha> of an older commit: promote that tag
    OLD: plan-dx: latest, matching testing image but unsigned: build, not promoted
    OLD: plan-dx: ...with a warning
    OLD: plan-dx: latest, force builds even with a promotable image
    OLD: plan-dx: latest, force builds although unchanged
    OLD: plan-dx: latest, published image without the dx-inputs label: not a skip, promotes the tested one
    """
    _, setup, force, want, warns = row
    setup = {**setup, "configs": {k.replace("OLDER", dx.older7): v for k, v in setup.get("configs", {}).items()}}
    _setup_latest(dx, setup)
    want = tuple(w.replace("OLDER", dx.older7) for w in want)
    p = dx.plan("latest", force=force)
    assert p.decision == want, p.r.out
    assert p.warned is warns
    if want[1] == "true":
        assert p.out["source_digest"] == "sha256:" + dx.dxd(want[2])


def test_dx_beta_never_promotes(dx):
    """OLD: plan-dx: beta never promotes: build
    OLD: plan-dx: beta builds on octarine-os:beta
    OLD: plan-dx: beta, unchanged: skip
    """
    dx.reg.config("testing", dx.bb, dx.inputs)
    p = dx.plan("beta")
    assert p.decision == ("true", "false", "")
    assert p.out["base_tag"] == "beta" and p.out["base_digest"] == dx.bb
    dx.reg.config("beta", dx.bb, dx.inputs)
    assert dx.plan("beta").decision == ("false", "false", "")


NVIDIA_ENV = dict(BASE_NAME="octarine-os-nvidia", DX_NAME="octarine-os-nvidia-dx", PROMOTE_FROM_TESTING="false")


# (id, label setup (base key, inputs), tag, force, expected build)
NV_ROWS = [
    ("nothing published: build", None, "latest", False, "true"),
    ("same NVIDIA base digest and dx inputs: skip", ("nv", "inputs"), "latest", False, "false"),
    ("a new NVIDIA base digest: build", ("old", "inputs"), "latest", False, "true"),
    ("changed dx inputs: build", ("nv", "other"), "latest", False, "true"),
    ("force builds", ("nv", "other"), "latest", True, "true"),
    ("a matching testing tag is never promoted (no testing channel): build", ("nv", "inputs"), "testing", False, "true"),
]


@pytest.mark.parametrize("row", NV_ROWS, ids=[r[0] for r in NV_ROWS])
def test_nvidia_dx_plan(dx, stubs, row):
    """The NVIDIA dx image builds on octarine-os-nvidia:latest, skips on equal base digest and dx inputs, has no
    testing channel, and never looks at the default image.

    OLD: plan-dx: nvidia-dx: nothing published: build
    OLD: plan-dx: nvidia-dx builds on octarine-os-nvidia:latest
    OLD: plan-dx: nvidia-dx: same NVIDIA base digest and dx inputs: skip
    OLD: plan-dx: nvidia-dx: a new NVIDIA base digest: build
    OLD: plan-dx: nvidia-dx: changed dx inputs: build
    OLD: plan-dx: nvidia-dx: force builds
    OLD: plan-dx: nvidia-dx: a matching testing tag is never promoted (no testing channel): build
    OLD: plan-dx: nvidia-dx: the registry is not even asked for a testing image
    OLD: plan-dx: nvidia-dx: the default image is never the base
    """
    _, labels, tag, force, build = row
    nv = "sha256:" + FakeRegistry.digest(f"{OWNER}/octarine-os-nvidia:latest")
    if labels:
        base = {"nv": nv, "old": "sha256:old"}[labels[0]]
        dx.reg.config(tag, base, dx.inputs if labels[1] == "inputs" else "other")
    p = dx.plan("latest", force=force, **NVIDIA_ENV)
    assert p.decision == (build, "false", "")
    assert p.out["base_tag"] == "latest" and p.out["base_digest"] == nv
    refs = [c[-1] for c in stubs["skopeo"].calls]
    assert not any("octarine-os-nvidia-dx:testing" in x for x in refs)
    assert not any(re.search(r"/octarine-os:", x) for x in refs)


def test_dx_plan_failures(dx):
    """OLD: plan-dx: an unsigned base fails the job
    OLD: plan-dx: an unknown channel fails the job
    """
    dx.reg.fail_base_signature()
    assert dx.plan("latest").r.rc != 0
    assert dx.plan("sideways").r.rc != 0
