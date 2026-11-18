#!/usr/bin/env python3
"""Move the MOVING tags (`testing`) of an image to a digest that is already pushed and SIGNED. Usage: move_tags.py <registry-image> <digest> [<tag>...]   (no tag: nothing to do)

A registry-side copy that keeps the digest, then a read-back (registry.settled). The one step that runs AFTER signing, so a run cancelled at any earlier point leaves `testing` on the previous
signed image (octarine-bins does the same: push by immutable tag, sign, verify, only then move `testing`). Exit 1 when a copy fails (after the retries) or the read-back still shows another digest.
"""
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ci  # noqa: E402
import registry  # noqa: E402


def main(argv=None):
    ap = ci.arg_parser(__doc__)
    ap.add_argument("image")
    ap.add_argument("digest")
    ap.add_argument("tags", nargs="*", metavar="tag")
    args = ap.parse_args(argv)
    if not re.fullmatch(r"sha256:[0-9a-f]{64}", args.digest):
        ci.log.error(f"move_tags.py: '{args.digest}' is not a digest")
        return 1
    try:
        for tag in args.tags:
            registry.copy(f"{args.image}@{args.digest}", f"{args.image}:{tag}")
            registry.settled(args.image, tag, args.digest)
            ci.log.info(f"moved {tag} -> {args.digest}")
    except (ci.NetworkError, registry.ReadError) as e:
        ci.log.error(str(e))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
