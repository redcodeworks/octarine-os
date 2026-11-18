#!/usr/bin/env python3
"""One issue per ongoing failure of a variant image (dx or gx, one label each: ci-failure-dx, ci-failure-gx) / its `latest` publishing on main, without duplicates (deduplicated on the LABEL,
not on the title). Usage: ci_issue.py fail|recover

  fail      a run failed: open the issue, or add a comment to the one that is already open
  recover   `latest` moved: comment "recovered" on the open issue and close it (nothing to do when none is open)

Why it exists: a run that was started by a dispatch with the default GITHUB_TOKEN probably sends no failure e-mail to anybody (undocumented), and a daily failure that holds `latest` back must
reach the repository owner. The issue does (owner and watchers).

Environment: GH_TOKEN (permission issues: write), GITHUB_REPOSITORY, SHA (the commit of the run), CHANNEL (default latest), RUN_URL (default: this run), NEEDS_JSON (toJSON(needs), optional: names
the failed jobs), LABEL (default ci-failure-dx), DOCS_URL (the CLAUDE.md section), NOW (default: today's date, for tests), and for the default build's alert (LABEL=ci-failure-default): ISSUE_TITLE,
ISSUE_BODY (the text of a new issue), LABEL_DESC, FAIL_COMMENT and RECOVER_COMMENT. Tools: gh.
"""
import json
import os
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ci  # noqa: E402

env = os.environ.get


def gh(*args, check=True, quiet=False):
    p = ci.run(["gh", *args], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL if quiet else None)
    if check and p.returncode != 0:
        raise SystemExit(p.returncode)
    return p.stdout.decode()


def main(argv):
    if len(argv) != 1 or argv[0] not in ("fail", "recover"):
        print("usage: ci_issue.py fail|recover", file=sys.stderr)
        return 2
    mode = argv[0]
    repo = env("GITHUB_REPOSITORY") or sys.exit("GITHUB_REPOSITORY: parameter null or not set")
    sha = env("SHA") or sys.exit("SHA: parameter null or not set")
    channel = env("CHANNEL") or "latest"
    label = env("LABEL") or "ci-failure-dx"
    run_url = env("RUN_URL") or f"{env('GITHUB_SERVER_URL') or 'https://github.com'}/{repo}/actions/runs/{env('GITHUB_RUN_ID') or '0'}"
    docs = env("DOCS_URL") or f"https://github.com/{repo}/blob/main/CLAUDE.md#publishing-latest-one-image-at-a-time"
    now = env("NOW") or time.strftime("%Y-%m-%d", time.gmtime())
    label_desc = env("LABEL_DESC") or "dx or latest was not published (one open issue at a time)"
    short = sha[:7]

    failed = ""
    if env("NEEDS_JSON"):
        try:
            failed = ", ".join(k for k, v in json.loads(env("NEEDS_JSON")).items() if v.get("result") == "failure")
        except (ValueError, AttributeError):
            failed = ""

    def open_issue():
        return gh("issue", "list", "-R", repo, "--label", label, "--state", "open", "--limit", "1", "--json", "number", "--jq", ".[0].number // empty").strip()

    if mode == "fail":
        ci.run(["gh", "label", "create", label, "-R", repo, "--color", "B60205", "--description", label_desc], stderr=subprocess.DEVNULL)  # an existing label is fine
        num = open_issue()
        if not num and env("ISSUE_BODY"):
            gh("issue", "create", "-R", repo, "--title", env("ISSUE_TITLE") or sys.exit("ISSUE_TITLE: parameter null or not set"), "--label", label, "--body", env("ISSUE_BODY"))
            print(f"opened an issue for {run_url}")
        elif num and env("FAIL_COMMENT"):
            gh("issue", "comment", num, "-R", repo, "--body", f"{env('FAIL_COMMENT')} ({now}): {run_url} (commit {sha}).")
            print(f"commented on #{num} for {run_url}")
        elif not num:
            body = f"""The dx image of channel {channel} (or the publication of its `latest`) failed on main, so `octarine-os-dx:latest` stays on the previous image (the default image publishes its own `latest` independently).

- Run: {run_url}
- Commit: {sha}
- Failed job(s): {failed or 'see the run'}

What you can do: re-run the failed dx run (a green re-run publishes). The default image is not held back by dx. See {docs}.

Later failures are added to this issue as comments; it closes itself when `latest` moves again."""
            gh("issue", "create", "-R", repo, "--title", f"dx/latest not published: {channel} {short}", "--label", label, "--body", body)
            print(f"opened an issue for {run_url}")
        else:
            gh("issue", "comment", num, "-R", repo, "--body", f"Failed again ({now}): {run_url} (commit {sha}, failed job(s): {failed or 'see the run'}).")
            print(f"commented on #{num} for {run_url}")
    else:
        num = open_issue()
        if not num:
            print(f"no open {label} issue: nothing to close")
            return 0
        if env("RECOVER_COMMENT"):
            rmsg = f"recovered: {env('RECOVER_COMMENT')} ({run_url}, commit {sha}, {now})."
        else:
            rmsg = f"recovered: {run_url} moved `latest` (commit {sha}, {now})."
        gh("issue", "comment", num, "-R", repo, "--body", rmsg)
        gh("issue", "close", num, "-R", repo)
        print(f"closed #{num}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
