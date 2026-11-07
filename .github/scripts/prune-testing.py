#!/usr/bin/env python3
"""Prune old `testing` image versions from GHCR.

Reads the package's version list (JSON from the GitHub Packages API) on stdin, prints a plan, and
unless DRY_RUN=true deletes it with `gh api -X DELETE`.

Rules:
  * A "build" is the set of versions that share a git sha in their tags. Keep the newest KEEP builds.
  * Only versions whose tags ALL start with `testing` are candidates. Anything carrying a `latest*`
    tag (or any other tag) is never deleted.
  * Delete the cosign signature version (`sha256-<digest>.sig`) of every deleted image, and any
    signature whose image no longer exists.
  * Delete untagged image versions older than UNTAGGED_DAYS.
  * Refuse to delete more than MAX_DELETES versions in one run.

Environment: API_BASE (e.g. users/<owner>/packages/container/<image>), DRY_RUN (default true),
KEEP (default 10), UNTAGGED_DAYS (default 7), MAX_DELETES (default 60).
"""
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timedelta, timezone

KEEP = int(os.environ.get("KEEP") or 10)
UNTAGGED_DAYS = int(os.environ.get("UNTAGGED_DAYS") or 7)
MAX_DELETES = int(os.environ.get("MAX_DELETES") or 60)
DRY_RUN = (os.environ.get("DRY_RUN") or "true").lower() != "false"
API_BASE = os.environ.get("API_BASE", "")

SIG = re.compile(r"^sha256-([0-9a-f]{64})\.sig$")
SHA_TAG = re.compile(r"-([0-9a-f]{7})$")


def read_versions(text):
    """The API output may be several concatenated JSON arrays (one per page)."""
    decoder = json.JSONDecoder()
    versions, pos = [], 0
    while pos < len(text):
        while pos < len(text) and text[pos].isspace():
            pos += 1
        if pos >= len(text):
            break
        value, pos = decoder.raw_decode(text, pos)
        versions.extend(value if isinstance(value, list) else [value])
    return versions


def tags_of(version):
    return ((version.get("metadata") or {}).get("container") or {}).get("tags") or []


def when(version):
    return datetime.fromisoformat(version["created_at"].replace("Z", "+00:00"))


def digest_of(version):
    return version["name"].split(":")[-1]


def label(version):
    return f'id={version["id"]} {digest_of(version)[:12]} tags={",".join(tags_of(version)) or "(none)"}'


def main():
    versions = read_versions(sys.stdin.read())
    sigs, images = {}, []
    for v in versions:
        tags = tags_of(v)
        if tags and all(SIG.match(t) for t in tags):
            for t in tags:
                sigs[SIG.match(t).group(1)] = v
        else:
            images.append(v)
    image_digests = {digest_of(v) for v in images}

    # Group testing-only versions into builds by the git sha in their tags
    groups = {}
    for v in images:
        tags = tags_of(v)
        if tags and all(t == "testing" or t.startswith("testing-") for t in tags):
            sha = next((m.group(1) for m in (SHA_TAG.search(t) for t in tags) if m), None)
            groups.setdefault(sha or digest_of(v), []).append(v)
    builds = sorted(groups.items(), key=lambda kv: max(when(v) for v in kv[1]), reverse=True)

    doomed = [v for _, vs in builds[KEEP:] for v in vs]
    cutoff = datetime.now(timezone.utc) - timedelta(days=UNTAGGED_DAYS)
    doomed += [v for v in images if not tags_of(v) and when(v) < cutoff]

    doomed_digests = {digest_of(v) for v in doomed}
    doomed_sigs = [sv for d, sv in sigs.items() if d in doomed_digests or d not in image_digests]

    # Safety nets
    for v in doomed:
        assert not any(t.startswith("latest") or re.match(r"^\d{8}", t) for t in tags_of(v)), label(v)
    plan = doomed + doomed_sigs
    print(f"{len(versions)} versions: {len(builds)} testing builds, keeping the newest {KEEP}")
    for sha, vs in builds[:KEEP]:
        print(f"  keep   build {sha[:12]}: " + "; ".join(label(v) for v in vs))
    for v in doomed:
        print(f"  DELETE image {label(v)}")
    for v in doomed_sigs:
        print(f"  DELETE sig   {label(v)}")
    if len(plan) > MAX_DELETES:
        sys.exit(f"Refusing to delete {len(plan)} versions (limit {MAX_DELETES})")
    if not plan:
        print("Nothing to prune.")
        return
    if DRY_RUN:
        print(f"Dry run: {len(plan)} versions would be deleted.")
        return
    if not API_BASE:
        sys.exit("API_BASE is required to delete")
    for v in plan:
        subprocess.run(["gh", "api", "-X", "DELETE", f"{API_BASE}/versions/{v['id']}"], check=True)
        print(f"deleted {v['id']}")
    print(f"Deleted {len(plan)} versions.")


if __name__ == "__main__":
    main()
