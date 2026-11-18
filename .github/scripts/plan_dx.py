#!/usr/bin/env python3
"""The plan of the variant image workflows (build-variant.yml for dx and gx,
build-extra.yml for dx-gx, nvidia-dx and nvidia-gx, both through the reusable
dx-image.yml): decide, for one channel, whether to skip, promote or build, and print
key=value lines to $GITHUB_OUTPUT. Run inside a checkout of the commit being built
(history needed on main).

Environment: CHANNEL (latest or testing), FORCE (true builds anyway),
GITHUB_REPOSITORY_OWNER, GITHUB_OUTPUT, VARIANT (dx, the default, or gx: which inputs
hash and which label are compared; the variant's own files are in inputs_hash.py),
GITHUB_STEP_SUMMARY (optional), MAX_WALK (default 60), BASE_NAME (default octarine-os),
DX_NAME (the image built: default octarine-os-<VARIANT>), BASE_DIGEST_PIN (channel
latest only: the default image's digest this run is built on, handed over by the
pipeline; without it the base is whatever `octarine-os:latest` is now, which is the
digest of the published pair), PROMOTE_FROM_TESTING (default true; false skips the
search for a tested testing image: the NVIDIA developer image has no testing channel).
Tools: git, skopeo, cosign. The NVIDIA developer image (build-extra.yml, variant
nvidia-dx) runs this with CHANNEL=latest BASE_NAME=octarine-os-nvidia
DX_NAME=octarine-os-nvidia-dx PROMOTE_FROM_TESTING=false: it skips when the NVIDIA base
digest and the dx inputs are unchanged.

Base: octarine-os:latest for the latest channel, resolved to the digest of its raw
manifest and verified with cosign.pub before anything is built on it. The testing
channel does NOT use the floating `testing` tag: it takes the immutable tag of the
commit being built, octarine-os:testing-<short sha> (the default build of that same
push). When that tag does not exist (the default build was reused for a dx-only or
docs-only change), it walks back like plan_vanilla_reuse.py to the nearest earlier
testing-<sha> built from the same default-image inputs; when there is none either, it
falls back to the floating `testing` tag and prints a warning. Reason: the floating tag
and the immutable tag of one build have been seen with different manifest digests, and a
base digest recorded from the floating tag then never matched the promoted `latest`
(push_tags.py now keeps one digest per build; this keeps the plan independent of the
floating tag anyway, and of a newer testing build landing while the dx build runs).

The published octarine-os-dx:<channel> carries two labels:
org.opencontainers.image.base.digest (the base it was built on) and
io.github.redcodeworks.octarine-os.dx-inputs (inputs_hash.py `dx` of the commit it was
built from); the gx image carries gx-inputs (inputs_hash.py `gx`). Everything below says
dx and means the variant.
  no force, both labels equal the current base digest and the current variant inputs ->
  skip   (build=false promote=false)
  channel latest, a tested octarine-os-dx testing image with the same two labels   ->
  promote (retag, no build)
  anything else (nothing published, unreadable, a label differs, force)            ->
  build
After a vanilla promote, octarine-os:latest has the digest of the tested
octarine-os:testing-<sha>, which is the base the dx testing image recorded: that
equality is what makes the promote match. Candidates for the promotion: the `testing`
tag, then `testing-<short sha>` of the newest MAX_WALK commits of HEAD (the testing
commits are the second parents of the merges on main); each must carry both labels and a
valid signature. Every lookup that fails means build, never skip.
"""

import os
import re
import sys
from pathlib import Path

here = Path(__file__).resolve().parent
sys.path[:0] = [str(here / "00-lib"), str(here)]
import ci  # noqa: E402
import inputs_hash as ih  # noqa: E402
import registry  # noqa: E402

env = os.environ.get
DIGEST_RE = re.compile(r"sha256:[0-9a-f]{64}")


def die(msg):
    """Log the error and exit 1 (the plan's own failures)."""
    ci.log.error(msg)
    raise SystemExit(1)


def raw_digest_of(ref: str) -> str:
    """The digest of the raw manifest of <image ref>; raises registry.Absent or
    registry.ReadError.
    """
    return registry.sha256_of(registry.read("raw", ref))


def verdict(ref: str) -> str:
    """cosign verify with the verdict told apart: "verified", "not verified" (cosign
    said so) or "unfinished" (could not be completed after the retries).
    """
    # cosign tells a bad signature (NotVerified) from a read error (ReadError)
    try:
        registry.cosign_check(["--key", "cosign.pub", ref])
    except registry.NotVerified:
        return "not verified"
    except registry.ReadError:
        return "unfinished"
    return "verified"


def main(argv=None):
    """Plan the build of one variant image (dx or gx) on one channel.

    Reads CHANNEL, VARIANT, FORCE, BASE_NAME, DX_NAME, BASE_DIGEST_PIN,
    PROMOTE_FROM_TESTING and MAX_WALK from the environment and writes the plan to
    the step output (build, promote, channel, base_tag, base_digest, inputs,
    source_tag, source_digest). Returns 0; every invalid input or unreadable
    registry stops the plan with exit 1 (die), never with a silent build or skip.
    """
    ci.arg_parser(__doc__).parse_args(argv)
    channel = os.environ["CHANNEL"]

    # only the two published channels have a base to build on
    if channel not in ("latest", "testing"):
        die(f"Unknown channel '{channel}' (latest or testing)")
    force = env("FORCE") or "false"
    owner = os.environ["GITHUB_REPOSITORY_OWNER"].lower()
    variant = env("VARIANT") or "dx"

    # the labels and names below exist for dx and gx only
    if variant not in ("dx", "gx"):
        die(f"Unknown variant '{variant}' (dx or gx)")
    # The image names are parameters (octarine-os-nvidia-dx sets
    # BASE_NAME=octarine-os-nvidia DX_NAME=octarine-os-nvidia-dx)
    base = f"ghcr.io/{owner}/{env('BASE_NAME') or 'octarine-os'}"
    dx = f"ghcr.io/{owner}/{env('DX_NAME') or f'octarine-os-{variant}'}"
    base_tag = channel
    l_base = "org.opencontainers.image.base.digest"
    l_inputs = f"io.github.redcodeworks.octarine-os.{variant}-inputs"

    # Registry reads follow ONE contract (registry.py): Absent = the tag does not exist,
    # ReadError = the registry could not be read (retried). An unreadable registry is an
    # ERROR here wherever a "missing" answer would send the plan down another path (a
    # different base, a rebuild instead of a promotion); it never means "absent".
    if channel == "testing":
        # nearest_image_for_inputs asks for the digest of testing-<sha> of the base
        # image
        mine = f"testing-{ci.git('rev-parse', '--short=7', 'HEAD')}"
        # prefer the default image built from this very commit
        try:
            raw_digest_of(f"{base}:{mine}")
            base_tag = mine
        except registry.Absent:
            # no image for this commit (the default build was reused): find the earlier
            # one
            try:
                found, _ = ih.nearest_image_for_inputs(
                    "HEAD", lambda tag: raw_digest_of(f"{base}:{tag}")
                )
                base_tag = found
                ci.log.info(
                    f"No {base}:{mine} (the default build was reused): using the nearest earlier {base_tag}, built from the same default-image inputs"
                )
            except ih.Unreadable:
                die(
                    "Could not read the registry while looking for an earlier testing image (a read error, not a missing image): not falling back to the floating tag"
                )
            except ih.NoImage:
                base_tag = "testing"
                ci.log.warning(
                    f"No {base}:{mine} and no earlier testing image with the same default-image inputs: falling back to the floating {base}:testing"
                )
        except registry.ReadError:
            die(
                f"Could not read {base}:{mine} (a registry read error, not a missing tag): not falling back to another base"
            )
    pin = env("BASE_DIGEST_PIN") or ""

    # a pinned digest (from the pipeline that just published the default image) is the
    # base
    if pin:
        # The default image this run is meant for, handed over by the pipeline that just
        # published it (channel latest on main). `latest` is not moved before dx has
        # passed, so it is NOT the base here: the base is exactly this digest, which
        # must exist as the image of the default repository and hash to itself. The
        # signature is verified below like any other base.
        if channel != "latest":
            die(f"BASE_DIGEST_PIN is only for the channel latest (got {channel})")
        # a malformed pin must not reach the registry
        if not DIGEST_RE.fullmatch(pin):
            die(f"BASE_DIGEST_PIN '{pin}' is not sha256:<64 hex>")
        # the pinned digest must exist and hash to itself, or it is not the image it
        # names
        try:
            raw = registry.read("raw", f"{base}@{pin}")
        except registry.ReadError:
            die(f"Cannot read {base}@{pin}")
        # a registry that returns other bytes for a digest is not to be trusted
        if registry.sha256_of(raw) != pin:
            die(f"{base}@{pin} does not hash to its digest")
        digest = pin
        base_tag = "latest"
        ci.log.info(f"Base pinned by the pipeline: {base}@{digest}")
    else:
        # no pin: read the digest of the channel tag
        try:
            digest = raw_digest_of(f"{base}:{base_tag}")
        except registry.ReadError:
            die(f"Cannot read {base}:{base_tag}")

    # never build on a base whose signature does not verify
    if verdict(f"{base}@{digest}") != "verified":
        die(
            f"The base {base}@{digest} did not verify (or could not be checked: see the message above): nothing is built on it"
        )
    ci.log.info(f"Base image {base}:{base_tag} = {digest} (signature valid)")

    inputs = {"dx": ih.dx_inputs, "gx": ih.gx_inputs}[variant]("HEAD")
    ci.log.info(f"{variant} inputs of this commit: {inputs}")

    def labels_of(tag):
        """(status, base digest, inputs): the labels of a published tag ('-' for a
        missing label), status ok, absent or unreadable.
        """
        # a missing tag and an unreadable registry give different statuses
        try:
            lab = registry.labels(registry.read("config", f"{dx}:{tag}"))
        except registry.Absent:
            return "absent", "", ""
        except registry.ReadError:
            return "unreadable", "", ""
        return "ok", lab.get(l_base) or "-", lab.get(l_inputs) or "-"

    build, promote = True, False
    source_tag = source_digest = ""
    rc, cur_base, cur_inputs = labels_of(channel)

    # an unreadable or absent published image never allows a skip
    if rc != "ok":
        # absent or unreadable: both mean "build, never skip" for the PUBLISHED image of
        # this channel (a skip needs a positive read)
        cur_base = cur_inputs = ""
        # only a missing tag is an ordinary first build; an unreadable one is a warning
        if rc == "absent":
            ci.log.info(f"No published {dx}:{channel} yet")
        else:
            ci.log.warning(
                f"{dx}:{channel} could not be read (a read error): building, never skipping on a failed read"
            )

    # a forced run builds whatever is published; otherwise compare base and inputs
    if force == "true":
        decision = (
            f"forced: building although the published image is {cur_base or 'unknown'}"
        )
    elif cur_base and cur_base == digest and cur_inputs == inputs:
        # No signature check here: the moving tags (`testing`, and `latest` by Publish
        # latest) are moved only AFTER their digest is signed and verified, so a
        # published tag is always a signed image (a run cancelled earlier leaves the
        # previous one in place)
        build = False
        decision = f"skipped: base and {variant} inputs unchanged ({channel}: {digest})"
    else:
        # say why the published image is stale, for the log
        if cur_base:
            # the base moved since the published image was built
            if cur_base != digest:
                ci.log.info(
                    f"The published {variant} image was built from {cur_base}, the base is now {digest}"
                )
            # the variant inputs changed since the published image was built
            if cur_inputs != inputs:
                ci.log.info(
                    f"The {variant} inputs changed since the published {variant} image ({cur_inputs} -> {inputs})"
                )
        decision = "building"
        # on latest a tested testing image can be promoted instead of building
        if channel == "latest" and (env("PROMOTE_FROM_TESTING") or "true") == "true":
            maximum = env("MAX_WALK") or "60"
            # the candidates: the floating testing tag, then testing-<sha> of the newest
            # commits
            tags = ["testing"] + [
                f"testing-{ci.git('rev-parse', '--short=7', c)}"
                for c in ci.git("rev-list", f"--max-count={maximum}", "HEAD").split()
            ]
            # each candidate needs equal base, equal inputs and a valid signature
            for t in tags:
                rc, t_base, t_inputs = labels_of(t)
                # no such candidate tag: keep walking
                if rc == "absent":
                    continue  # no such candidate tag
                # an unreadable candidate must not turn into a rebuild of untested
                # content
                if rc != "ok":
                    die(
                        f"Could not read the labels of {dx}:{t} (a registry read error, not a missing tag): not building instead of promoting"
                    )
                # only an image built from this base and these inputs may be promoted
                if not (t_base == digest and t_inputs == inputs):
                    continue
                # the manifest digest to promote and verify
                try:
                    d = raw_digest_of(f"{dx}:{t}")
                except registry.ReadError as e:
                    die(
                        f"Could not read the manifest of {dx}:{t} ({e}): not building instead of promoting"
                    )
                answer = verdict(f"{dx}@{d}")
                # a signed match is promoted without a rebuild
                if answer == "verified":
                    build, promote, source_tag, source_digest = False, True, t, d
                    decision = f"promoting {t} ({source_digest}): same base digest and {variant} inputs, signed"
                    break
                # a check that could not finish is an error, not a verdict on the key
                if answer == "unfinished":
                    die(
                        f"Could not complete the signature check of {dx}:{t} (a read error, not a bad signature): not building instead of promoting"
                    )
                ci.log.warning(
                    f"{t} matches but its signature does not verify; not promoting it"
                )
            # nothing promotable was found
            if not promote:
                decision = f"building (no tested testing image with this base digest and these {variant} inputs)"
    ci.log.info(f"{variant} {channel}: {decision}")
    ci.append_to("GITHUB_STEP_SUMMARY", f"{variant} {channel}: {decision}")

    # tell the log when there is nothing to do at all
    if not build and not promote:
        ci.log.info(f"::notice::base unchanged, nothing to build ({channel}: {digest})")
    os.environ["GITHUB_OUTPUT"]  # required: the plan's answer goes there

    # publish the plan as step outputs
    for key, value in (
        ("build", str(build).lower()),
        ("promote", str(promote).lower()),
        ("channel", channel),
        ("base_tag", base_tag),
        ("base_digest", digest),
        ("inputs", inputs),
        ("source_tag", source_tag),
        ("source_digest", source_digest),
    ):
        ci.append_to("GITHUB_OUTPUT", f"{key}={value}")
    return 0


# run as a script, not when imported by a test
if __name__ == "__main__":
    sys.exit(main())
