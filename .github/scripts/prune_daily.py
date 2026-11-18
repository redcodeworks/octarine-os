#!/usr/bin/env python3
"""Delete old daily images of ONE container package (octarine-os, octarine-os-dx or octarine-os-gx) and their cosign signatures.

Reads the package versions (the output of `gh api --paginate <package>/versions?per_page=100`, one or several JSON arrays) on stdin.

A version is a CANDIDATE when it has at least one `daily-YYYYMMDD` tag and EVERY tag it carries is a daily tag or a dated alias tag of the
image (`latest-<sha7>`, `latest-YYYYMMDD`, `latest-YYYYMMDD-<sha7>`, `YYYYMMDD`, `YYYYMMDD-<sha7>`). Anything with another tag (the bare `latest`,
`testing*`, `beta*`, ...) and every untagged version is never a candidate. Of the versions that carry a daily tag the newest KEEP (default 14, by
created_at) are kept; the older candidates are deleted. The cosign signature version (`sha256-<digest>.sig`) of each deleted image is deleted
with it, and so is a signature whose image digest is not a version of this package at all (provable from the list).

PROTECT (space separated sha256 digests, set by the workflow) lists images that must never be deleted: the digest behind each image's own `latest` and the base
image of each variant `latest` (dx, gx; that is a label of the variant image, so the workflow reads it and passes it in).

DRY_RUN (default true) only prints the plan. API_BASE (e.g. users/<owner>/packages/container/<name>) is needed to delete. More than MAX_DELETES
(default 30) versions in the plan: nothing is deleted and the run fails.
"""

import json
import os
import re
import sys
from datetime import datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
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
    decoder, versions, pos = json.JSONDecoder(), [], 0
    while True:
        while pos < len(text) and text[pos].isspace():
            pos += 1
        if pos >= len(text):
            return versions
        value, pos = decoder.raw_decode(text, pos)
        versions.extend(value if isinstance(value, list) else [value])


def tags_of(v):
    return ((v.get("metadata") or {}).get("container") or {}).get("tags") or []


def digest_of(v):
    return v["name"].split(":")[-1]


def label(v):
    return f"id={v['id']} {digest_of(v)[:12]} {v['created_at'][:10]} tags={','.join(tags_of(v)) or '(none)'}"


def plan(versions):
    sigs, images = {}, []
    for v in versions:
        tags = tags_of(v)
        if tags and all(SIG.match(t) for t in tags):
            for t in tags:
                sigs[SIG.match(t).group(1)] = v
        else:
            images.append(v)
    image_digests = {digest_of(v) for v in images}
    protect = {p.split(":")[-1] for p in PROTECT}
    dailies = sorted(
        (v for v in images if any(DAILY.match(t) for t in tags_of(v))),
        key=lambda v: datetime.fromisoformat(v["created_at"].replace("Z", "+00:00")),
        reverse=True,
    )
    kept = dailies[:KEEP]
    doomed = [
        v
        for v in dailies[KEEP:]
        if all(DAILY.match(t) or ALIAS.match(t) for t in tags_of(v))
        and digest_of(v) not in protect
    ]
    doomed_digests = {digest_of(v) for v in doomed}
    doomed_sigs = [
        s for d, s in sigs.items() if d in doomed_digests or d not in image_digests
    ]
    return dailies, kept, doomed, doomed_sigs


def main(argv=None):
    ci.arg_parser(__doc__).parse_args(argv)
    versions = read_versions(sys.stdin.read())
    dailies, kept, doomed, doomed_sigs = plan(versions)
    todo = doomed + doomed_sigs
    ci.log.info(
        f"{len(versions)} versions, {len(dailies)} with a daily tag, keeping the newest {KEEP}"
    )
    for v in kept:
        ci.log.info(f"  keep   {label(v)}")
    for v in dailies[KEEP:]:
        if v not in doomed:
            ci.log.info(f"  keep   (protected or carries another tag) {label(v)}")
    for v in doomed:
        ci.log.info(f"  DELETE image {label(v)}")
    for v in doomed_sigs:
        ci.log.info(f"  DELETE sig   {label(v)}")
    if not todo:
        ci.log.info("Nothing to prune.")
        return 0
    if len(todo) > MAX_DELETES:
        sys.exit(f"Refusing to delete {len(todo)} versions (limit {MAX_DELETES})")
    if DRY_RUN:
        ci.log.info(f"Dry run: {len(todo)} versions would be deleted.")
        return 0
    if not API_BASE:
        sys.exit("API_BASE is required to delete")
    gh = ci.github()
    for v in todo:
        gh.request("DELETE", f"/{API_BASE}/versions/{v['id']}")
        ci.log.info(f"deleted {v['id']}")
    ci.log.info(f"Deleted {len(todo)} versions.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
