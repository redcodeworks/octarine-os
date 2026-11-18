#!/usr/bin/env python3
"""Read a tag back after a write until it shows the expected digest ("settled"). Usage: registry_settled.py <image (registry/owner/name)> <tag> <expected digest>

The registry may answer a read right after a push or a copy with the PREVIOUS manifest of the tag (seen on GHCR 2026-11-14), or fail the read for a moment. Environment:
READBACK_TRIES (default 6), READBACK_WAIT (seconds apart, default 5). Exit 0 as soon as one read shows the expected digest; exit 1 when after the last read the tag still shows another
digest (a wrong copy) or could not be read, with the last answer in the message (the digest, "absent" or "unreadable").
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import registry  # noqa: E402


def main(argv):
    if len(argv) != 3:
        print("registry_settled.py: usage: registry_settled.py <image> <tag> <expected digest>", file=sys.stderr)
        return 2
    registry.settled(*argv)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
