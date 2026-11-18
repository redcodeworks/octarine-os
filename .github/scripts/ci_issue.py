#!/usr/bin/env python3
"""One issue per ongoing failure of a variant image (dx or gx, one label each: ci-failure-dx, ci-failure-gx) / its `latest` publishing on main, without duplicates (deduplicated on the LABEL,
not on the title). Usage: ci_issue.py fail|recover

  fail      a run failed: open the issue, or add a comment to the one that is already open
  recover   `latest` moved: comment "recovered" on the open issue and close it (nothing to do when none is open)

Why it exists: a run that was started by a dispatch with the default GITHUB_TOKEN probably sends no failure e-mail to anybody (undocumented), and a daily failure that holds `latest` back must
reach the repository owner. The issue does (owner and watchers).

Environment: GITHUB_TOKEN (permission issues: write), GITHUB_REPOSITORY, SHA (the commit of the run), CHANNEL (default latest), RUN_URL (default: this run), NEEDS_JSON (toJSON(needs), optional: names
the failed jobs), LABEL (default ci-failure-dx), DOCS_URL (the CLAUDE.md section), NOW (default: today's date, for tests), and for the default build's alert (LABEL=ci-failure-default): ISSUE_TITLE,
ISSUE_BODY (the text of a new issue), LABEL_DESC, FAIL_COMMENT and RECOVER_COMMENT.
"""

import json
import os
import sys
import time
from pathlib import Path

from githubkit.exception import RequestFailed

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ci  # noqa: E402

env = os.environ.get


def failed_jobs() -> str:
    """The names of the jobs of NEEDS_JSON (toJSON(needs)) whose result is failure."""
    try:
        return ", ".join(k for k, v in json.loads(env("NEEDS_JSON") or "{}").items() if v.get("result") == "failure")
    except ValueError, AttributeError:
        return ""


def main(argv=None):
    ap = ci.arg_parser(__doc__)
    ap.add_argument("mode", choices=["fail", "recover"])
    mode = ap.parse_args(argv).mode
    owner, name = os.environ["GITHUB_REPOSITORY"].split("/")
    repo = {"owner": owner, "repo": name}
    sha = os.environ["SHA"]
    channel = env("CHANNEL") or "latest"
    label = env("LABEL") or "ci-failure-dx"
    run_url = env("RUN_URL") or f"{env('GITHUB_SERVER_URL') or 'https://github.com'}/{owner}/{name}/actions/runs/{env('GITHUB_RUN_ID') or '0'}"
    docs = env("DOCS_URL") or f"https://github.com/{owner}/{name}/blob/main/CLAUDE.md#publishing-latest-one-image-at-a-time"
    now = env("NOW") or time.strftime("%Y-%m-%d", time.gmtime())
    failed = failed_jobs() or "see the run"
    gh = ci.github()  # keep the client: gh.rest only holds a weak reference to it
    rest = gh.rest

    def open_issue():
        issues = rest.issues.list_for_repo(labels=label, state="open", per_page=1, **repo).parsed_data
        return issues[0].number if issues else None

    def comment(number, body):
        rest.issues.create_comment(issue_number=number, data={"body": body}, **repo)

    if mode == "fail":
        try:
            rest.issues.create_label(data={"name": label, "color": "B60205", "description": env("LABEL_DESC") or "dx or latest was not published (one open issue at a time)"}, **repo)
        except RequestFailed:
            pass  # the label exists already
        number = open_issue()
        if number is None and env("ISSUE_BODY"):
            rest.issues.create(data={"title": env("ISSUE_TITLE") or sys.exit("ISSUE_TITLE: parameter null or not set"), "body": env("ISSUE_BODY"), "labels": [label]}, **repo)
            ci.log.info(f"opened an issue for {run_url}")
        elif number is not None and env("FAIL_COMMENT"):
            comment(number, f"{env('FAIL_COMMENT')} ({now}): {run_url} (commit {sha}).")
            ci.log.info(f"commented on #{number} for {run_url}")
        elif number is None:
            body = f"""The dx image of channel {channel} (or the publication of its `latest`) failed on main, so `octarine-os-dx:latest` stays on the previous image (the default image publishes its own `latest` independently).

- Run: {run_url}
- Commit: {sha}
- Failed job(s): {failed}

What you can do: re-run the failed dx run (a green re-run publishes). The default image is not held back by dx. See {docs}.

Later failures are added to this issue as comments; it closes itself when `latest` moves again."""
            rest.issues.create(data={"title": f"dx/latest not published: {channel} {sha[:7]}", "body": body, "labels": [label]}, **repo)
            ci.log.info(f"opened an issue for {run_url}")
        else:
            comment(number, f"Failed again ({now}): {run_url} (commit {sha}, failed job(s): {failed}).")
            ci.log.info(f"commented on #{number} for {run_url}")
        return 0
    number = open_issue()
    if number is None:
        ci.log.info(f"no open {label} issue: nothing to close")
        return 0
    comment(number, f"recovered: {env('RECOVER_COMMENT')} ({run_url}, commit {sha}, {now})." if env("RECOVER_COMMENT") else f"recovered: {run_url} moved `latest` (commit {sha}, {now}).")
    rest.issues.update(issue_number=number, data={"state": "closed"}, **repo)
    ci.log.info(f"closed #{number}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
