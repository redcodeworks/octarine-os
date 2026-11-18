#!/usr/bin/env python3
"""`cosign verify` that tells a transient failure from a real verdict. Usage: cosign_check.py <cosign verify arguments...>

Used where the RESULT of a verification decides something (promote, skip, reuse). Exit status: 0 verified; 5 NOT VERIFIED (cosign said the signature is missing or wrong; nothing is retried);
4 READ ERROR (anything else, an image or tag that is not visible yet included; retried, still failing after the last try). cosign's stdout is discarded.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ci  # noqa: E402
import registry  # noqa: E402


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if not argv:
        ci.log.error("usage: cosign_check.py <cosign verify arguments...>")
        return 2
    try:
        registry.cosign_check(argv)
    except registry.NotVerified as e:
        ci.log.error(f"cosign-check: {e}")
        return 5
    except registry.ReadError as e:
        ci.log.error(f"cosign-check: {e}")
        return 4
    return 0


if __name__ == "__main__":
    sys.exit(main())
