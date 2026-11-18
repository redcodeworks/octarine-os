#!/usr/bin/env python3
"""Decide whether a workflow run needs the heavy image build and print `true` or `false`. Usage: plan_build.py <event> [<before> [<after> [<ref>]]]

<event>           github.event_name
<before>/<after>  the commit range to diff: github.event.before and github.sha for pushes (after defaults to HEAD)
<ref>             github.ref (optional)

Rules:
  schedule, workflow_dispatch   always build
  push                          build unless every changed file in <before>..<after> is docs-only (docs_only.is_docs); an empty, all-zero or unknown <before> (new branch, force push) or an
                                empty diff builds. A push to refs/heads/testing is never skipped here: the diff of ONE push cannot tell whether an image exists for the tip (a batch of merges cancels
                                the builds of the earlier pushes), so the workflow's reuse step decides (plan_vanilla_reuse.py: reuse only an image with equal default-image inputs, else build)
The workflow keeps the required check names by always running an aggregate job; it never uses a workflow-level `paths:` filter, because required checks of a skipped workflow stay pending forever.
"""
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ci  # noqa: E402
import docs_only  # noqa: E402


def main(argv):
    if not argv or not argv[0]:
        sys.exit("event: parameter null or not set")
    event = argv[0]
    before = argv[1] if len(argv) > 1 else ""
    after = (argv[2] if len(argv) > 2 else "") or "HEAD"
    ref = argv[3] if len(argv) > 3 else ""
    if event in ("schedule", "workflow_dispatch"):
        print("true")
        return 0
    if event != "push":
        print(f"unknown event '{event}'", file=sys.stderr)
        return 1
    if not before or re.fullmatch(r"0+", before) or not ci.git_ok("cat-file", "-e", f"{before}^{{commit}}") or not ci.git_ok("cat-file", "-e", f"{after}^{{commit}}"):
        ci.err(f"no usable base commit ('{before}'): building")
        print("true")
        return 0
    changed = ci.git("diff", "--name-only", before, after).splitlines()
    if not changed:
        ci.err("empty diff: building")
        print("true")
        return 0
    for f in changed:
        if not docs_only.is_docs(f):
            ci.err(f"non-docs file changed ({f}): building")
            print("true")
            return 0
    if ref == "refs/heads/testing":
        ci.err(f"only docs changed ({len(changed)} files) on testing: the reuse check decides whether an image already covers the tip")
        print("true")
        return 0
    ci.err(f"only docs changed ({len(changed)} files): skipping the heavy build")
    print("false")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
