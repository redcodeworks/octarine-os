#!/usr/bin/env python3
"""Publish one built image under several tags with ONE manifest digest. Usage: push_tags.py <local-image> <registry-image> <tag> [<tag>...]

The first tag is pushed with `podman push --digestfile`; every other tag is a registry-side copy of that digest (`skopeo copy --all --preserve-digests`), so all tags point at the same
manifest and one signature (which belongs to the digest) covers them. Pushing the same local image once per tag does not do that: podman writes a manifest per push and the digests of
the tags differ although the content is the same (observed 2026-11-10 on octarine-os:testing vs testing-cc213cb), which is what kept the dx promotion from ever matching.
After every copy the digest of the tag is read back from the registry (registry.settled: polled, reads can lag a write) and must equal the pushed one.
Output: `digests=<digest>` appended to $GITHUB_OUTPUT (when set), and printed. Tools: podman, skopeo.
"""
import re
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ci  # noqa: E402
import registry  # noqa: E402


def main(argv):
    if len(argv) < 3:
        if len(argv) == 2:
            print("::error::push_tags.py needs at least one tag", file=sys.stderr)
            return 1
        print("usage: push_tags.py <local image> <registry image> <tag>...", file=sys.stderr)
        return 1
    local_image, registry_image, first, *others = argv
    with tempfile.TemporaryDirectory() as d:
        digestfile = Path(d) / "digest"
        rc = ci.retry_command(["podman", "push", f"--digestfile={digestfile}", local_image, f"{registry_image}:{first}"])
        if rc != 0:
            return rc
        digest = "".join(digestfile.read_text().split()) if digestfile.exists() else ""
    if not re.fullmatch(r"sha256:[0-9a-f]{64}", digest):
        print(f"::error::podman push gave no digest for {first} ('{digest}')", file=sys.stderr)
        return 1
    # podman's digestfile is the digest of the manifest it wrote; the registry must agree before anything is copied
    registry.settled(registry_image, first, digest)
    for tag in others:
        rc = ci.retry_command(["skopeo", "copy", "--all", "--preserve-digests", f"docker://{registry_image}@{digest}", f"docker://{registry_image}:{tag}"])
        if rc != 0:
            return rc
        registry.settled(registry_image, tag, digest)
    print(f"pushed {first} {' '.join(others)} -> {digest}")
    print(f"digests={digest}")
    ci.output("digests", digest)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
