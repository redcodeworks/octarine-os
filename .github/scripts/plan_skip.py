#!/usr/bin/env python3
"""Decide whether a SCHEDULED run may skip the image build, and print one line:
`skipped: ...` or `build: <reason>`.

The decision is a pure function of its environment, so it can be tried locally (see
tests/py/test_decisions.py):

  EVENT             github.event_name; anything but `schedule` always builds
  REF               github.ref; the skip only applies on refs/heads/main (the default
                    branch)
  BASE_NOW          digest of the base image's manifest list now (sha256 of `skopeo
                    inspect --raw`)
  LATEST_BASE       the same digest recorded in the published `latest` (label
                    ...base-index-digest)
  REPO_SAME         `true` when the repository content (git tree) of main HEAD equals
                    the commit `latest` was built from (label
                    org.opencontainers.image.revision), else `false`
  LATEST_CREATED    org.opencontainers.image.created of `latest` (ISO 8601)
  NOW_EPOCH         seconds since the epoch, default: now
  MAX_AGE_DAYS      `latest` older than this always rebuilds. 7 days because the build
                    installs RPMs from live Fedora and RPM Fusion repositories, so
                    package updates arrive without a base image change
  SIGNED            `true` when `latest` has a valid signature
  LATEST_MISSING    the label org.octarineos.optional-packages-missing of `latest`
                    (`none` or a comma separated list, set by `just rechunk`): a list
                    means optional packages failed to install; such an image is never
                    kept, the next run tries again

Anything missing or unreadable means build (fail safe): an image from before the labels
existed has no LATEST_BASE or REPO_SAME and therefore gets one normal build that records
them.
"""

import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ci  # noqa: E402


env = os.environ.get


def decide() -> str:
    """Decide from the environment whether the scheduled build may be skipped.

    Reads EVENT, REF, BASE_NOW, LATEST_BASE, LATEST_MISSING, REPO_SAME,
    LATEST_CREATED, NOW_EPOCH, MAX_AGE_DAYS and SIGNED. Returns one line, `skipped:
    ...` or `build: <reason>`; every doubt (missing value, unreadable date) is a
    build.
    """
    # only the scheduled run on main may skip
    if env("EVENT") != "schedule":
        return f"build: not a scheduled run ({env('EVENT') or 'unset'})"
    # a branch run never skips
    if env("REF") != "refs/heads/main":
        return f"build: not main ({env('REF') or 'unset'})"
    base_now, latest_base = env("BASE_NOW", ""), env("LATEST_BASE", "")

    # without both digests nothing can be compared
    if not (base_now and latest_base):
        return (
            f"build: base digest unknown (now '{base_now}', in latest '{latest_base}')"
        )

    # a changed base image needs a rebuild
    if base_now != latest_base:
        return "build: base image changed"
    missing = env("LATEST_MISSING", "")

    # optional packages that failed last time get another try
    if missing and missing != "none":
        return f"build: latest was built with optional packages missing ({missing}): trying again"
    # content that differs from the commit latest was built from needs a rebuild
    if env("REPO_SAME") != "true":
        return "build: repository content differs from, or is unknown for, the commit latest was built from"
    created_text = env("LATEST_CREATED", "")

    # without a creation date the age is unknown
    if not created_text:
        return "build: age of latest unknown"
    # a date that cannot be read counts as unknown
    try:
        created = ci.epoch(created_text)
    except ValueError:
        return f"build: cannot read created date '{created_text}'"
    now = int(env("NOW_EPOCH") or time.time())
    maximum = env("MAX_AGE_DAYS") or "7"

    # the age limit must be a number of days
    if not maximum.isdigit():
        return "build: MAX_AGE_DAYS is not a number"
    # an image older than the limit is rebuilt even when nothing changed
    if not now - created < int(maximum) * 86400:
        return f"build: latest is {(now - created) // 86400} days old (limit {maximum})"
    # an image that cannot be verified as signed is not kept
    if env("SIGNED") != "true":
        return "build: latest is not verified as signed"
    return "skipped: base, repo and age unchanged"


# run as a script, not when imported by a test
if __name__ == "__main__":
    ci.result(decide())
