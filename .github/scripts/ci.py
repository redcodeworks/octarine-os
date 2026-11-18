"""The shared helpers of the CI scripts (standard library only): step outputs and the job summary, the command runner, and THE retry for network commands.

The scripts run through uv (`uv run --frozen --no-dev python -I .github/scripts/<name>.py`). `-I` keeps the script's own directory off sys.path, so every script adds it back
with two lines (see any script) before it imports this module. Behavior notes: the messages are the ones the shell scripts printed (`::error::` / `::warning::` lines the
workflows and the tests read), and the environment names (RETRY_TRIES, RETRY_DELAY, GITHUB_OUTPUT, GITHUB_STEP_SUMMARY ...) are unchanged.
"""
import os
import subprocess
import sys
import time
from pathlib import Path


def err(msg: str) -> None:
    """A message on stderr (the `::error::` and `::warning::` annotations are written by the callers, as the shell scripts did)."""
    print(msg, file=sys.stderr, flush=True)


def fail(msg: str, code: int = 1):
    """Print `::error::<msg>` (stdout, like the shell `echo "::error::..."`) and exit."""
    print(f"::error::{msg}", flush=True)
    raise SystemExit(code)


def append_to(env_var: str, line: str) -> None:
    """Append a line to the file named by an Actions variable (GITHUB_OUTPUT, GITHUB_STEP_SUMMARY, GITHUB_ENV), when set."""
    if path := os.environ.get(env_var):
        with Path(path).open("a") as f:
            print(line, file=f)


def output(key: str, value: str) -> None:
    """Export a step output (only when GITHUB_OUTPUT is set; nothing is printed)."""
    append_to("GITHUB_OUTPUT", f"{key}={value}")


def summary(line: str, echo: bool = True) -> None:
    """Print a line and add it to the job summary; a summary that cannot be written never fails the step."""
    if echo:
        print(line, flush=True)
    try:
        append_to("GITHUB_STEP_SUMMARY", line)
    except OSError:
        pass


def snippet(data, limit: int) -> str:
    """The first `limit` bytes of a command's output as one line (the `head -c N | tr '\\n' ' '` of the shell scripts)."""
    if isinstance(data, str):
        data = data.encode()
    return data[:limit].decode(errors="replace").replace("\n", " ")


def run(cmd, **kw) -> subprocess.CompletedProcess:
    """Run an argument list (never a shell); a missing program is exit status 127 with the reason as stderr. Output is bytes."""
    try:
        return subprocess.run(cmd, **kw)
    except FileNotFoundError as e:
        return subprocess.CompletedProcess(cmd, 127, b"", str(e).encode())


def capture(cmd, **kw) -> subprocess.CompletedProcess:
    return run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, **kw)


def git(*args: str, check: bool = True) -> str:
    """The stdout of a git command, stripped; a failing git raises CalledProcessError unless check is False (then: empty string)."""
    p = subprocess.run(["git", *args], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if p.returncode != 0 and check:
        raise subprocess.CalledProcessError(p.returncode, p.args, p.stdout, p.stderr)
    return p.stdout.strip() if p.returncode == 0 else ""


def git_ok(*args: str) -> bool:
    """Whether a git command succeeds (`git cat-file -e ...`, `git merge-base --is-ancestor ...`)."""
    return subprocess.run(["git", *args], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0


def int_env(name: str, default: int) -> int:
    value = os.environ.get(name, str(default))
    if not value.isdigit():
        raise SystemExit(f"{name} must be a number, got '{value}'")
    return int(value)


def retry_command(cmd, tries: int | None = None, delay: int | None = None) -> int:
    """THE retry of the pipeline: run a command up to `tries` times (RETRY_TRIES, 3) with a growing pause (RETRY_DELAY, 5 seconds times the try number) for calls to the
    network (registries, apt, cosign's lookups). Output passes through; notices go to stderr as `::warning::` (every failed try) and `::error::` (the last). Returns 0 when a try
    succeeded, else the exit status of the last try. Not for commands that must not run twice."""
    tries = int_env("RETRY_TRIES", 3) if tries is None else tries
    delay = int_env("RETRY_DELAY", 5) if delay is None else delay
    name = " ".join(cmd[:2])
    rc = 0
    for i in range(1, tries + 1):
        rc = run(cmd).returncode
        if rc == 0:
            return 0
        if i < tries:
            err(f"::warning::try {i}/{tries} failed (exit {rc}): {name}; retrying in {delay * i} s")
            time.sleep(delay * i)
    err(f"::error::{name} failed {tries} times (last exit {rc}); a transient network error would have passed by now, so treat this as a real failure "
        "(bad signature, missing package or tag, or a longer outage)")
    return rc
