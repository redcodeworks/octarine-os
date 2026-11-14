"""Run a script with a clean, explicit environment and report what happened.

The environment is built from scratch (never inherited): PATH is the test's stub directory, then the deny
directory (sudo, systemctl, podman, ... exit 99 and are logged), then the system directories. stdin is /dev/null and
the child gets its own session, so nothing can reach the terminal or the caller's process group.
"""
from __future__ import annotations

import os
import subprocess
from dataclasses import dataclass, field
from pathlib import Path

SYSTEM_PATH = "/usr/local/bin:/usr/bin:/bin"


@dataclass
class Result:
    rc: int
    out: str
    err: str
    calls: list[list[str]] = field(default_factory=list)

    @property
    def lines(self) -> list[str]:
        return self.out.splitlines()

    def output(self, key: str) -> str:
        """Value of a `key=value` line in stdout (the last one wins), '' when absent."""
        val = ""
        for line in self.out.splitlines():
            if line.startswith(key + "="):
                val = line[len(key) + 1:]
        return val


def clean_env(path_dirs: list[Path | str], home: Path, deny_log: Path, extra: dict[str, str] | None = None) -> dict[str, str]:
    env = {
        "PATH": ":".join([*(str(p) for p in path_dirs), SYSTEM_PATH]),
        "HOME": str(home),
        "LC_ALL": "C.UTF-8",
        "TZ": "UTC",
        "DENY_LOG": str(deny_log),
        "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.invalid",
        "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.invalid",
        "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
    }
    env.update(extra or {})
    return env


def run(argv: list[str], *, env: dict[str, str], cwd: Path, timeout: int = 60, stdin: str | None = None) -> tuple[int, str, str]:
    p = subprocess.run(
        argv, env=env, cwd=cwd, input=stdin, stdin=None if stdin is not None else subprocess.DEVNULL,
        capture_output=True, text=True, timeout=timeout, start_new_session=True,
    )
    return p.returncode, p.stdout, p.stderr
