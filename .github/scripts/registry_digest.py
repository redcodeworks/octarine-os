#!/usr/bin/env python3
"""Print the manifest digest of <image>:<tag> (the sha256 of the raw manifest bytes, the
same for every tag that points at the same content). Usage: registry_digest.py <image>
<tag>

Exit status (the contract the workflow steps read): 0 the digest is printed; 3 the tag
does not exist; 4 the registry could not be read after the retries.
"""

import sys
from pathlib import Path

here = Path(__file__).resolve().parent
sys.path[:0] = [str(here / "00-lib"), str(here)]
import ci  # noqa: E402
import registry  # noqa: E402


def main(argv=None):
    """Print the manifest digest of an image tag.

    Receives the image and the tag as arguments; writes the digest as the result.
    Returns 0 when printed, 3 when the tag does not exist and 4 when the registry
    could not be read (already retried): the exit code is the contract the workflow
    steps read.
    """
    ap = ci.arg_parser(__doc__)
    ap.add_argument("image", help="registry/owner/name")
    ap.add_argument("tag")
    args = ap.parse_args(argv)

    # keep a missing tag (3) apart from a read error (4)
    try:
        ci.result(registry.digest(args.image, args.tag))
    except registry.Absent as e:
        ci.log.error(str(e))
        return 3
    except registry.ReadError as e:
        ci.log.error(str(e))
        return 4
    return 0


# run as a script, not when imported by a test
if __name__ == "__main__":
    sys.exit(main())
