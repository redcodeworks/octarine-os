#!/usr/bin/env python3
"""Print the manifest digest of <image>:<tag> (the sha256 of the raw manifest bytes, the same for every tag that points at the same content). Usage: registry_digest.py <image> <tag>

Exit status (the contract the workflow steps read): 0 the digest is printed; 3 the tag does not exist; 4 the registry could not be read after the retries.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ci  # noqa: E402
import registry  # noqa: E402


def main(argv=None):
    ap = ci.arg_parser(__doc__)
    ap.add_argument("image", help="registry/owner/name")
    ap.add_argument("tag")
    args = ap.parse_args(argv)
    try:
        print(registry.digest(args.image, args.tag))
    except registry.Absent as e:
        ci.log.error(str(e))
        return 3
    except registry.ReadError as e:
        ci.log.error(str(e))
        return 4
    return 0


if __name__ == "__main__":
    sys.exit(main())
