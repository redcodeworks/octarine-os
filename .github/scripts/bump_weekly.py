#!/usr/bin/env python3
"""The weekly pin bump: ONE INDEPENDENT pull request into testing PER PIN that moved.
Usage: bump_weekly.py   (env GITHUB_TOKEN, GITHUB_REPOSITORY, GITHUB_API_URL; BUMP_PINS
(required: the pins to bump, space separated; the matrix of bump-pins.yml is the only
list, one job per pin); DRY_RUN=1; BUMP_BASE, REPO_ROOT for the tests)

Every pin starts from current testing on its own branch bump/<pin>-YYYYMMDD with ONE
commit (the pin change, made by bump_run.py), so the PRs are not a chain and touch
different pin lines, and any subset can be merged in any order. Rules:
  - the pin already equals upstream (testing has it): nothing is opened; an open bump PR
    of that pin is closed with a comment (stale);
  - an open bump PR of the pin already carries the value upstream has now: it stays as
    it is, nothing new (idempotent reruns);
  - an open bump PR of the pin carries an OLDER value (upstream moved again): a new
    branch (bump/<pin>-YYYYMMDD-2 ...: a new name, no force-push is ever used) and a new
    PR are made, and the older one is closed with a comment pointing at the new one, so
    at most one bump PR per pin stays open;
  - a failing pin changes nothing, turns the run red and does not stop the other pins.
Every new PR gets the required `test` and `secrets` check runs from bump_checks.py
(keyed by its commit sha, so parallel PRs do not collide). DRY_RUN=1 does every decision
locally and prints what it would open, keep or close, pushing and opening nothing. A
real run needs HEAD to be origin/testing (the workflow checks testing out).
"""

import os
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

from githubkit.exception import RequestFailed

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import ci  # noqa: E402

NOTES = {
    "bins": (
        " The new octarine-bins digest (the prebuilt binaries) was verified with `keys/octarine-bins.pub`; the testing build after the merge is the first OS build with those binaries "
        "(its ldd, 32-bit, terminfo and file-conflict checks run there). Check the scheduler READMEs when the schedulers change."
    ),
}
BODY = """One commit, one pin; this pull request is independent of the other bump pull requests (merge any subset, in any order, and close the rest).

| pin | from | to | what changed upstream | days the new value has existed |
|---|---|---|---|---|
| {row} |

Only the pin lines change.{note} Not verified: nothing was built or booted by the bump; the image build after the merge into `{base}` is the first build with this pin. The owner merges this pull request.

Checks: this commit is tested by the `Test` workflow (dispatched on `{base}` for it, because a pull request opened with the workflow token starts no workflow itself) and its `test` and `secrets` results are reported here as check runs. If they are missing, run the bump workflow again (`gh workflow run bump-pins.yml --ref {base}`): it makes a new branch and pull request and closes this one.

🤖 Generated with [Claude Code](https://claude.com/claude-code)"""


def git(*args):
    """Run git and capture its output.

    Receives the git arguments; returns the CompletedProcess without raising, so
    callers test the return code themselves.
    """
    return subprocess.run(["git", *args], capture_output=True, text=True)


def summary(line):
    """Log a line and add it to the job summary.

    Receives the line.
    """
    ci.log.info(line)
    ci.append_to("GITHUB_STEP_SUMMARY", line)


def row_of(rev):
    """The pin row of a commit: the first line of its body (pin | from | to | what
    changed upstream | days).
    """
    return (git("log", "-1", "--format=%b", rev).stdout.splitlines() or [""])[0]


def to_of(rev):
    """Return the proposed value (the third column) of a commit's table row, or "".

    Receives the revision whose first body line is the row.
    """
    fields = row_of(rev).split(" | ")
    return fields[2] if len(fields) > 2 else ""


def repo_parts():
    """Return the owner and repository name from GITHUB_REPOSITORY as API arguments."""
    owner, name = os.environ["GITHUB_REPOSITORY"].split("/")
    return {"owner": owner, "repo": name}


def open_prs(pin, base):
    """(number, branch) of every open PR into the base whose branch is bump/<pin>-..."""
    gh = ci.github()
    prs = gh.rest.paginate(gh.rest.pulls.list, state="open", base=base, **repo_parts())
    # keep the open pull requests whose branch is a bump of this pin
    return [
        (pr.number, pr.head.ref) for pr in prs if pr.head.ref.startswith(f"bump/{pin}-")
    ]


def close_pr(number, branch, comment):
    """Comment on a pull request, close it and delete its branch."""
    gh = ci.github()
    rest = gh.rest
    rest.issues.create_comment(
        issue_number=number, data={"body": comment}, **repo_parts()
    )
    rest.pulls.update(pull_number=number, data={"state": "closed"}, **repo_parts())
    rest.git.delete_ref(ref=f"heads/{branch}", **repo_parts())


def open_pr(branch, title, body, base):
    """Open the pull request and return its URL."""
    gh = ci.github()

    # a rejected creation usually means the setting that lets Actions open PRs is off
    try:
        return gh.rest.pulls.create(
            data={"title": title, "head": branch, "base": base, "body": body},
            **repo_parts(),
        ).parsed_data.html_url
    except RequestFailed:
        ci.log.error(
            "Could not open the pull request. Is Settings, Actions, General, Allow GitHub Actions to create and approve pull requests, on?"
        )
        raise


def main(argv=None):
    """Open, update or close the weekly pin bump pull requests.

    Reads BUMP_PINS (the pins to bump), BUMP_BASE (default testing), DRY_RUN and
    REPO_ROOT. For each pin a branch is cut from the starting commit and bump_run.py
    makes the change; a new pull request is opened when the proposal differs from
    every open one, older ones for the pin are closed, and bump_checks.py reports
    the checks. A dry run only reports. Returns 0, or 1 when a pin failed or the run
    could not start.
    """
    ci.arg_parser(__doc__).parse_args(argv)
    os.chdir(os.environ.get("REPO_ROOT") or HERE.parents[1])
    base = os.environ.get("BUMP_BASE", "testing")
    pins = os.environ.get("BUMP_PINS", "").split()

    # without pins there is nothing to do and that is a mistake in the call
    if not pins:
        ci.log.error(
            'BUMP_PINS is empty (the pins to bump, e.g. BUMP_PINS="bins brew")'
        )
        return 1
    dry = bool(os.environ.get("DRY_RUN"))

    # the base must be fetchable to compare against
    if git("fetch", "-q", "origin", base).returncode != 0:
        ci.log.error(f"cannot fetch {base}")
        return 1
    start = git("rev-parse", "HEAD").stdout.strip()

    # a real run must start from the tip of the base branch
    if not dry and start != git("rev-parse", f"origin/{base}").stdout.strip():
        ci.log.error(
            f"a real run must start from origin/{base} (this checkout is not it); use dry_run to try another ref"
        )
        return 1
    day = datetime.now(timezone.utc).strftime("%Y%m%d")
    summary(f"## Pin bump: {' '.join(pins)}")
    failed = False

    # one branch and pull request per pin
    for p in pins:
        # each pin starts from the same commit
        if git("checkout", "-q", "--detach", start).returncode != 0:
            failed = True
            continue
        branch, n = f"bump/{p}-{day}", 1
        # a free branch name: add a number when today's name is taken on the remote
        while (
            not dry
            and git("ls-remote", "--exit-code", "--heads", "origin", branch).returncode
            == 0
        ):
            n += 1
            branch = f"bump/{p}-{day}-{n}"
        # cut the branch for this pin
        if git("checkout", "-q", "-B", branch).returncode != 0:
            failed = True
            continue
        # bump_run.py edits the pin file and commits it
        if (
            subprocess.run(
                [sys.executable, "-I", str(HERE / "bump_run.py"), p]
            ).returncode
            != 0
        ):
            failed = True
            continue
        pending = open_prs(p, base)
        # no commit means the base already has the upstream value
        if not git("rev-list", f"{start}..HEAD").stdout.strip():
            # so any open bump pull request for the pin is obsolete
            for number, pr_branch in pending:
                # a dry run only says what it would close
                if dry:
                    summary(
                        f"Dry run: would close #{number} ({p}: testing already has the upstream value)"
                    )
                else:
                    close_pr(
                        number,
                        pr_branch,
                        f"Closing: `{p}` already equals upstream on `{base}`, so this bump is not needed any more.",
                    )
            continue
        commit = git("rev-parse", "HEAD").stdout.strip()
        row, to = row_of(commit), to_of(commit)
        # the commit must carry the table row that fills the title and the body
        if " | " not in row:
            ci.log.error(f"{p}: the bump commit has no table row")
            failed = True
            continue
        keep = None
        # an open pull request that already proposes this value makes a new one
        # pointless
        for number, pr_branch in pending:
            # fetch its branch and compare its proposed value
            if (
                git("fetch", "-q", "origin", pr_branch).returncode == 0
                and to_of("FETCH_HEAD") == to
            ):
                keep = number
        # nothing new to propose
        if keep:
            summary(f"`{p}`: #{keep} already proposes {to}; nothing new")
            continue
        fields = row.split("|")
        title = f"Bump {p}: {fields[1].strip()} to {fields[2].strip()}"[:140]
        body = BODY.format(row=row, note=NOTES.get(p, ""), base=base)
        # a dry run reports what it would open and close
        if dry:
            summary(f"Dry run: would open {branch} ({commit[:7]}), title: {title}")
            # older pull requests the new one would supersede
            for number, pr_branch in pending:
                summary(
                    f"Dry run: would close the older #{number} ({pr_branch}), superseded"
                )
            summary(body)
            continue
        # publish the branch before opening the pull request
        if (
            git(
                "push", "-q", "origin", f"refs/heads/{branch}:refs/heads/{branch}"
            ).returncode
            != 0
        ):
            ci.log.error(f"cannot push {branch}")
            failed = True
            continue
        url = open_pr(branch, title, body, base)
        summary(f"`{p}`: opened {url}")
        # older bump pull requests for this pin are superseded by the new one
        for number, pr_branch in pending:
            close_pr(
                number,
                pr_branch,
                f"Superseded by {url}: upstream moved again, so `{p}` has a newer bump pull request.",
            )
        subprocess.run(
            [sys.executable, "-I", str(HERE / "bump_checks.py"), branch, commit]
        )
    git("checkout", "-q", "--detach", start)
    return 1 if failed else 0


# run as a script, not when imported by a test
if __name__ == "__main__":
    sys.exit(main())
