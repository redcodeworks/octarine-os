#!/usr/bin/env python3
"""Decide whether a push to main can promote an already tested `testing` image to
`latest` (retag the same digest, no rebuild) and print key=value lines (for
$GITHUB_OUTPUT). Usage: plan_promote.py <event> <ref> <after>

  promote=true|false
  source_tag=testing-<short sha>   (only when promote=true)
  source_digest=<digest>           (only when promote=true)

Environment: PROMOTE_ENABLED (must be `true`), IMAGE (the registry image; its
`testing-<sha>` tags are looked up).

Promote only when all hold:
  * event is push, ref is refs/heads/main, and <after> is a merge commit (two parents);
  * the default-image inputs (vanilla_inputs, inputs_hash.py: every file except docs and
    the dx-only files) of the testing side (<after>^2) and of <after> are equal;
  * walking first-parent history back from <after>^2, the nearest commit C that has a
    published `testing-<short sha>` image is reached without crossing a commit whose
    vanilla_inputs differ (so a docs-only or dx-only testing tip, which has no image of
    its own, promotes the image of the commit behind it).
Anything else (schedule, dispatch, non-merge push, differing inputs, no image, disabled)
means build. EXCEPT a registry that cannot be read (a read error, not an absent tag):
that fails the plan, because "unreadable" is not "no tested image" and a rebuild on main
would publish something that was never tested.
"""

import os
import sys
from pathlib import Path

here = Path(__file__).resolve().parent
sys.path[:0] = [str(here / "00-lib"), str(here)]
import ci  # noqa: E402
import inputs_hash as ih  # noqa: E402


def no(reason):
    """Report that no promotion applies and stop.

    Receives the reason; logs it, writes `promote=false` as the result and exits 0
    through SystemExit, so the caller falls back to a normal build.
    """
    ci.note(f"no promote: {reason}")
    ci.result("promote=false")
    raise SystemExit(0)


def main(argv=None):
    """Decide whether this push to main can promote an image already built on testing.

    Receives the event, the ref and the commit (the merge commit, default HEAD).
    Writes the `promote=` lines (and the source tag and digest when true) as the
    result. Returns 0, or 1 when the registry cannot be read: unreadable is not "no
    tested image".
    """
    ap = ci.arg_parser(__doc__)
    ap.add_argument("event")
    ap.add_argument("ref")
    ap.add_argument("after", nargs="?", default="HEAD")
    args = ap.parse_args(argv)
    event, ref, after = args.event, args.ref, args.after or "HEAD"

    # promotion can be switched off by the repository variable
    if os.environ.get("PROMOTE_ENABLED") != "true":
        no("PROMOTE_ENABLED is not 'true'")
    # only a push to main can promote
    if not (event == "push" and ref == "refs/heads/main"):
        no(f"not a push to main ({event} {ref})")
    # a promotion needs a merge commit: its second parent is the testing tip
    if not ci.git_ok("cat-file", "-e", f"{after}^2^{{commit}}"):
        no(f"{after} is not a merge commit")
    # an octopus merge has no single testing tip to promote
    if ci.git_ok("cat-file", "-e", f"{after}^3^{{commit}}"):
        no("octopus merge")
    tip = ci.git("rev-parse", f"{after}^2")

    # main must hold exactly the default-image inputs that the testing tip was built
    # from
    if ih.vanilla_inputs(tip) != ih.vanilla_inputs(after):
        no("main differs from the testing tip in the default-image inputs")
    # find the nearest testing image built from the same inputs; a read error fails the
    # plan
    try:
        tag, digest = ih.nearest_image_for_inputs(tip)
    except ih.Unreadable as e:
        # a registry read error is not "no tested image": falling back to a rebuild
        # would put an UNTESTED build on latest. Fail the plan; a re-run decides again.
        ci.log.error(
            f"cannot decide whether a tested testing image exists for {tip}: {e}"
        )
        return 1
    except ih.NoImage as e:
        no(str(e))
    ci.note(f"promote: {tag} ({digest}) covers {tip}")
    ci.result(f"promote=true\nsource_tag={tag}\nsource_digest={digest}")
    return 0


# run as a script, not when imported by a test
if __name__ == "__main__":
    sys.exit(main())
