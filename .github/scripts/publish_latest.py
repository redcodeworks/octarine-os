#!/usr/bin/env python3
"""Move the bare `latest` tag of ONE image: the default image (octarine-os) or a variant
built on it (dx or gx). Every image publishes its OWN `latest`, after its own signed
build or its own promotion, independently of the others (2026-11-16, Kevin). Builds and
promotions on main publish dated tags only (`latest-<sha7>`, `latest-<date>-<sha7>`,
`<date>-<sha7>`, and the same-day aliases); this script is the one step that makes an
image visible to `bootc upgrade`. A signature belongs to a digest, so a retag needs no
new signature.

Environment
  OWNER            repository owner (the images are ghcr.io/<owner>/octarine-os,
                   octarine-os-dx, octarine-os-gx)
  IMAGE            default | dx | gx: the image whose `latest` moves (nothing else
                   moves)
  DIGEST           the digest to publish (called from the build run of that image);
                   empty = resolve it from TAG
  TAG              dispatch only: a dated tag of THAT image (latest-<sha7>,
                   latest-<date>-<sha7>, <date>-<sha7>). Empty is allowed for the
                   default image only: the newest commit of main (first parent) that has
                   a published latest-<sha7>; a variant needs its tag
  MAIN_REF         the ref that holds main's history (default origin/main), MAX_WALK
                   (default 60)
  DRY_RUN          true = plan and report only; WRITE must be true for any write (the
                   workflow sets it only on main)
  ALLOW_BACKWARDS  true = a ROLLBACK (rollback-latest.yml): the ordering guard is
                   skipped, so an older verified image may be put under `latest`;
                   everything else (signatures, the base rule, the main-commit rule) is
                   unchanged
  REASON           free text for the summary; GITHUB_STEP_SUMMARY, GITHUB_OUTPUT
                   (moved=true|false) are used when set
Tools: skopeo, cosign (cosign.pub in the current directory), git (history of main).

What it refuses (exit 1) and what it holds back (exit 0 with a notice):
  * a tag that is not a dated tag of the image (testing-*, latest itself, anything
    else);
  * an image without a valid signature (cosign.pub); the default image whose label
    org.opencontainers.image.revision is not a commit of main; a variant whose label
    org.opencontainers.image.base.digest is not a SIGNED default image built from main
    (it may be the default image's `latest` or not: the images publish independently,
    the variant only has to
    stand on a default image that is itself publishable);
  * HELD, not failed: a candidate OLDER than what that image's `latest` is now (a re-run
    of an old green run must not move `latest` backwards): the commit of the candidate
    is an ancestor of the commit under `latest`, or it is the same commit built earlier
    (label created).
  * an unreadable registry is a FAILURE (a read error is never "no latest yet" and never
    "unsigned"): nothing moves, a re-run decides again.
Idempotent: a `latest` that already has the digest is left alone; nothing new = a green
no-op.
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
TAG_RE = re.compile(
    r"latest-[0-9a-f]{7}|latest-[0-9]{8}-[0-9a-f]{7}|[0-9]{8}-[0-9a-f]{7}"
)


class Stop(SystemExit):
    """End the run with exit status 1 (a refusal or a read error; nothing was moved)
    after logging why.
    """

    def __init__(self, message):
        """Log the reason and end the run with exit status 1.

        Receives the message; it is logged as an error before SystemExit(1) is
        raised.
        """
        ci.log.error(message)
        super().__init__(1)


def read_error(what):
    """Stop the run because the registry could not be read.

    Receives what was being read; raises Stop, since a read error must never look
    like "nothing there" and move latest unguarded.
    """
    raise Stop(
        f"could not read the registry ({what}): a read error, not a missing image or tag; nothing was moved"
    )


def label(image, digest, key):
    """One label of image@digest; a registry that cannot be read (or does not show a
    digest it just named) fails the run.
    """
    # a registry that cannot be read fails the run instead of returning an empty label
    try:
        return (
            registry.labels(registry.read("config", f"{image}@{digest}")).get(key) or ""
        )
    except registry.RegistryError:
        read_error(f"labels of {image}@{digest}")


def tag_digest(image, tag):
    """The digest under a tag, or None when the tag does not exist; a registry that
    cannot be read fails the run (never "no latest yet").
    """
    # a missing tag is a normal answer (None); a read error is not
    try:
        return registry.digest(image, tag)
    except registry.Absent:
        return None
    except registry.ReadError:
        read_error(f"{image}:{tag}")


def must_be_signed(ref, fresh=False):
    """The ref carries a valid signature (cosign.pub); `fresh`: it was written seconds
    ago, so a missing signature is retried first.
    """
    check = registry.cosign_check_fresh if fresh else registry.cosign_check

    # NotVerified is a refusal; ReadError is an unreadable registry
    try:
        check(["--key", "cosign.pub", ref])
    except registry.NotVerified:
        raise Stop(f"{ref} has no valid signature (cosign.pub)")
    except registry.ReadError:
        read_error(f"signature of {ref}")


def is_commit(rev):
    """Whether a revision names a commit that exists in this checkout.

    Receives the label value (possibly empty); returns False for an empty value or
    an unknown commit.
    """
    return bool(rev) and ci.git_ok("cat-file", "-e", f"{rev}^{{commit}}")


def main(argv=None):
    """Read the publication request from the environment and run it.

    Reads OWNER, IMAGE (default, dx or gx), MAIN_REF, MAX_WALK, DRY_RUN, WRITE,
    REASON, ALLOW_BACKWARDS and, for the candidate, DIGEST or TAG. Returns 0 (moved,
    held, unchanged or dry run), 2 for an unknown IMAGE, and 1 through Stop for any
    refusal or read error.
    """
    ci.arg_parser(__doc__).parse_args(argv)
    owner = os.environ["OWNER"].lower()
    which = os.environ["IMAGE"]
    names = {"default": "octarine-os", "dx": "octarine-os-dx", "gx": "octarine-os-gx"}

    # only the three published images can be moved
    if which not in names:
        ci.log.error("IMAGE must be default, dx or gx")
        return 2
    img = f"ghcr.io/{owner}/{names[which]}"
    bimg = f"ghcr.io/{owner}/octarine-os"
    main_ref = os.environ.get("MAIN_REF") or "origin/main"
    max_walk = os.environ.get("MAX_WALK") or "60"
    dry = os.environ.get("DRY_RUN") or "false"
    write = os.environ.get("WRITE") or "false"
    reason = os.environ.get("REASON", "")
    back = os.environ.get("ALLOW_BACKWARDS") or "false"

    # Stop carries the exit status to return after its message was logged
    try:
        return publish(img, bimg, which, main_ref, max_walk, dry, write, reason, back)
    except Stop as e:
        return e.code


def publish(img, bimg, which, main_ref, max_walk, dry, write, reason, back):
    """Check the candidate and move `latest` to it when everything allows.

    Receives the image names, which image it is, the main ref, the walk length, the
    dry-run and write switches, the reason and the rollback switch. Returns 0 when
    nothing is to be moved or latest was moved; raises Stop (exit 1) when the
    candidate is unsigned, not built from main, unreadable or malformed.
    """
    ci.append_to("GITHUB_OUTPUT", "moved=false")

    # ---- 1. the candidate
    cand = os.environ.get("DIGEST", "")
    ctag = ""

    # no digest given: find the candidate by tag or by walking main
    if not cand:
        ctag = os.environ.get("TAG", "")
        # an explicit dated tag names the candidate
        if ctag:
            # only dated tags may be published; testing-* and latest are refused
            if not TAG_RE.fullmatch(ctag):
                raise Stop(
                    f"'{ctag}' is not a dated tag of {img} (latest-<sha7>, latest-<date>-<sha7> or <date>-<sha7>); testing-* and latest are refused"
                )
            cand = tag_digest(img, ctag)
            # the tag must exist
            if cand is None:
                raise Stop(f"{img}:{ctag} does not exist")
        elif which == "default":
            # walk main newest first until a commit has a published latest-<sha7>
            for c in ci.git(
                "rev-list", "--first-parent", f"--max-count={max_walk}", main_ref
            ).split():
                ctag = f"latest-{ci.git('rev-parse', '--short=7', c)}"
                # the first commit with a published image is the candidate
                if cand := tag_digest(img, ctag):
                    break
            else:
                raise Stop(
                    f"no published latest-<sha7> within the newest {max_walk} commits of {main_ref}"
                )
        else:
            raise Stop(
                f"{img}: a dated tag is required (TAG), there is no main commit to look it up by"
            )

    # whatever the source, the candidate must be a well-formed digest
    if not DIGEST_RE.fullmatch(cand):
        raise Stop(f"'{cand}' is not a sha256 digest")

    # ---- 2. verification: the candidate is signed; the default image was built from
    # main; a variant stands on such a default image
    must_be_signed(f"{img}@{cand}")

    # the default image carries its own revision; a variant carries its base's
    if which == "default":
        rev = label(img, cand, L_REV)
        root_desc = f"{img}@{cand}"
    else:
        base = label(img, cand, L_BASE)
        # a variant needs a usable base digest label
        if not DIGEST_RE.fullmatch(base):
            raise Stop(f"{img}@{cand} has no usable base digest label ('{base}')")
        must_be_signed(f"{bimg}@{base}")
        rev = label(bimg, base, L_REV)
        root_desc = f"{bimg}@{base} (the base of {img}@{cand})"

    # the revision label must name a commit of this repository
    if not is_commit(rev):
        raise Stop(
            f"{root_desc}: its revision label '{rev}' is not a commit of this repository"
        )

    # only images built from main may become latest
    if not ci.git_ok("merge-base", "--is-ancestor", rev, main_ref):
        raise Stop(
            f"{root_desc} was built from {rev}, which is not on {main_ref}: only images built from main are published as latest"
        )

    # ---- 3. ordering guard: never move latest backwards
    def older(candidate, current):
        """True when the candidate is older than the one under latest now."""
        cr, ur = label(img, candidate, L_REV), label(img, current, L_REV)
        cc, uc = label(img, candidate, L_CREATED), label(img, current, L_CREATED)

        # a latest without a usable revision cannot be compared: do not hold the
        # candidate
        if not is_commit(ur):
            ci.log.warning(
                f"the image under {img}:latest has no usable revision label ({ur or 'none'}): the ordering guard cannot compare"
            )
            return False

        # the same commit: the creation time decides which image is older
        if cr == ur:
            return bool(cc and uc and cc < uc)
        return ci.git_ok("merge-base", "--is-ancestor", cr, ur)

    # absent means none yet; a read error fails the run (it must not look like
    # "nothing is published", which would move latest unguarded)
    cur = tag_digest(img, "latest") or ""

    # a rollback may put an older verified image under latest
    if back == "true":
        ci.log.info(
            "ROLLBACK: the ordering guard is skipped; an older verified image may be put under latest"
        )
    elif cur and cur != cand and older(cand, cur):
        ci.summary(
            f"latest held: {img}:latest ({cur}) is newer than the candidate {cand}; nothing was moved{f' (reason: {reason})' if reason else ''}"
        )
        return 0

    # ---- 4. plan
    if cur == cand:
        ci.summary(
            f"latest unchanged: {img}:latest is already {cand}; nothing new was built"
        )
        return 0
    plan = f"{img}: latest {cur or 'none'} -> {cand} ({ctag or 'from the build run'}, main commit {rev[:7]})"

    # a dry run, or a run without permission to write, only reports the plan
    if dry == "true" or write != "true":
        ci.summary(f"DRY RUN ({dry}, write allowed: {write}): would move latest:")
        ci.summary(f"  {plan}")
        return 0

    # ---- 5. move; the copy is read back and verified
    try:
        registry.copy(f"{img}@{cand}", f"{img}:latest")
        # the read-back polls (a registry may show the previous manifest right after
        # a copy)
        registry.settled(img, "latest", cand)
    except ci.NetworkError as e:
        raise Stop(str(e))
    except registry.ReadError:
        raise Stop(f"{img}:latest does not show {cand} after the copy")
    must_be_signed(f"{img}:latest", fresh=True)
    ci.summary(
        f"{'ROLLBACK, ' if back == 'true' else ''}latest moved: {plan}{'; reason: ' + reason if reason else ''}"
    )
    ci.append_to("GITHUB_OUTPUT", "moved=true")
    return 0


# run as a script, not when imported by a test
if __name__ == "__main__":
    sys.exit(main())
