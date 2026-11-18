#!/usr/bin/env python3
"""Fail when an image version (read from stdin, one `key=value` line each) names a
channel.

- every label whose key contains `version` (org.opencontainers.image.version, ostree
  version labels) must not contain `testing` or `latest`, and
  org.opencontainers.image.version must be present;
- the line `IMAGE_VERSION=<value>` (os-release, the CI appends it to the labels) is
  required and follows the same rule; quotes around a value are ignored.
"""

import sys
from pathlib import Path

here = Path(__file__).resolve().parent
sys.path[:0] = [str(here.parent / "00-lib"), str(here)]
import ci  # noqa: E402


def main(argv=None):
    """Check that no version label or os-release value names a channel.

    Reads KEY=VALUE lines on stdin (the image's version label and os-release lines).
    Logs each version line and an error for any that contains `testing` or `latest`,
    and for a missing required key. Returns 0 when clean, 1 otherwise.
    """
    ci.arg_parser(__doc__).parse_args(argv)
    # split each KEY=VALUE line; only the text after the first = is the value
    pairs = [line.rstrip("\n").partition("=")[::2] for line in sys.stdin]
    # keep the version-like keys, with their surrounding quotes removed
    versions = {
        k: v.removesuffix('"').removeprefix('"')
        for k, v in pairs
        if "version" in k.lower()
    }
    bad = False

    # every version value is shown, and a channel name in one is an error
    for key, value in versions.items():
        # a version that names a channel would make a dated tag mean different images
        if any(channel in value.lower() for channel in ("testing", "latest")):
            ci.log.error(f"{key}={value} names a channel")
            bad = True
        ci.log.info(f"{key}={value}")

    # both required keys must be present
    for key, what in (
        ("org.opencontainers.image.version", "org.opencontainers.image.version"),
        ("IMAGE_VERSION", "os-release IMAGE_VERSION"),
    ):
        # a missing required key is an error at once
        if key not in versions:
            ci.log.error(f"{what} is missing")
            return 1
    return 1 if bad else 0


# run as a script, not when imported by a test
if __name__ == "__main__":
    sys.exit(main())
