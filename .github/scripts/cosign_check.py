#!/usr/bin/env python3
"""`cosign verify` that tells a transient failure from a real one. Usage: cosign_check.py <cosign verify arguments...>

Used wherever the RESULT of a verification decides something (promote, skip, reuse, fall back). Environment: RETRY_TRIES (3), RETRY_DELAY (5). Exit status: 0 verified; 5 NOT VERIFIED
(cosign said so explicitly: no signatures found, no matching signatures, an invalid signature, the image is not there; nothing is retried); 4 READ ERROR (anything else: network,
registry, timeout; retried, still failing after the last try); 2 usage. cosign's own message goes to stderr; its stdout is discarded (callers only want the verdict).
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import registry  # noqa: E402


def main(argv):
    if not argv:
        print("usage: cosign_check.py <cosign verify arguments...>", file=sys.stderr)
        return 2
    return registry.verify_code(argv)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
