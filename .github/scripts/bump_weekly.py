#!/usr/bin/env python3
"""The weekly pin bump: ONE INDEPENDENT pull request into testing PER PIN that moved (2026-11-16, Kevin: so any subset can be merged in any order and the rest closed). Every pin starts from current
testing on its own branch bump/<pin>-YYYYMMDD with ONE commit (the pin change, made by bump_run.py), so the PRs are not a chain and touch different pin lines. Rules:
  - the pin already equals upstream (testing has it): nothing is opened; an open bump PR of that pin is closed with a comment (stale);
  - an open bump PR of the pin already carries the value upstream has now: it stays as it is, nothing new (idempotent reruns);
  - an open bump PR of the pin carries an OLDER value (upstream moved again): a new branch (bump/<pin>-YYYYMMDD-2 ...: a new name, no force-push is ever used) and a new PR are made, and the older one is
    closed with a comment pointing at the new one, so at most one bump PR per pin stays open;
  - a failing pin changes nothing, turns the run red (scripts/scheduled-runs.sh reports it) and does not stop the other pins.
Every new PR gets the required `test` and `secrets` check runs from bump_checks.py (keyed by its commit sha, so parallel PRs do not collide).
DRY_RUN=1 (a manual run with dry_run on) does every decision locally and prints what it would open, keep or close, pushing and opening nothing. A real run needs HEAD to be origin/testing (the workflow
checks testing out). Needs git, gh with GH_TOKEN, GITHUB_REPOSITORY; BUMP_BASE (testing) for the tests. BUMP_PINS: the pins to bump, space separated, no default: the matrix of bump-pins.yml is the only
list of pins (one job per pin sets it to its own pin). Usage: bump_weekly.py
"""
import json
import os
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ci  # noqa: E402

HERE = Path(__file__).resolve().parent
env = os.environ.get


def summary(line):
    ci.summary(line)


def open_prs(base, pin):
    """(number, branch) of every open PR into the base whose branch is bump/<pin>-..."""
    p = ci.capture(["gh", "pr", "list", "--base", base, "--state", "open", "--json", "number,headRefName"])
    try:
        prs = json.loads(p.stdout) if p.returncode == 0 else []
    except ValueError:
        prs = []
    return [(str(pr["number"]), pr["headRefName"]) for pr in prs if pr["headRefName"].startswith(f"bump/{pin}-")]


def row_of(rev):
    """The pin row of a commit (first line of its body): pin | from | to | what changed upstream | days."""
    body = ci.git("log", "-1", "--format=%b", rev, check=False)
    return body.split("\n", 1)[0]


def to_of(rev):
    """The `to` field of the row."""
    r = row_of(rev)
    for _ in range(2):
        i = r.find("| ")
        r = r[i + 2:] if i >= 0 else r
    j = r.find(" |")
    return r[:j] if j >= 0 else r


def close_pr(number, comment):
    if ci.run(["gh", "pr", "close", number, "--delete-branch", "--comment", comment]).returncode != 0:
        print(f"::warning::could not close #{number}")


def main():
    os.chdir(env("REPO_ROOT") or HERE.parent.parent)
    base = env("BUMP_BASE") or "testing"
    pins = (env("BUMP_PINS") or "").split()
    if not pins:
        print('::error::BUMP_PINS is empty (the pins to bump, e.g. BUMP_PINS="bins brew")')
        return 1
    dry = bool(env("DRY_RUN"))
    if ci.run(["git", "fetch", "-q", "origin", base]).returncode != 0:
        print(f"::error::cannot fetch {base}")
        return 1
    start = ci.git("rev-parse", "HEAD")
    if not dry and start != ci.git("rev-parse", f"origin/{base}", check=False):
        print(f"::error::a real run must start from origin/{base} (this checkout is not it); use dry_run to try another ref")
        return 1
    day = time.strftime("%Y%m%d", time.gmtime())
    summary(f"## Pin bump: {' '.join(pins)}")
    failed = 0

    for p in pins:
        if not ci.git_ok("checkout", "-q", "--detach", start):
            failed = 1
            continue
        branch, n = f"bump/{p}-{day}", 1
        while not dry and ci.git_ok("ls-remote", "--exit-code", "--heads", "origin", branch):
            n += 1
            branch = f"bump/{p}-{day}-{n}"
        if not ci.git_ok("checkout", "-q", "-B", branch):
            failed = 1
            continue
        if subprocess.run([sys.executable, "-I", str(HERE / "bump_run.py"), p]).returncode != 0:
            failed = 1
            continue
        pending = open_prs(base, p)
        if not ci.git("rev-list", f"{start}..HEAD"):
            for number, _ in pending:
                if dry:
                    summary(f"Dry run: would close #{number} ({p}: testing already has the upstream value)")
                else:
                    close_pr(number, f"Closing: `{p}` already equals upstream on `{base}`, so this bump is not needed any more.")
            continue
        c = ci.git("rev-parse", "HEAD")
        row, to = row_of(c), to_of(c)
        if " | " not in row:
            print(f"::error::{p}: the bump commit has no table row")
            failed = 1
            continue
        keep = ""
        for number, pr_branch in pending:
            if ci.run(["git", "fetch", "-q", "origin", pr_branch], stderr=subprocess.DEVNULL).returncode == 0 and to_of("FETCH_HEAD") == to:
                keep = number
        if keep:
            summary(f"`{p}`: #{keep} already proposes {to}; nothing new")
            continue
        title = f"Bump {p}: " + "|".join(row.split("|")[1:3]).replace(" | ", " to ", 1).strip(" ")
        title = title[:140]
        note = ""
        if p == "bins":
            note = (" The new octarine-bins digest (the prebuilt binaries) was verified with `keys/octarine-bins.pub`; the testing build after the merge is the first OS build with those binaries "
                    "(its ldd, 32-bit, terminfo and file-conflict checks run there). Check the scheduler READMEs when the schedulers change.")
        body = f"""One commit, one pin; this pull request is independent of the other bump pull requests (merge any subset, in any order, and close the rest).

| pin | from | to | what changed upstream | days the new value has existed |
|---|---|---|---|---|
| {row} |

Only the pin lines change.{note} Not verified: nothing was built or booted by the bump; the image build after the merge into `{base}` is the first build with this pin. The owner merges this pull request.

Checks: this commit is tested by the `Test` workflow (dispatched on `{base}` for it, because a pull request opened with the workflow token starts no workflow itself) and its `test` and `secrets` results are reported here as check runs. If they are missing, run the bump workflow again (`gh workflow run bump-pins.yml --ref {base}`): it makes a new branch and pull request and closes this one.

🤖 Generated with [Claude Code](https://claude.com/claude-code)"""
        if dry:
            summary(f"Dry run: would open {branch} ({c[:7]}), title: {title}")
            for number, pr_branch in pending:
                summary(f"Dry run: would close the older #{number} ({pr_branch}), superseded")
            summary(body)
            continue
        if ci.run(["git", "push", "-q", "origin", f"refs/heads/{branch}:refs/heads/{branch}"]).returncode != 0:
            print(f"::error::cannot push {branch}")
            failed = 1
            continue
        created = ci.run(["gh", "pr", "create", "--base", base, "--head", branch, "--title", title, "--body", body], stdout=subprocess.PIPE)
        if created.returncode != 0:
            print(f"::error::Could not open the pull request for {p}. Is Settings, Actions, General, Allow GitHub Actions to create and approve pull requests, on?")
            failed = 1
            continue
        url = created.stdout.decode().strip()
        summary(f"`{p}`: opened {url}")
        for number, _ in pending:
            close_pr(number, f"Superseded by {url}: upstream moved again, so `{p}` has a newer bump pull request.")
        subprocess.run([sys.executable, "-I", str(HERE / "bump_checks.py"), branch, c])
    ci.run(["git", "checkout", "-q", "--detach", start], stderr=subprocess.DEVNULL)
    return failed


if __name__ == "__main__":
    sys.exit(main())
