"""The decision scripts that are pure functions of their environment or arguments: plan_skip, plan_build, the aggregate results, the channel-neutral version check."""

import subprocess
import sys

import pytest

import ci
from conftest import SCRIPTS, git, make_repo, script

NOW = ci.epoch("2026-11-08T10:05:00Z")
SKIP_ENV = {
    "EVENT": "schedule",
    "REF": "refs/heads/main",
    "BASE_NOW": "sha256:aa",
    "LATEST_BASE": "sha256:aa",
    "REPO_SAME": "true",
    "LATEST_CREATED": "2026-11-05T10:05:00Z",
    "NOW_EPOCH": str(NOW),
    "MAX_AGE_DAYS": "7",
    "SIGNED": "true",
    "LATEST_MISSING": "none",
}


@pytest.mark.parametrize(
    "override, want",
    [
        ({}, "skipped: base, repo and age unchanged"),
        ({"EVENT": "push"}, "build: not a scheduled run"),
        ({"EVENT": "workflow_dispatch"}, "build: not a scheduled run"),
        ({"REF": "refs/heads/testing"}, "build: not main"),
        ({"BASE_NOW": "sha256:bb"}, "build: base image changed"),
        ({"BASE_NOW": ""}, "build: base digest unknown"),
        ({"REPO_SAME": "false"}, "build: repository content differs"),
        ({"LATEST_CREATED": ""}, "build: age of latest unknown"),
        ({"LATEST_CREATED": "garbage"}, "build: cannot read created date"),
        ({"LATEST_CREATED": "2026-10-01T00:00:00Z"}, "build: latest is 38 days old"),
        ({"MAX_AGE_DAYS": "x"}, "build: MAX_AGE_DAYS is not a number"),
        ({"SIGNED": "false"}, "build: latest is not verified as signed"),
        ({"LATEST_MISSING": "zsh,fish"}, "build: latest was built with optional packages missing"),
        ({"LATEST_MISSING": ""}, "skipped"),  # an image from before the label skips as before
    ],
)
def test_plan_skip(override, want):
    p = script("plan_skip.py", env={k: "" for k in SKIP_ENV}, extra={**SKIP_ENV, **override})
    assert p.stdout.startswith(want), p.stdout


def push_repo(tmp_path, *changes):
    """A repository with a base commit and one commit per entry of `changes` (a list of file names); returns (repo, [commit ids]) with the base first."""
    repo = tmp_path / "r"
    ids = make_repo(repo, "base")
    (repo / "docs").mkdir()
    for name in changes:
        (repo / name).parent.mkdir(parents=True, exist_ok=True)
        (repo / name).write_text("x\n")
        git(repo, "add", "-A")
        git(repo, "commit", "-qm", name)
        ids.append(git(repo, "rev-parse", "HEAD"))
    return repo, ids


@pytest.mark.parametrize(
    "event, changed, ref, want",
    [
        ("schedule", "README.md", "", "true"),
        ("workflow_dispatch", "README.md", "", "true"),
        ("push", "system_files/x", "refs/heads/main", "true"),
        ("push", "README.md", "refs/heads/main", "false"),  # docs only: no heavy build
        ("push", "README.md", "refs/heads/testing", "true"),  # testing: the reuse check decides
        ("push", "docs/a.md", "refs/heads/main", "false"),
    ],
)
def test_plan_build(tmp_path, event, changed, ref, want):
    repo, ids = push_repo(tmp_path, changed)
    assert script("plan_build.py", event, ids[0], ids[1], ref, cwd=repo).stdout.strip() == want


def test_plan_build_builds_for_an_unusable_base_commit(tmp_path):
    repo, ids = push_repo(tmp_path, "README.md")
    assert script("plan_build.py", "push", "0" * 40, ids[1], "refs/heads/main", cwd=repo).stdout.strip() == "true"


def aggregate(name, **env):
    return script(name, env={k: "" for k in ("PLAN", "BUILD", "PROMOTE", "SIGN", "BUILD_WANTED", "PROMOTE_WANTED", "PUBLISH", "DRY_RUN")}, extra=env)


@pytest.mark.parametrize(
    "env, ok",
    [
        (dict(PLAN="success", BUILD="success", PROMOTE="skipped", SIGN="success", BUILD_WANTED="true", PUBLISH="true"), True),
        (dict(PLAN="success", BUILD="success", PROMOTE="skipped", SIGN="skipped", BUILD_WANTED="true", PUBLISH="false"), True),
        (dict(PLAN="success", BUILD="skipped", PROMOTE="success", SIGN="success", PROMOTE_WANTED="true"), True),
        (dict(PLAN="success", BUILD="skipped", PROMOTE="skipped", SIGN="skipped"), True),  # docs-only
        (dict(PLAN="failure", BUILD="skipped", PROMOTE="skipped", SIGN="skipped"), False),
        (dict(PLAN="success", BUILD="failure", PROMOTE="skipped", SIGN="skipped", BUILD_WANTED="true"), False),
        (dict(PLAN="success", BUILD="success", PROMOTE="skipped", SIGN="failure", BUILD_WANTED="true", PUBLISH="true"), False),
        (dict(PLAN="success", BUILD="success", PROMOTE="skipped", SIGN="success", BUILD_WANTED="true", PUBLISH="false"), False),  # signed although nothing was published
        (dict(PLAN="success", BUILD="skipped", PROMOTE="success", SIGN="failure", PROMOTE_WANTED="true"), False),
        (dict(PLAN="success", BUILD="success", PROMOTE="success", SIGN="success", BUILD_WANTED="false", PROMOTE_WANTED="false"), False),
    ],
)
def test_aggregate_result(env, ok):
    assert (aggregate("aggregate_result.py", **env).returncode == 0) is ok


@pytest.mark.parametrize(
    "env, ok",
    [
        (dict(PLAN="skipped", BUILD="skipped", PROMOTE="skipped", SIGN="skipped"), True),
        (dict(PLAN="skipped", BUILD="success", PROMOTE="skipped", SIGN="skipped"), False),
        (dict(PLAN="success", BUILD="success", PROMOTE="skipped", SIGN="success", BUILD_WANTED="true"), True),
        (dict(PLAN="success", BUILD="success", PROMOTE="skipped", SIGN="failure", BUILD_WANTED="true"), False),
        (dict(PLAN="success", BUILD="skipped", PROMOTE="success", SIGN="success", PROMOTE_WANTED="true"), True),
        (dict(PLAN="success", BUILD="skipped", PROMOTE="skipped", SIGN="skipped"), True),
        (dict(PLAN="success", BUILD="success", PROMOTE="skipped", SIGN="skipped"), False),
        (dict(PLAN="success", BUILD="skipped", PROMOTE="skipped", SIGN="skipped", DRY_RUN="true", BUILD_WANTED="true"), True),
        (dict(PLAN="success", BUILD="success", PROMOTE="skipped", SIGN="success", DRY_RUN="true", BUILD_WANTED="true"), False),
    ],
)
def test_aggregate_dx(env, ok):
    assert (aggregate("aggregate_dx.py", **env).returncode == 0) is ok


def version_check(*lines):
    return subprocess.run([sys.executable, "-I", str(SCRIPTS / "check_version_neutral.py")], input="".join(f"{line}\n" for line in lines), capture_output=True, text=True)


def test_version_labels_must_not_name_a_channel():
    assert version_check("org.opencontainers.image.version=20261108-abc1234", 'IMAGE_VERSION="20261108-abc1234"').returncode == 0
    assert version_check("org.opencontainers.image.version=testing-abc", "IMAGE_VERSION=1").returncode == 1
    assert version_check("org.opencontainers.image.version=1", "IMAGE_VERSION=latest").returncode == 1
    assert version_check("IMAGE_VERSION=1").returncode == 1  # the OCI version label is required
    assert version_check("org.opencontainers.image.version=1").returncode == 1  # and so is IMAGE_VERSION


def test_a_captured_result_is_alone_on_stdout():
    """A workflow captures stdout with `$(...)`: the reason a script logs (info) goes to stderr, stdout holds only the result."""
    p = script("plan_build.py", "push", "0" * 40, "HEAD", "refs/heads/main")
    assert p.returncode == 0 and p.stdout == "true\n" and "no usable base commit" in p.stderr
    p = script("plan_skip.py", env={k: "" for k in SKIP_ENV}, extra=SKIP_ENV)
    assert p.stdout.count("\n") == 1 and p.stdout.startswith("skipped:")
