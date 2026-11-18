#!/usr/bin/env python3
"""Read from a registry so that "the registry could not be read" is never mistaken for
"it is not there". Usage: registry_read.py raw|config <image reference without
docker://>

Prints the raw manifest or the image config JSON. Exit status (the contract the workflow
steps read): 0 the answer is on stdout; 3 ABSENT; 4 READ ERROR, after the retries
(RETRY_TRIES, RETRY_DELAY).
"""

import sys
from pathlib import Path

here = Path(__file__).resolve().parent
sys.path[:0] = [str(here.parent / "00-lib"), str(here)]
import ci  # noqa: E402
import registry  # noqa: E402


def main(argv=None):
    """Write the raw manifest or the image config of a reference to stdout.

    Receives the mode (raw or config) and the image reference. Returns 0 with the
    bytes on stdout, 3 when the reference is absent and 4 when the registry could
    not be read after the retries.
    """
    ap = ci.arg_parser(__doc__)
    ap.add_argument("mode", choices=["raw", "config"])
    ap.add_argument("ref")
    args = ap.parse_args(argv)

    # keep a missing reference (3) apart from a read error (4)
    try:
        data = registry.read(args.mode, args.ref)
    except registry.Absent as e:
        ci.log.error(str(e))
        return 3
    except registry.ReadError as e:
        ci.log.error(str(e))
        return 4
    sys.stdout.buffer.write(data)
    return 0


# run as a script, not when imported by a test
if __name__ == "__main__":
    sys.exit(main())
