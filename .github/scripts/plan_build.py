#!/usr/bin/env python3
"""Decide whether a workflow run needs the heavy image build and print `true` or
`false`. Usage: plan_build.py <event> [<before> [<after> [<ref>]]]

<event>           github.event_name
<before>/<after>  the commit range to diff: github.event.before and github.sha for
                  pushes (after defaults to HEAD)
<ref>             github.ref (optional)

Rules:
  schedule, workflow_dispatch   always build
  push                          build unless every changed file in <before>..<after> is
                                docs-only (docs_only.is_docs); an empty, all-zero or
                                unknown <before> (new branch, force push) or an empty
                                diff builds. A push to refs/heads/testing is never
                                skipped here: the diff of ONE push cannot tell whether
                                an image exists for the tip (a batch of merges cancels
                                the builds of the earlier pushes), so the workflow's
                                reuse step decides (plan_vanilla_reuse.py: reuse only an
                                image with equal default-image inputs, else build)
The workflow keeps the required check names by always running an aggregate job; it never
uses a workflow-level `paths:` filter, because required checks of a skipped workflow
stay pending forever.
"""

import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ci  # noqa: E402
import docs_only  # noqa: E402


def main(argv=None):
    """Run the plan: decide whether the heavy image build is needed.

    Receives the event name, the before and after commits and the ref (see the
    module docstring). Writes `true` or `false` as the result and the reason as a
    log line; returns 0, or 1 for an event it does not know.
    """
    ap = ci.arg_parser(__doc__)
    ap.add_argument("event")
    ap.add_argument("before", nargs="?", default="")
    ap.add_argument("after", nargs="?", default="HEAD")
    ap.add_argument("ref", nargs="?", default="")
    args = ap.parse_args(argv)
    event, before, after, ref = args.event, args.before, args.after or "HEAD", args.ref
    # a scheduled or dispatched run always builds, whatever changed
    if event in ("schedule", "workflow_dispatch"):
        ci.result("true")
        return 0
    # only a push has a commit range to judge; anything else is an error
    if event != "push":
        ci.note(f"unknown event '{event}'")
        return 1
    # a missing or unknown base commit (new branch, force push) leaves nothing to diff
    if (
        not before
        or re.fullmatch(r"0+", before)
        or not ci.git_ok("cat-file", "-e", f"{before}^{{commit}}")
        or not ci.git_ok("cat-file", "-e", f"{after}^{{commit}}")
    ):
        ci.note(f"no usable base commit ('{before}'): building")
        ci.result("true")
        return 0
    changed = ci.git("diff", "--name-only", before, after).splitlines()
    # an empty diff cannot prove docs-only, so it builds
    if not changed:
        ci.note("empty diff: building")
        ci.result("true")
        return 0
    # the first file that is not documentation decides: build
    if code := next((f for f in changed if not docs_only.is_docs(f)), None):
        ci.note(f"non-docs file changed ({code}): building")
        ci.result("true")
        return 0
    # testing is never skipped here: the reuse step decides whether an image covers the
    # tip
    if ref == "refs/heads/testing":
        ci.note(
            f"only docs changed ({len(changed)} files) on testing: the reuse check decides whether an image already covers the tip"
        )
        ci.result("true")
        return 0
    ci.note(f"only docs changed ({len(changed)} files): skipping the heavy build")
    ci.result("false")
    return 0


# run as a script, not when imported by a test
if __name__ == "__main__":
    sys.exit(main())
