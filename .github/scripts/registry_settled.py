#!/usr/bin/env python3
"""Read a tag back after a write until it shows the expected digest. Usage: registry_settled.py <image> <tag> <expected digest>   (env READBACK_TRIES 6, READBACK_WAIT 5)

The registry may answer a read right after a push or a copy with the PREVIOUS manifest of the tag (seen on GHCR 2026-11-14), or fail the read for a moment. Exit 0 as soon as one read shows
the expected digest; exit 1 when after the last read the tag still shows another digest, absent or unreadable, with the last answer in the message.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ci  # noqa: E402
import registry  # noqa: E402


def main(argv=None):
    ap = ci.arg_parser(__doc__)
    ap.add_argument("image")
    ap.add_argument("tag")
    ap.add_argument("digest")
    args = ap.parse_args(argv)
    try:
        registry.settled(args.image, args.tag, args.digest)
    except registry.ReadError as e:
        ci.log.error(str(e))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
