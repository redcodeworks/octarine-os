#!/usr/bin/env python3
"""Print the manifest digest of ${IMAGE}:<tag> (IMAGE is registry/owner/name). Usage: IMAGE=ghcr.io/o/n registry_digest.py <tag>

The digest is that of the raw manifest (or manifest list) bytes, so it is the same for every tag that points at the same content. Exit status (the contract of every registry lookup):
0 the digest is printed; 3 the tag does not exist; 4 the registry could not be read (retried): a caller must not take that for "absent".
"""
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import registry  # noqa: E402


def main(argv):
    if len(argv) != 1 or not os.environ.get("IMAGE"):
        print("registry_digest.py: usage: IMAGE=<registry/owner/name> registry_digest.py <tag>", file=sys.stderr)
        return 2
    try:
        print(registry.digest(os.environ["IMAGE"], argv[0]))
    except registry.RegistryError as e:
        return e.code
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
