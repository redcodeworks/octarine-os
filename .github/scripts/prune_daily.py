#!/usr/bin/env python3
"""Delete old daily images of ONE container package (octarine-os, octarine-os-dx or
octarine-os-gx) and their cosign signatures.

Reads the package versions (the output of `gh api --paginate
<package>/versions?per_page=100`, one or several JSON arrays) on stdin.

A version is a CANDIDATE when it has at least one `daily-YYYYMMDD` tag and EVERY tag it
carries is a daily tag or a dated alias tag of the image (`latest-<sha7>`,
`latest-YYYYMMDD`, `latest-YYYYMMDD-<sha7>`, `YYYYMMDD`, `YYYYMMDD-<sha7>`). Anything
with another tag (the bare `latest`, `testing*`, `beta*`, ...) and every untagged
version is never a candidate. Of the versions that carry a daily tag the newest KEEP
(default 14, by created_at) are kept; the older candidates are deleted. The cosign
signature version (`sha256-<digest>.sig`) of each deleted image is deleted with it, and
so is a signature whose image digest is not a version of this package at all (provable
from the list).

PROTECT (space separated sha256 digests, set by the workflow) lists images that must
never be deleted: the digest behind each image's own `latest` and the base image of each
variant `latest` (dx, gx; that is a label of the variant image, so the workflow reads it
and passes it in).

DRY_RUN (default true) only prints the plan. API_BASE (e.g.
users/<owner>/packages/container/<name>) is needed to delete. More than MAX_DELETES
(default 30) versions in the plan: nothing is deleted and the run fails.
"""

import json
import os
import re
import sys
from datetime import datetime
from pathlib import Path

here = Path(__file__).resolve().parent
sys.path[:0] = [str(here / "00-lib"), str(here)]
import ci  # noqa: E402

KEEP = int(os.environ.get("KEEP") or 14)
MAX_DELETES = int(os.environ.get("MAX_DELETES") or 30)
DRY_RUN = (os.environ.get("DRY_RUN") or "true").lower() != "false"
API_BASE = os.environ.get("API_BASE", "")
PROTECT = set(os.environ.get("PROTECT", "").split())

DAILY = re.compile(r"^daily-\d{8}$")
ALIAS = re.compile(
    r"^(latest-[0-9a-f]{7}|latest-\d{8}(-[0-9a-f]{7})?|\d{8}(-[0-9a-f]{7})?)$"
)
SIG = re.compile(r"^sha256-([0-9a-f]{64})\.sig$")


def read_versions(text):
    """Parse the concatenated JSON arrays that `gh api --paginate` prints.

    Receives the text; returns one list with the versions of every page.
    """
    decoder, versions, pos = json.JSONDecoder(), [], 0

    # one raw_decode per page: the pages follow each other without a separator
    while True:
        # skip the whitespace between pages
        while pos < len(text) and text[pos].isspace():
            pos += 1
        # the end of the text ends the loop
        if pos >= len(text):
            return versions
        value, pos = decoder.raw_decode(text, pos)
        versions.extend(value if isinstance(value, list) else [value])


def tags_of(v):
    """Return the tags of a package version, or an empty list.

    Receives one version of the packages API.
    """
    return ((v.get("metadata") or {}).get("container") or {}).get("tags") or []


def digest_of(v):
    """Return the digest part of a version's name (`sha256:...`)."""
    return v["name"].split(":")[-1]


def label(v):
    """Describe a version in one line for the log: id, short digest, date and tags."""
    return f"id={v['id']} {digest_of(v)[:12]} {v['created_at'][:10]} tags={','.join(tags_of(v)) or '(none)'}"


def plan(versions):
    """Split the versions into what to keep and what to delete.

    Receives the versions of the package. Returns (dailies, kept, doomed,
    doomed_sigs): the daily-tagged images newest first, the newest KEEP of them, the
    older ones that carry only daily or alias tags and are not protected, and the
    cosign signatures of deleted images or of images that no longer exist.
    """
    sigs, images = {}, []

    # signature versions (only sha256-<digest>.sig tags) are kept apart from images
    for v in versions:
        tags = tags_of(v)
        # a version whose tags are all signature tags is a signature
        if tags and all(SIG.match(t) for t in tags):
            # index the signature by the digest it signs
            for t in tags:
                sigs[SIG.match(t).group(1)] = v
        else:
            images.append(v)
    # digests of all images, to find signatures of images that are gone
    image_digests = {digest_of(v) for v in images}
    # protected references are matched by digest only
    protect = {p.split(":")[-1] for p in PROTECT}
    # daily images, newest first
    dailies = sorted(
        (v for v in images if any(DAILY.match(t) for t in tags_of(v))),
        key=lambda v: datetime.fromisoformat(v["created_at"].replace("Z", "+00:00")),
        reverse=True,
    )
    kept = dailies[:KEEP]
    # older dailies go, unless they carry another tag or a protected digest
    doomed = [
        v
        for v in dailies[KEEP:]
        if all(DAILY.match(t) or ALIAS.match(t) for t in tags_of(v))
        and digest_of(v) not in protect
    ]
    # digests of the images that will be deleted
    doomed_digests = {digest_of(v) for v in doomed}
    # their signatures go too, and so do signatures of images that no longer exist
    doomed_sigs = [
        s for d, s in sigs.items() if d in doomed_digests or d not in image_digests
    ]
    return dailies, kept, doomed, doomed_sigs


def main(argv=None):
    """List and, unless it is a dry run, delete old daily images and their signatures.

    Reads the packages API versions on stdin and the settings KEEP, MAX_DELETES,
    DRY_RUN (default true), API_BASE and PROTECT. Returns 0; exits with a message
    when the number of deletions exceeds the limit or API_BASE is missing for a real
    run.
    """
    ci.arg_parser(__doc__).parse_args(argv)
    versions = read_versions(sys.stdin.read())
    dailies, kept, doomed, doomed_sigs = plan(versions)
    todo = doomed + doomed_sigs
    ci.log.info(
        f"{len(versions)} versions, {len(dailies)} with a daily tag, keeping the newest {KEEP}"
    )

    # log what stays and what goes
    for v in kept:
        ci.log.info(f"  keep   {label(v)}")
    # older dailies that stay are shown with the reason
    for v in dailies[KEEP:]:
        # a daily that is not doomed is protected or carries another tag
        if v not in doomed:
            ci.log.info(f"  keep   (protected or carries another tag) {label(v)}")

    # each image to delete
    for v in doomed:
        ci.log.info(f"  DELETE image {label(v)}")
    # each signature to delete
    for v in doomed_sigs:
        ci.log.info(f"  DELETE sig   {label(v)}")
    # nothing to delete is the normal case
    if not todo:
        ci.log.info("Nothing to prune.")
        return 0
    # a plan that deletes more than expected is a mistake: refuse
    if len(todo) > MAX_DELETES:
        sys.exit(f"Refusing to delete {len(todo)} versions (limit {MAX_DELETES})")
    # a dry run only reports
    if DRY_RUN:
        ci.log.info(f"Dry run: {len(todo)} versions would be deleted.")
        return 0
    # a real run needs the API base to delete through
    if not API_BASE:
        sys.exit("API_BASE is required to delete")
    gh = ci.github()

    # delete one version at a time, logging each
    for v in todo:
        gh.request("DELETE", f"/{API_BASE}/versions/{v['id']}")
        ci.log.info(f"deleted {v['id']}")
    ci.log.info(f"Deleted {len(todo)} versions.")
    return 0


# run as a script, not when imported by a test
if __name__ == "__main__":
    sys.exit(main())
