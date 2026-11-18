#!/usr/bin/env python3
"""Read from a registry so that "the registry could not be read" is never mistaken for "it is not there". Usage: registry_read.py raw|config <image reference without docker://>

Prints the raw manifest or the image config JSON. Exit status (the contract the workflow steps read): 0 the answer is on stdout; 3 ABSENT; 4 READ ERROR, after the retries (RETRY_TRIES, RETRY_DELAY).
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ci  # noqa: E402
import registry  # noqa: E402


def main(argv=None):
    ap = ci.arg_parser(__doc__)
    ap.add_argument("mode", choices=["raw", "config"])
    ap.add_argument("ref")
    args = ap.parse_args(argv)
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


if __name__ == "__main__":
    sys.exit(main())
