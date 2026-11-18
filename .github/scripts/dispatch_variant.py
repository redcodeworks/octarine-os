#!/usr/bin/env python3
"""Start the dx or gx run of build-variant.yml for a commit the pipeline just built, and FAIL if no run appears. Usage: dispatch_variant.py <channel> <sha> [<base_digest>]

Environment: REF (the branch to dispatch on, main or testing), GITHUB_REPOSITORY, GH_TOKEN (the default token with `actions: write`), POLL_TRIES (default 12), POLL_WAIT seconds between tries
(default 10), VARIANT (required: dx or gx, the `variant` input of build-variant.yml and the run-name prefix; one call starts one variant, the two variants are dispatched by two independent
matrix legs), GITHUB_STEP_SUMMARY (optional; a failure to write to it never fails the step).

Finding the run. The dispatch API answers 204 unless the request carries `return_run_details: true`; `gh` 2.87.0 and later sends it and prints the run URL when stdout is not a terminal.
So: the URL printed by `gh workflow run` is used when there is one (its trailing number is the run id; the run is then checked for event and branch). A `gh` that prints no URL (an older one on
the runner) gets the snapshot approach: the ids of the runs of this workflow on this branch are listed BEFORE the dispatch, and the run is the first id that is not in that list, on this branch,
with the run-name (`<variant> <channel> <sha>`) as its title (the variant is in it, so the other variant's concurrent run is never mistaken for this one). No clock is used anywhere.
Either way, no run found within the time fails the step (the base build stays green, this job is red, and re-running it dispatches again). The variant's run itself is not waited for.
"""
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ci  # noqa: E402

WORKFLOW = "build-variant.yml"


def gh_json(args):
    """The parsed JSON of a gh command, or None when it fails or prints something else."""
    p = ci.capture(["gh", *args])
    if p.returncode != 0:
        return None
    try:
        return json.loads(p.stdout)
    except ValueError:
        return None


def main(argv):
    if len(argv) < 2:
        print("usage: dispatch_variant.py <channel> <sha> [<base_digest>]", file=sys.stderr)
        return 1
    channel, sha = argv[0], argv[1]
    base_digest = argv[2] if len(argv) > 2 else ""
    ref = os.environ.get("REF") or sys.exit("REF: parameter null or not set")
    repo = os.environ.get("GITHUB_REPOSITORY") or sys.exit("GITHUB_REPOSITORY: parameter null or not set")
    variant = os.environ.get("VARIANT") or sys.exit("VARIANT (dx or gx): parameter null or not set")
    for ok, msg in ((variant in ("dx", "gx"), f"unknown variant '{variant}'"),
                    (channel in ("testing", "latest"), f"unknown channel '{channel}'"),
                    (re.fullmatch(r"[0-9a-f]{40}", sha), f"'{sha}' is not a full commit sha"),
                    (not base_digest or re.fullmatch(r"sha256:[0-9a-f]{64}", base_digest), f"'{base_digest}' is not a sha256 digest"),
                    (ref in ("main", "testing"), f"refusing to dispatch on '{ref}'")):
        if not ok:
            print(f"::error::{msg}")
            return 2
    version = ci.capture(["gh", "--version"]).stdout.decode(errors="replace").splitlines()
    print(f"gh: {version[0] if version else ''}")
    title = f"{variant} {channel} {sha}"
    poll_wait = ci.int_env("POLL_WAIT", 10)
    tries = ci.int_env("POLL_TRIES", 12)

    def list_runs():
        return gh_json(["run", "list", "-R", repo, "--workflow", WORKFLOW, "--branch", ref, "--event", "workflow_dispatch", "--limit", "50",
                        "--json", "databaseId,displayTitle,headBranch,url"]) or []

    before = {str(r["databaseId"]) for r in list_runs()}

    args = ["-f", f"variant={variant}", "-f", f"channel={channel}", "-f", f"sha={sha}"]
    if base_digest:
        args += ["-f", f"base_digest={base_digest}"]
    p = ci.run(["gh", "workflow", "run", WORKFLOW, "-R", repo, "--ref", ref, *args], stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    out = p.stdout.decode(errors="replace").rstrip("\n")
    if p.returncode != 0:
        print(out)
        print(f"::error::could not dispatch {WORKFLOW} on {ref} (channel {channel}, {sha})")
        return 1
    print(out)

    def started(what):
        print(f"Started: {what}")
        ci.summary(f"{variant} {channel} for {sha}: {what}", echo=False)
        return 0

    # 1. the URL that gh printed (the API returned the run id). The run is checked by branch and event only: its title is the workflow name ("Build variant image") for the first seconds and
    # becomes the run-name (`dx <channel> <sha>`) later, so a title check would race (it did, on the first real run: gh 2.103.3 on the runner printed the right URL and the old check rejected
    # the title of a run that had just been created).
    urls = re.findall(r"https://[^ ]+/actions/runs/[0-9]+", out)
    if urls:
        url = urls[-1]
        run_id = url.rsplit("/", 1)[1]
        for _ in range(3):
            info = gh_json(["run", "view", run_id, "-R", repo, "--json", "event,headBranch"])
            if info is not None:
                if info.get("event") == "workflow_dispatch" and info.get("headBranch") == ref:
                    return started(url)
                print(f"::error::run {run_id} (from the dispatch) is a '{info.get('event')}' run on '{info.get('headBranch')}', expected a workflow_dispatch run on '{ref}'")
                return 1
            time.sleep(poll_wait)
        print(f"::error::run {run_id} ({url}) was returned by the dispatch but cannot be read")
        return 1

    # 2. no URL printed: the snapshot approach
    print("gh printed no run URL: looking for a run that was not there before the dispatch")
    for i in range(1, tries + 1):
        # a run that was not listed before the dispatch, on this branch, titled with the run-name (a fresh run has the workflow name for the first seconds: the loop waits)
        for r in list_runs():
            if r.get("displayTitle") == title and r.get("headBranch") == ref and str(r.get("databaseId")) not in before and r.get("url"):
                return started(r["url"])
        if i != tries:
            time.sleep(poll_wait)
    print(f"::error::{WORKFLOW} was dispatched but no new run titled '{title}' appeared on {ref} in {tries * poll_wait} s; re-run this job to dispatch again")
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
