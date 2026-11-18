#!/usr/bin/env python3
"""Start the dx or gx run of build-variant.yml for a commit the pipeline just built, and
FAIL if no run appears. Usage: dispatch_variant.py <channel> <sha> [<base_digest>]

Environment: REF (the branch to dispatch on, main or testing), GITHUB_REPOSITORY,
GITHUB_TOKEN (the default token with `actions: write`), POLL_TRIES (default 12),
POLL_WAIT seconds between tries (default 10), VARIANT (required: dx or gx, the `variant`
input of build-variant.yml and the run-name prefix; one call starts one variant, the two
variants are dispatched by two independent matrix legs), GITHUB_STEP_SUMMARY (optional).

Finding the run: the ids of the runs of this workflow on this branch are listed BEFORE
the dispatch, and the run is the first one that is not in that list, on this branch,
with the run-name (`<variant> <channel> <sha>`) as its title (the variant is in it, so
the other variant's concurrent run is never mistaken for this one). A fresh run carries
the workflow name for its first seconds, so the poll waits for the title. No clock is
used. No run found within the time fails the step (the base build stays green, this job
is red, and re-running it dispatches again). The variant's run itself is not waited for.
"""

import os
import re
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ci  # noqa: E402

WORKFLOW = "build-variant.yml"


def main(argv=None):
    """Dispatch the variant build workflow and wait for the run it starts.

    Receives the channel (testing or latest), the full commit sha and an optional
    base digest; reads REF, VARIANT and GITHUB_REPOSITORY and the polling settings
    POLL_WAIT and POLL_TRIES. Returns 0 once the new run appears (its URL goes to
    the summary), 2 for an invalid argument or ref, 1 when the dispatch fails or no
    run appears in time.
    """
    ap = ci.arg_parser(__doc__)
    ap.add_argument("channel", choices=["testing", "latest"])
    ap.add_argument("sha")
    ap.add_argument("base_digest", nargs="?", default="")
    args = ap.parse_args(argv)
    ref, variant = os.environ["REF"], os.environ["VARIANT"]
    owner, name = os.environ["GITHUB_REPOSITORY"].split("/")
    repo = {"owner": owner, "repo": name}
    # the first failed validation names the problem
    problem = next(
        (
            msg
            for ok, msg in (
                (variant in ("dx", "gx"), f"unknown variant '{variant}'"),
                (
                    re.fullmatch(r"[0-9a-f]{40}", args.sha),
                    f"'{args.sha}' is not a full commit sha",
                ),
                (
                    not args.base_digest
                    or re.fullmatch(r"sha256:[0-9a-f]{64}", args.base_digest),
                    f"'{args.base_digest}' is not a sha256 digest",
                ),
                (ref in ("main", "testing"), f"refusing to dispatch on '{ref}'"),
            )
            if not ok
        ),
        None,
    )
    # refuse before anything is dispatched
    if problem:
        ci.log.error(problem)
        return 2
    title = f"{variant} {args.channel} {args.sha}"
    poll_wait, tries = ci.int_env("POLL_WAIT", 10), ci.int_env("POLL_TRIES", 12)
    gh = ci.github()  # keep the client: gh.rest only holds a weak reference to it
    rest = gh.rest

    def list_runs():
        """List the recent dispatched runs of the workflow on the branch."""
        return rest.actions.list_workflow_runs(
            workflow_id=WORKFLOW,
            branch=ref,
            event="workflow_dispatch",
            per_page=50,
            **repo,
        ).parsed_data.workflow_runs

    # runs that exist before the dispatch, to tell the new one apart
    before = {r.id for r in list_runs()}
    inputs = {
        "variant": variant,
        "channel": args.channel,
        "sha": args.sha,
        **({"base_digest": args.base_digest} if args.base_digest else {}),
    }
    # a rejected dispatch is reported with the SDK's own message
    try:
        rest.actions.create_workflow_dispatch(
            workflow_id=WORKFLOW, data={"ref": ref, "inputs": inputs}, **repo
        )
    except Exception as e:
        # the SDK's own error, whatever its type, is the reason to print
        ci.log.error(
            f"could not dispatch {WORKFLOW} on {ref} (channel {args.channel}, {args.sha}): {e}"
        )
        return 1
    # a poll, not a retry: the dispatched run does not exist yet for a moment
    for i in range(1, tries + 1):
        # the new run: right title and branch, and not one of the earlier runs
        new = next(
            (
                r
                for r in list_runs()
                if r.display_title == title
                and r.head_branch == ref
                and r.id not in before
            ),
            None,
        )
        # found: report it and finish
        if new:
            ci.summary(f"Started: {new.html_url}")
            ci.append_to(
                "GITHUB_STEP_SUMMARY",
                f"{variant} {args.channel} for {args.sha}: {new.html_url}",
            )
            return 0
        # wait between polls, but not after the last one
        if i != tries:
            time.sleep(poll_wait)
    ci.log.error(
        f"{WORKFLOW} was dispatched but no new run titled '{title}' appeared on {ref} in {tries * poll_wait} s; re-run this job to dispatch again"
    )
    return 1


# run as a script, not when imported by a test
if __name__ == "__main__":
    sys.exit(main())
