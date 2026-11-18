#!/usr/bin/env python3
"""Fail when an image version (read from stdin, one `key=value` line each) names a channel.

- every label whose key contains `version` (org.opencontainers.image.version, ostree version labels) must not contain `testing` or `latest`, and org.opencontainers.image.version must be present;
- the line `IMAGE_VERSION=<value>` (os-release, the CI appends it to the labels) is required and follows the same rule; quotes around a value are ignored.
"""
import sys


def main():
    found = found_os = False
    bad = 0
    for line in sys.stdin:
        line = line.rstrip("\n")
        k, _, v = line.partition("=")
        if "version" not in k.lower():
            continue
        v = v.removesuffix('"').removeprefix('"')
        if k == "org.opencontainers.image.version":
            found = True
        if "testing" in v.lower() or "latest" in v.lower():
            print(f"ERROR: {k}={v} names a channel")
            bad = 1
        if k == "IMAGE_VERSION":
            found_os = True
        print(f"{k}={v}")
    if not found:
        print("ERROR: org.opencontainers.image.version is missing")
        return 1
    if not found_os:
        print("ERROR: os-release IMAGE_VERSION is missing")
        return 1
    return bad


if __name__ == "__main__":
    sys.exit(main())
