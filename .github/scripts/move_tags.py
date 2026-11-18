#!/usr/bin/env python3
"""Move the MOVING tags (`testing`) of an image to a digest that is already pushed and
SIGNED. Usage: move_tags.py <registry-image> <digest> [<tag>...]   (no tag: nothing to
do)

A registry-side copy that keeps the digest, then a read-back (registry.settled). The one
step that runs AFTER signing, so a run cancelled at any earlier point leaves `testing`
on the previous signed image (octarine-bins does the same: push by immutable tag, sign,
verify, only then move `testing`). Exit 1 when a copy fails (after the retries) or the
read-back still shows another digest.
"""

import re
import sys
from pathlib import Path

here = Path(__file__).resolve().parent
sys.path[:0] = [str(here / "00-lib"), str(here)]
import ci  # noqa: E402
import registry  # noqa: E402


def main(argv=None):
    """Move registry tags to an existing digest and check each move.

    Receives the image, the digest and the tags. Each tag is copied registry-side to
    the digest and read back until it shows it. Returns 0, or 1 for a malformed
    digest, a failed copy or a tag that does not settle.
    """
    ap = ci.arg_parser(__doc__)
    ap.add_argument("image")
    ap.add_argument("digest")
    ap.add_argument("tags", nargs="*", metavar="tag")
    args = ap.parse_args(argv)

    # a tag must never be moved to something that is not a digest
    if not re.fullmatch(r"sha256:[0-9a-f]{64}", args.digest):
        ci.log.error(f"move_tags.py: '{args.digest}' is not a digest")
        return 1
    # stop at the first tag that fails: a half-moved set is reported, not hidden
    try:
        # move each tag in order
        for tag in args.tags:
            registry.copy(f"{args.image}@{args.digest}", f"{args.image}:{tag}")
            registry.settled(args.image, tag, args.digest)
            ci.log.info(f"moved {tag} -> {args.digest}")
    except (ci.NetworkError, registry.ReadError) as e:
        ci.log.error(str(e))
        return 1
    return 0


# run as a script, not when imported by a test
if __name__ == "__main__":
    sys.exit(main())
