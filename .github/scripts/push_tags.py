#!/usr/bin/env python3
"""Publish one built image under several tags with ONE manifest digest. Usage:
push_tags.py <local-image> <registry-image> <tag> [<tag>...]

The first tag is pushed with `podman push --digestfile`; every other tag is a
registry-side copy of that digest (`skopeo copy --all --preserve-digests`), so all tags
point at the same manifest and one signature (which belongs to the digest) covers them.
Pushing the same local image once per tag does not do that: podman writes a manifest per
push and the digests of the tags differ although the content is the same (observed
2026-11-10 on octarine-os:testing vs testing-cc213cb), which is what kept the dx
promotion from ever matching. After every copy the digest of the tag is read back
(registry.settled: polled, reads can lag a write) and must equal the pushed one. Output:
`digests=<digest>` appended to $GITHUB_OUTPUT (when set), and printed. Tools: podman,
skopeo.
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ci  # noqa: E402
import registry  # noqa: E402


def main(argv=None):
    """Push a local image under several tags with one manifest digest.

    Receives the local image, the registry image and the tags. The first tag is
    pushed; every other tag is a registry-side copy of that digest, each read back
    until it settles. Writes `digests=<digest>` as the result and step output.
    Returns 0, or 1 when a push, copy or read-back fails.
    """
    ap = ci.arg_parser(__doc__)
    ap.add_argument("local_image")
    ap.add_argument("registry_image")
    ap.add_argument("tags", nargs="+", metavar="tag")
    args = ap.parse_args(argv)
    first, *others = args.tags

    # any network or read-back failure stops the publication
    try:
        digest = registry.push(args.local_image, f"{args.registry_image}:{first}")
        # podman's digestfile is the manifest it wrote; the registry must agree
        # before anything is copied
        registry.settled(args.registry_image, first, digest)
        # the other tags copy the pushed digest instead of pushing again
        for tag in others:
            registry.copy(
                f"{args.registry_image}@{digest}", f"{args.registry_image}:{tag}"
            )
            registry.settled(args.registry_image, tag, digest)
    except (ci.NetworkError, registry.ReadError) as e:
        ci.log.error(str(e))
        return 1
    ci.log.info(f"pushed {' '.join(args.tags)} -> {digest}")
    ci.emit("digests", digest)
    return 0


# run as a script, not when imported by a test
if __name__ == "__main__":
    sys.exit(main())
