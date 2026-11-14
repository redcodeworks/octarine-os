"""Fixtures: repo root, a sandbox (stubs, deny directory, clean environment) and git repositories."""
from __future__ import annotations

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).parent))

from helpers import bashrun  # noqa: E402
from helpers.gitrepo import GitRepo  # noqa: E402
from helpers.stubs import Stubs, write_deny_dir  # noqa: E402

REPO = Path(__file__).resolve().parents[1]
SCRIPTS = REPO / ".github" / "scripts"


@pytest.fixture(scope="session")
def repo_root() -> Path:
    """The repository root. Read only: copy what a test needs to change."""
    return REPO


class Sandbox:
    """Per-test environment: stubs first on PATH, the deny directory behind them, an empty HOME."""

    def __init__(self, tmp_path: Path):
        self.tmp = tmp_path
        self.home = tmp_path / "home"
        self.home.mkdir()
        self.stubs = Stubs(tmp_path)
        self.deny_dir = write_deny_dir(tmp_path / "deny")
        self.deny_log = tmp_path / "deny.log"
        self.deny_log.touch()

    def run(self, argv, *, cwd: Path | None = None, env: dict | None = None, stdin: str | None = None,
            timeout: int = 60) -> bashrun.Result:
        full = bashrun.clean_env([self.stubs.bin, self.deny_dir], self.home, self.deny_log, env)
        before = len(self.stubs.all_calls)
        rc, out, err = bashrun.run([str(a) for a in argv], env=full, cwd=cwd or self.tmp, stdin=stdin, timeout=timeout)
        return bashrun.Result(rc, out, err, self.stubs.all_calls[before:])

    def bash(self, script: Path | str, *args, **kw) -> bashrun.Result:
        return self.run(["bash", script, *args], **kw)


@pytest.fixture(autouse=True)
def sandbox(tmp_path) -> Sandbox:
    """The sandbox of the test. Autouse: a test fails when anything it ran reached a denied tool (sudo, systemctl,
    podman, skopeo, ... that the test did not stub itself)."""
    sbx = Sandbox(tmp_path)
    yield sbx
    denied = sbx.deny_log.read_text().strip()
    assert not denied, f"a denied tool was reached (stub it in the test):\n{denied}"


@pytest.fixture
def stubs(sandbox) -> Stubs:
    return sandbox.stubs


@pytest.fixture
def git_repo(tmp_path):
    """Factory: git_repo("name", branch="main") -> GitRepo in tmp_path/name."""
    def make(name: str = "repo", branch: str = "main") -> GitRepo:
        return GitRepo(tmp_path / name, branch)
    return make
