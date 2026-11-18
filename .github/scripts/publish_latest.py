#!/usr/bin/env python3
"""Move the bare `latest` tag of ONE image: the default image (octarine-os) or a variant built on it (dx or gx). Every image publishes its OWN `latest`, after its own signed build or its
own promotion, independently of the others (2026-11-16, Kevin). Builds and promotions on main publish dated tags only (`latest-<sha7>`, `latest-<date>-<sha7>`, `<date>-<sha7>`, and the same-day
aliases); this script is the one step that makes an image visible to `bootc upgrade`. A signature belongs to a digest, so a retag needs no new signature.

Environment
  OWNER            repository owner (the images are ghcr.io/<owner>/octarine-os, octarine-os-dx, octarine-os-gx)
  IMAGE            default | dx | gx: the image whose `latest` moves (nothing else moves)
  DIGEST           the digest to publish (called from the build run of that image); empty = resolve it from TAG
  TAG              dispatch only: a dated tag of THAT image (latest-<sha7>, latest-<date>-<sha7>, <date>-<sha7>). Empty is allowed for the default image only: the newest commit of
                   main (first parent) that has a published latest-<sha7>; a variant needs its tag
  MAIN_REF         the ref that holds main's history (default origin/main), MAX_WALK (default 60)
  DRY_RUN          true = plan and report only; WRITE must be true for any write (the workflow sets it only on main)
  ALLOW_BACKWARDS  true = a ROLLBACK (rollback-latest.yml): the ordering guard is skipped, so an older verified image may be put under `latest`; everything else (signatures, the base rule, the
                   main-commit rule) is unchanged
  REASON           free text for the summary; GITHUB_STEP_SUMMARY, GITHUB_OUTPUT (moved=true|false) are used when set
Tools: skopeo, cosign (cosign.pub in the current directory), git (history of main).

What it refuses (exit 1) and what it holds back (exit 0 with a notice):
  * a tag that is not a dated tag of the image (testing-*, latest itself, anything else);
  * an image without a valid signature (cosign.pub); the default image whose label org.opencontainers.image.revision is not a commit of main; a variant whose label
    org.opencontainers.image.base.digest is not a SIGNED default image built from main (it may be the default image's `latest` or not: the images publish independently, the variant only has to
    stand on a default image that is itself publishable);
  * HELD, not failed: a candidate OLDER than what that image's `latest` is now (a re-run of an old green run must not move `latest` backwards): the commit of the candidate is an ancestor of the
    commit under `latest`, or it is the same commit built earlier (label created).
  * an unreadable registry is a FAILURE (a read error is never "no latest yet" and never "unsigned"): nothing moves, a re-run decides again.
Idempotent: a `latest` that already has the digest is left alone; nothing new = a green no-op.
"""
import os
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ci  # noqa: E402
import registry  # noqa: E402

L_REV = "org.opencontainers.image.revision"
L_CREATED = "org.opencontainers.image.created"
L_BASE = "org.opencontainers.image.base.digest"
DIGEST_RE = re.compile(r"sha256:[0-9a-f]{64}")
TAG_RE = re.compile(r"latest-[0-9a-f]{7}|latest-[0-9]{8}-[0-9a-f]{7}|[0-9]{8}-[0-9a-f]{7}")


def read_error(what):
    ci.err(f"::error::could not read the registry ({what}): a read error, not a missing image or tag; nothing was moved")
    raise SystemExit(1)


def label(image, digest, key):
    """One label of image@digest; a registry that cannot be read fails the run."""
    try:
        return registry.labels(registry.read("config", f"{image}@{digest}")).get(key) or ""
    except registry.RegistryError:
        read_error(f"labels of {image}@{digest}")


def tag_digest(image, tag):
    """(code, digest): code 0 with the digest, 3 the tag does not exist, 4 the registry could not be read (retried)."""
    try:
        return 0, registry.digest(image, tag, quiet=True)
    except registry.RegistryError as e:
        return e.code, ""


def must_be_signed(ref):
    rc = registry.verify_code(["--key", "cosign.pub", ref], sink=lambda m: None)  # 0 verified, 5 not verified, 4 could not be checked
    if rc == 0:
        return
    if rc == 4:
        read_error(f"signature of {ref}")
    ci.fail(f"{ref} has no valid signature (cosign.pub)")


def is_commit(rev):
    return bool(rev) and ci.git_ok("cat-file", "-e", f"{rev}^{{commit}}")


def main():
    owner = (os.environ.get("OWNER") or sys.exit("OWNER: parameter null or not set")).lower()
    which = os.environ.get("IMAGE") or sys.exit("IMAGE (default, dx or gx): parameter null or not set")
    names = {"default": "octarine-os", "dx": "octarine-os-dx", "gx": "octarine-os-gx"}
    if which not in names:
        print("::error::IMAGE must be default, dx or gx")
        return 2
    img = f"ghcr.io/{owner}/{names[which]}"
    bimg = f"ghcr.io/{owner}/octarine-os"
    main_ref = os.environ.get("MAIN_REF") or "origin/main"
    max_walk = os.environ.get("MAX_WALK") or "60"
    dry = os.environ.get("DRY_RUN") or "false"
    write = os.environ.get("WRITE") or "false"
    reason = os.environ.get("REASON", "")
    back = os.environ.get("ALLOW_BACKWARDS") or "false"

    ci.append_to("GITHUB_OUTPUT", "moved=false")

    # ---- 1. the candidate
    cand = os.environ.get("DIGEST", "")
    ctag = ""
    if not cand:
        ctag = os.environ.get("TAG", "")
        if ctag:
            if not TAG_RE.fullmatch(ctag):
                ci.fail(f"'{ctag}' is not a dated tag of {img} (latest-<sha7>, latest-<date>-<sha7> or <date>-<sha7>); testing-* and latest are refused")
            rc, cand = tag_digest(img, ctag)
            if rc != 0:
                if rc == 3:
                    ci.fail(f"{img}:{ctag} does not exist")
                read_error(f"{img}:{ctag}")
        elif which == "default":
            for c in ci.git("rev-list", "--first-parent", f"--max-count={max_walk}", main_ref).split():
                t = f"latest-{ci.git('rev-parse', '--short=7', c)}"
                rc, d = tag_digest(img, t)
                if rc == 0:
                    cand, ctag = d, t
                    break
                if rc != 3:
                    read_error(f"{img}:{t}")
            if not cand:
                ci.fail(f"no published latest-<sha7> within the newest {max_walk} commits of {main_ref}")
        else:
            ci.fail(f"{img}: a dated tag is required (TAG), there is no main commit to look it up by")
    if not DIGEST_RE.fullmatch(cand):
        ci.fail(f"'{cand}' is not a sha256 digest")

    # ---- 2. verification: the candidate is signed; the default image was built from main; a variant stands on such a default image
    must_be_signed(f"{img}@{cand}")
    if which == "default":
        rev = label(img, cand, L_REV)
        root_desc = f"{img}@{cand}"
    else:
        base = label(img, cand, L_BASE)
        if not DIGEST_RE.fullmatch(base):
            ci.fail(f"{img}@{cand} has no usable base digest label ('{base}')")
        must_be_signed(f"{bimg}@{base}")
        rev = label(bimg, base, L_REV)
        root_desc = f"{bimg}@{base} (the base of {img}@{cand})"
    if not is_commit(rev):
        ci.fail(f"{root_desc}: its revision label '{rev}' is not a commit of this repository")
    if not ci.git_ok("merge-base", "--is-ancestor", rev, main_ref):
        ci.fail(f"{root_desc} was built from {rev}, which is not on {main_ref}: only images built from main are published as latest")

    # ---- 3. ordering guard: never move latest backwards
    def older(candidate, current):
        """True when the candidate is older than the one under latest now (an unreadable label fails the run: read_error exits)."""
        cr, ur = label(img, candidate, L_REV), label(img, current, L_REV)
        cc, uc = label(img, candidate, L_CREATED), label(img, current, L_CREATED)
        if not is_commit(ur):
            ci.err(f"::warning::the image under {img}:latest has no usable revision label ({ur or 'none'}): the ordering guard cannot compare")
            return False
        if cr == ur:
            return bool(cc and uc and cc < uc)
        return ci.git_ok("merge-base", "--is-ancestor", cr, ur)

    # the digest under latest now: absent (3) means none yet; a read error fails the run (it must not look like "nothing is published", which would move latest unguarded)
    rc, cur = tag_digest(img, "latest")
    if rc not in (0, 3):
        read_error(f"{img}:latest")
    if rc != 0:
        cur = ""
    note = f" (reason: {reason})" if reason else ""
    if back == "true":
        print("ROLLBACK: the ordering guard is skipped; an older verified image may be put under latest")
    elif cur and cur != cand and older(cand, cur):
        ci.summary(f"latest held: {img}:latest ({cur}) is newer than the candidate {cand}; nothing was moved{note}")
        return 0

    # ---- 4. plan
    if cur == cand:
        ci.summary(f"latest unchanged: {img}:latest is already {cand}; nothing new was built")
        return 0
    plan = f"{img}: latest {cur or 'none'} -> {cand} ({ctag or 'from the build run'}, main commit {rev[:7]})"
    if dry == "true" or write != "true":
        ci.summary(f"DRY RUN ({dry}, write allowed: {write}): would move latest:")
        ci.summary(f"  {plan}")
        return 0

    # ---- 5. move; the copy is read back and verified
    rc = ci.retry_command(["skopeo", "copy", "--all", "--preserve-digests", f"docker://{img}@{cand}", f"docker://{img}:latest"])
    if rc != 0:
        return rc
    # the read-back polls (a registry may show the previous manifest or fail a read for a moment right after a copy): registry.settled, the same one push_tags.py uses
    try:
        registry.settled(img, "latest", cand)
    except SystemExit:
        ci.fail(f"{img}:latest does not show {cand} after the copy")
    must_be_signed(f"{img}:latest")
    pre = "ROLLBACK, " if back == "true" else ""
    ci.summary(f"{pre}latest moved: {plan}{'; reason: ' + reason if reason else ''}")
    ci.append_to("GITHUB_OUTPUT", "moved=true")
    return 0


if __name__ == "__main__":
    sys.exit(main())
