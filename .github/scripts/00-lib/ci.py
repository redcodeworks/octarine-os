"""The ONE shared-helpers file of the CI scripts: logging (`log`, GitHub annotations),
the @retry decorator (THE retry for network calls), the GitHub API through githubkit
(`github()`, used directly by the scripts), version ordering (packaging) and step
outputs.

The scripts run through uv with the locked dependencies (`uv run --frozen python -I
.github/scripts/<stage>/<name>.py`). `-I` keeps the script's own directory off sys.path,
so each script puts this directory (00-lib) and its own directory on it with two lines
(see any script) before it imports this module.
"""

import argparse
import contextlib
import functools
import logging
import os
import re
import subprocess
import sys
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

from githubkit import GitHub
from githubkit.exception import RequestError, RequestFailed
from githubkit.retry import RETRY_DEFAULT, RetryOption
from packaging.version import InvalidVersion, Version


class Annotations(logging.Handler):
    """Writes log records the way the Actions runner reads them: `::error::` and
    `::warning::` lines (stderr), plain lines for info, all on stderr: stdout belongs to
    the result of a script (`ci.result`), which a workflow may capture with `$(...)`.
    """

    def emit(self, record):
        """Print one log record to stderr, with the annotation prefix its level needs.

        Receives the record; errors and warnings get `::error::` and
        `::warning::` so the Actions runner shows them as annotations.
        """
        prefix = {logging.ERROR: "::error::", logging.WARNING: "::warning::"}.get(
            record.levelno, ""
        )
        print(f"{prefix}{record.getMessage()}", file=sys.stderr, flush=True)


# every script logs through this one: log.info, log.warning, log.error
log = logging.getLogger("ci")
log.setLevel(logging.INFO)
log.addHandler(Annotations())
log.propagate = False


def arg_parser(doc):
    """An ArgumentParser whose --help description is the first sentence of the script's
    docstring.
    """
    return argparse.ArgumentParser(
        description=doc.strip().splitlines()[0].split(" Usage:")[0],
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )


def append_to(env_var: str, line: str) -> None:
    """Append a line to the file named by an Actions variable (GITHUB_OUTPUT,
    GITHUB_STEP_SUMMARY), when set.
    """
    # a variable that is not set (a local run) writes nothing
    if path := os.environ.get(env_var):
        # append one line to the file the runner provides
        with Path(path).open("a") as f:
            print(line, file=f)


def emit(key: str, value: str, note: str = "") -> None:
    """Write `key=value` as the result and export it as a step output."""
    result(f"{key}={value}{note}")
    append_to("GITHUB_OUTPUT", f"{key}={value}")


def result(text: str) -> None:
    """The ONE way a script writes its result to stdout (what a workflow captures:
    `true`/`false`, a digest, key=value lines); reasons and progress go through `log`.
    """
    print(text, flush=True)


def note(message: str) -> None:
    """A plain info line (stderr): a decision script keeps its stdout for its answer and
    puts the reasons here.
    """
    log.info(message)


def summary(line: str) -> None:
    """Log a line and add it to the job summary (a summary that cannot be written never
    fails the step).
    """
    log.info(line)

    # a summary that cannot be written must never fail the step
    try:
        append_to("GITHUB_STEP_SUMMARY", line)
    except OSError:
        pass


def text(data: bytes | str, limit: int = 300) -> str:
    """Bytes or str -> a one-line snippet for a message."""
    # bytes are decoded first; undecodable bytes are replaced, not an error
    if isinstance(data, bytes):
        data = data.decode(errors="replace")
    return data[:limit].replace("\n", " ")


def int_env(name: str, default: int) -> int:
    """Read a non-negative whole number from the environment.

    Receives the variable name and the default used when it is unset. Returns the
    number; a value that is not a number exits with a message through SystemExit.
    """
    value = os.environ.get(name, str(default))

    # only digits are valid: no sign, no unit, no empty string
    if not value.isdigit():
        raise SystemExit(f"{name} must be a number, got '{value}'")
    return int(value)


def run(cmd, capture=False, **kw):
    """Run an argument list (never a shell); a missing program is exit status 127."""
    # a missing program is exit status 127, as a shell would report it
    try:
        return subprocess.run(cmd, capture_output=capture, **kw)
    except FileNotFoundError as e:
        return subprocess.CompletedProcess(cmd, 127, b"", str(e).encode())


def stderr_of(proc: subprocess.CompletedProcess) -> str:
    """Return the stderr of a finished process as text.

    Receives a CompletedProcess whose stderr was captured (or None); undecodable
    bytes are replaced.
    """
    return (proc.stderr or b"").decode(errors="replace")


def git(*args: str) -> str:
    """The stdout of a git command; a failing git raises CalledProcessError (callers
    that expect a failure catch it: EAFP).
    """
    return subprocess.run(
        ["git", *args], check=True, text=True, capture_output=True
    ).stdout.strip()


@contextlib.contextmanager
def group(title: str):
    """A collapsible group in the Actions log: `with ci.group("sign"):`."""
    print(f"::group::{title}", flush=True)

    # the group is closed even when the body raises
    try:
        yield
    finally:
        print("::endgroup::", flush=True)


class NetworkError(Exception):
    """A network command (skopeo copy, podman push, cosign sign) failed; the usual
    transient error to retry.
    """


class ServerError(Exception):
    """A web server answered 5xx; transient."""


def retry(*, on, attempts=None, delay=None, backoff=True):
    """Decorator for a NETWORK call that may fail for a moment (a registry, cosign's
    lookups, a download; the GitHub API has its own retry decision, see
    `retry_decision`); put it on nothing else.

    What it retries: only the exception types in `on` (the transient failures). Any
    other exception, in particular a definitive answer such as `Absent` (the tag is not
    there), `NotVerified` (the signature is not valid) or a 404, propagates at once and
    is never retried: a permanent failure must not be dressed up as a flaky network. How
    long it waits: `attempts` tries (default RETRY_TRIES, 3) with a pause of `delay`
    seconds (default RETRY_DELAY, 5) times the try number before the next try
    (`backoff=False`: the same pause every time). Both are read when the function is
    called, so the environment can shorten them for tests. What it re-raises: after the
    last try, the last error itself (same type, so callers catch it as before) with the
    text "(failed N attempts)" added to its message. Not for calls that must not run
    twice. Every failed try logs a warning.
    """

    def decorate(fn):
        """Wrap one function with the retry loop.

        Receives the function; returns the wrapper that calls it up to the
        configured number of times.
        """

        @functools.wraps(fn)
        def wrapper(*args, **kwargs):
            """Call the function, retrying the transient exceptions in `on`.

            Returns the function's value. Re-raises the last transient error
            after the final try (with the attempt count added), and any
            other exception at once.
            """
            tries = int_env("RETRY_TRIES", 3) if attempts is None else attempts
            pause = int_env("RETRY_DELAY", 5) if delay is None else delay

            # try up to `tries` times, pausing a little longer after each failure
            for i in range(1, tries + 1):
                # a transient failure is retried; anything else propagates
                try:
                    return fn(*args, **kwargs)
                except on as e:
                    # the last try re-raises with the attempt count in the message
                    if i == tries:
                        e.args = (f"{e} (failed {tries} attempts)",)
                        raise
                    wait = pause * i if backoff else pause
                    log.warning(
                        f"{fn.__name__}: try {i}/{tries} failed ({text(str(e), 200)}); retrying in {wait} s"
                    )
                    time.sleep(wait)

        return wrapper

    return decorate


def retry_decision(exc, retry_count):
    """githubkit's own retry decision (RETRY_DEFAULT: a rate limit once, a 5xx three
    times) plus transport errors (a dropped connection, a timeout: githubkit raises a
    RequestError that is not a RequestFailed), two more tries with a pause of
    RETRY_DELAY (5) seconds times the try number. An error status such as a 404 is never
    retried.
    """
    # transport errors (not an error status) get two more tries
    if (
        isinstance(exc, RequestError)
        and not isinstance(exc, RequestFailed)
        and retry_count < 2
    ):
        pause = int_env("RETRY_DELAY", 5) * (retry_count + 1)
        # githubkit reads a zero timedelta as "no answer" and waits 60 s, so never
        # zero
        return RetryOption(True, timedelta(seconds=max(pause, 0.001)))
    return RETRY_DEFAULT(exc, retry_count)


def github():
    """The githubkit client of every script: token from GITHUB_TOKEN (or GH_TOKEN, which
    the workflow steps export for the gh CLI), server from GITHUB_API_URL (a fake in the
    tests), the retry decision above. Its errors are not wrapped.
    """
    return GitHub(
        os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN"),
        base_url=os.environ.get("GITHUB_API_URL", "https://api.github.com"),
        timeout=30,
        auto_retry=retry_decision,
    )


def version(tag: str) -> Version:
    """A tag as a comparable version (a leading v is fine); ValueError for a tag that is
    not a version.
    """
    # an invalid tag is reported as ValueError with the tag in the message
    try:
        return Version(tag)
    except InvalidVersion as e:
        raise ValueError(f"'{tag}' is not a version") from e


def git_ok(*args: str) -> bool:
    """Whether a git command succeeds (`git cat-file -e ...`, `git merge-base
    --is-ancestor ...`).
    """
    return (
        run(
            ["git", *args], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
        ).returncode
        == 0
    )


def epoch(iso: str) -> int:
    """An ISO 8601 date as seconds since the epoch (a date without a zone is UTC, like
    `date -u -d`); ValueError when it cannot be read.
    """
    d = datetime.fromisoformat(re.sub(r"(\.\d{6})\d+", r"\1", iso.strip()))
    return int((d if d.tzinfo else d.replace(tzinfo=timezone.utc)).timestamp())
