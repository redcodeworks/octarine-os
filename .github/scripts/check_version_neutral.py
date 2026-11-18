#!/usr/bin/env python3
"""Fail when an image version (read from stdin, one `key=value` line each) names a channel.

- every label whose key contains `version` (org.opencontainers.image.version, ostree version labels) must not contain `testing` or `latest`, and org.opencontainers.image.version must be present;
- the line `IMAGE_VERSION=<value>` (os-release, the CI appends it to the labels) is required and follows the same rule; quotes around a value are ignored.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ci  # noqa: E402


def main(argv=None):
    ci.arg_parser(__doc__).parse_args(argv)
    pairs = [line.rstrip("\n").partition("=")[::2] for line in sys.stdin]
    versions = {k: v.removesuffix('"').removeprefix('"') for k, v in pairs if "version" in k.lower()}
    bad = False
    for key, value in versions.items():
        if any(channel in value.lower() for channel in ("testing", "latest")):
            print(f"ERROR: {key}={value} names a channel")
            bad = True
        print(f"{key}={value}")
    for key, what in (("org.opencontainers.image.version", "org.opencontainers.image.version"), ("IMAGE_VERSION", "os-release IMAGE_VERSION")):
        if key not in versions:
            print(f"ERROR: {what} is missing")
            return 1
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
