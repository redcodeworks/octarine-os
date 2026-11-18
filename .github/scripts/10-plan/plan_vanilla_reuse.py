#!/usr/bin/env python3
"""Decide whether a push to `testing` can skip the default image build because an image
built from identical inputs is already published (same vanilla_inputs, see
inputs_hash.py: a dx-only or docs-only change), and print key=value lines (for
$GITHUB_OUTPUT). Usage: plan_vanilla_reuse.py <event> <ref> <after>

  reuse=true|false
  source_tag=testing-<short sha>   (only when reuse=true)
  source_digest=<digest>           (only when reuse=true)
  inputs=<vanilla_inputs of <after>>

Environment: IMAGE (the registry image). Nothing is published or retagged: the image of
the nearest earlier commit stays the `testing` image.
"""

import sys
from pathlib import Path

here = Path(__file__).resolve().parent
sys.path[:0] = [str(here.parent / "00-lib"), str(here)]
import ci  # noqa: E402
import inputs_hash as ih  # noqa: E402


def no(reason):
    """Report that no reuse applies and stop.

    Receives the reason; logs it, writes `reuse=false` as the result and exits 0
    through SystemExit, so the caller builds.
    """
    ci.note(f"no reuse: {reason}")
    ci.result("reuse=false")
    raise SystemExit(0)


def main(argv=None):
    """Decide whether a testing image can be reused for the tip instead of building.

    Receives the event, the ref and the commit (default HEAD). Writes `inputs=` (the
    default-image input hash), then `reuse=true` with the source tag and digest, or
    `reuse=false`. Returns 0; a registry read error is a warning and means build.
    """
    ap = ci.arg_parser(__doc__)
    ap.add_argument("event")
    ap.add_argument("ref")
    ap.add_argument("after", nargs="?", default="HEAD")
    args = ap.parse_args(argv)
    event, ref, after = args.event, args.ref, args.after or "HEAD"

    # only a push to testing looks for a reusable image
    if not (event == "push" and ref == "refs/heads/testing"):
        no(f"not a push to testing ({event} {ref})")
    ci.result(f"inputs={ih.vanilla_inputs(after)}")

    # walk back to the nearest image built from the same inputs; a read error means
    # build
    try:
        tag, digest = ih.nearest_image_for_inputs(after)
    except ih.Unreadable as e:
        ci.log.warning(
            f"registry read error while looking for a reusable testing image (building instead): {e}"
        )
        no(str(e))
    except ih.NoImage as e:
        no(str(e))
    ci.note(
        f"reuse: {tag} ({digest}) was built from the same default-image inputs as {after}"
    )
    ci.result(f"reuse=true\nsource_tag={tag}\nsource_digest={digest}")
    return 0


# run as a script, not when imported by a test
if __name__ == "__main__":
    sys.exit(main())
