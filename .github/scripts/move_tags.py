#!/usr/bin/env python3
"""Move the MOVING tags (`testing`) of an image to a digest that is already pushed and SIGNED. Usage: move_tags.py <registry-image> <digest> <tag>...   (no tag: nothing to do)

A registry-side copy that keeps the digest, then a read-back (registry.settled). The one step that runs AFTER signing, so a run cancelled at any earlier point leaves `testing` on the
previous signed image (octarine-bins does the same: push by immutable tag, sign, verify, only then move `testing`). Exit 1 when a copy fails (after the retries) or the read-back still shows
another digest. Tools: skopeo.
"""
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ci  # noqa: E402
import registry  # noqa: E402


def main(argv):
    if len(argv) < 2:
        print("usage: move_tags.py <registry image> <digest> <tag>...", file=sys.stderr)
        return 1
    image, digest, *tags = argv
    if not re.fullmatch(r"sha256:[0-9a-f]{64}", digest):
        print(f"::error::move_tags.py: '{digest}' is not a digest", file=sys.stderr)
        return 1
    for tag in tags:
        rc = ci.retry_command(["skopeo", "copy", "--all", "--preserve-digests", f"docker://{image}@{digest}", f"docker://{image}:{tag}"])
        if rc != 0:
            return rc
        registry.settled(image, tag, digest)
        print(f"moved {tag} -> {digest}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
