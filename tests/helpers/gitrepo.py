"""A throw-away git repository with a `commit(msg, **files)` helper."""
from __future__ import annotations

import subprocess
from pathlib import Path

_ENV = {
    "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.invalid",
    "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.invalid",
    "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "PATH": "/usr/bin:/bin",
}


class GitRepo:
    def __init__(self, path: Path, branch: str = "main"):
        self.path = Path(path)
        self.path.mkdir(parents=True, exist_ok=True)
        self.git("init", "-q", "-b", branch)

    def git(self, *args: str) -> str:
        p = subprocess.run(["git", *args], cwd=self.path, env=_ENV, capture_output=True, text=True, check=True)
        return p.stdout.strip()

    def commit(self, msg: str, files: dict[str, str] | None = None, remove: tuple[str, ...] = (), **named: str) -> str:
        """Write the files (path -> content; extra paths can come as keywords through ``**{"a/b": "x"}``),
        remove the listed ones, commit everything and return the commit id."""
        for rel, content in {**(files or {}), **named}.items():
            f = self.path / rel
            f.parent.mkdir(parents=True, exist_ok=True)
            f.write_text(content)
        for rel in remove:
            (self.path / rel).unlink()
        self.git("add", "-A")
        self.git("commit", "-q", "--allow-empty", "-m", msg)
        return self.rev()

    def rev(self, ref: str = "HEAD") -> str:
        return self.git("rev-parse", ref)

    def short(self, ref: str = "HEAD", n: int = 7) -> str:
        return self.git("rev-parse", f"--short={n}", ref)

    def sha_default_short(self, ref: str = "HEAD") -> str:
        """Same as `git rev-parse --short` (auto length), the form plan-promote's tags use."""
        return self.git("rev-parse", "--short", ref)
