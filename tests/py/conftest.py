"""Fixtures of the tests: the scripts on sys.path, and the fake skopeo, cosign and gh programs of tests/fakes/ on PATH (no network, nothing is pulled).

The fakes are real executable Python files that the scripts under test start as they would start the real tools, so the tests run the real script into the real
reader. Their behavior comes from the environment: STATE (a directory with one file per tag, the manifest), MODE, COSIGN_MODE, LOG, COUNT, DB.
"""

import importlib.util
import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / ".github" / "scripts"
FAKES = ROOT / "tests" / "py" / "fakes"
sys.path.insert(0, str(SCRIPTS))


@pytest.fixture
def fakes(tmp_path, monkeypatch):
    """tests/fakes on PATH in front; returns the environment for subprocesses (also applied to this process)."""
    state = tmp_path / "state"
    state.mkdir()
    env = {
        "PATH": f"{FAKES}:{os.environ['PATH']}",
        "RETRY_DELAY": "0",
        "READBACK_WAIT": "0",
        "READBACK_TRIES": "2",
        "STATE": str(state),
        "LOG": str(tmp_path / "log"),
        "COUNT": str(tmp_path / "count"),
    }
    for k, v in env.items():
        monkeypatch.setenv(k, v)
    monkeypatch.delenv("GITHUB_OUTPUT", raising=False)
    return env


def script(name, *args, cwd=None, env=None, extra=None):
    """Run a script of .github/scripts the way a workflow does (`python3 -I`); returns the CompletedProcess with text output."""
    e = {**os.environ, **(env or {}), **(extra or {})}
    return subprocess.run([sys.executable, "-I", str(SCRIPTS / name), *args], cwd=cwd, env=e, capture_output=True, text=True)


def git(repo, *args):
    return subprocess.run(
        ["git", "-C", str(repo), *args],
        check=True,
        capture_output=True,
        text=True,
        env={**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"},
    ).stdout.strip()


def load_fake(name):
    """Import a Python file of tests/fakes by path (the directory is not on sys.path: the stub bump_run.py there must not shadow the real one)."""
    spec = importlib.util.spec_from_file_location(name, FAKES / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


github_api = load_fake("github_api")
fixture, pull = github_api.fixture, github_api.pull  # captured GitHub answers for the tests to adjust


@pytest.fixture
def github(monkeypatch):
    """A fake GitHub API: the scripts (this process and subprocesses) talk to it through GITHUB_API_URL, GITHUB_REPOSITORY is o/r."""
    api = github_api.FakeGitHub()
    monkeypatch.setenv("GITHUB_API_URL", api.url)
    monkeypatch.setenv("GITHUB_TOKEN", "test-token")
    monkeypatch.setenv("GITHUB_REPOSITORY", "o/r")
    monkeypatch.setenv("RETRY_DELAY", "0")
    yield api
    api.stop()


class Registry:
    """A fake registry directory for fakes/skopeo (env REG): images with tags and image configs (labels), and the digests they get (the sha256 of the manifest bytes)."""

    def __init__(self, root):
        self.root = root

    def directory(self, image):
        return self.root / image.replace("/", "_")

    def put(self, image, tag, content, labels=None):
        """Publish `content` (bytes or str, the manifest) under image:tag with the given labels; returns its digest."""
        import hashlib

        data = content.encode() if isinstance(content, str) else content
        hexdigest = hashlib.sha256(data).hexdigest()
        d = self.directory(image)
        (d / "tags").mkdir(parents=True, exist_ok=True)
        (d / "cfg").mkdir(exist_ok=True)
        (d / "tags" / tag).write_bytes(data)
        (d / "cfg" / hexdigest).write_text(json.dumps({"config": {"Labels": labels or {}}}))
        return f"sha256:{hexdigest}"

    def tag(self, image, tag):
        """The digest under image:tag, or None."""
        import hashlib

        f = self.directory(image) / "tags" / tag
        return f"sha256:{hashlib.sha256(f.read_bytes()).hexdigest()}" if f.exists() else None


@pytest.fixture
def reg(tmp_path, fakes, monkeypatch):
    root = tmp_path / "registry"
    root.mkdir()
    monkeypatch.setenv("REG", str(root))
    return Registry(root)


def make_repo(path, *messages):
    """A git repository on branch main with one commit per message; returns the commit ids oldest first."""
    path.mkdir(parents=True, exist_ok=True)
    git(path, "init", "-q", "-b", "main", ".")
    ids = []
    for i, message in enumerate(messages):
        (path / "f").write_text(f"{i}\n")
        git(path, "add", "-A")
        git(path, "commit", "-qm", message)
        ids.append(git(path, "rev-parse", "HEAD"))
    return ids
