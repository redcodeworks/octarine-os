#!/usr/bin/env python3
"""The plan of the variant image workflows (build-variant.yml for dx and gx, build-extra.yml for dx-gx, nvidia-dx and nvidia-gx, both through the reusable dx-image.yml): decide, for one channel, whether
to skip, promote or build, and print key=value lines to $GITHUB_OUTPUT. Run inside a checkout of the commit being built (history needed on main).

Environment: CHANNEL (latest or testing), FORCE (true builds anyway), GITHUB_REPOSITORY_OWNER, GITHUB_OUTPUT, VARIANT (dx, the default, or gx: which inputs hash and which label are compared; the
variant's own files are in inputs_hash.py), GITHUB_STEP_SUMMARY (optional), MAX_WALK (default 60), BASE_NAME (default octarine-os), DX_NAME (the image built: default octarine-os-<VARIANT>),
BASE_DIGEST_PIN (channel latest only: the default image's digest this run is built on, handed over by the pipeline; without it the base is whatever `octarine-os:latest` is now, which is the digest of
the published pair), PROMOTE_FROM_TESTING (default true; false skips the search for a tested testing image: the NVIDIA developer image has no testing channel). Tools: git, skopeo, cosign.
The NVIDIA developer image (build-extra.yml, variant nvidia-dx) runs this with CHANNEL=latest BASE_NAME=octarine-os-nvidia DX_NAME=octarine-os-nvidia-dx PROMOTE_FROM_TESTING=false: it skips when the
NVIDIA base digest and the dx inputs are unchanged.

Base: octarine-os:latest for the latest channel, resolved to the digest of its raw manifest and verified with cosign.pub before anything is built on it. The testing channel does NOT use the floating
`testing` tag: it takes the immutable tag of the commit being built, octarine-os:testing-<short sha> (the default build of that same push). When that tag does not exist (the default build was reused for
a dx-only or docs-only change), it walks back like plan_vanilla_reuse.py to the nearest earlier testing-<sha> built from the same default-image inputs; when there is none either, it falls back to the
floating `testing` tag and prints a warning. Reason: the floating tag and the immutable tag of one build have been seen with different manifest digests, and a base digest recorded from the floating
tag then never matched the promoted `latest` (push_tags.py now keeps one digest per build; this keeps the plan independent of the floating tag anyway, and of a newer testing build landing while the
dx build runs).

The published octarine-os-dx:<channel> carries two labels: org.opencontainers.image.base.digest (the base it was built on) and io.github.redcodeworks.octarine-os.dx-inputs (inputs_hash.py `dx` of the
commit it was built from); the gx image carries gx-inputs (inputs_hash.py `gx`). Everything below says dx and means the variant.
  no force, both labels equal the current base digest and the current variant inputs -> skip   (build=false promote=false)
  channel latest, a tested octarine-os-dx testing image with the same two labels   -> promote (retag, no build)
  anything else (nothing published, unreadable, a label differs, force)            -> build
After a vanilla promote, octarine-os:latest has the digest of the tested octarine-os:testing-<sha>, which is the base the dx testing image recorded: that equality is what makes the promote match.
Candidates for the promotion: the `testing` tag, then `testing-<short sha>` of the newest MAX_WALK commits of HEAD (the testing commits are the second parents of the merges on main); each must carry
both labels and a valid signature. Every lookup that fails means build, never skip.
"""
import os
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ci  # noqa: E402
import inputs_hash as ih  # noqa: E402
import registry  # noqa: E402

env = os.environ.get
DIGEST_RE = re.compile(r"sha256:[0-9a-f]{64}")


def die(msg):
    """`::error::<msg>` on stdout and exit 1 (the plan's own failures)."""
    print(f"::error::{msg}")
    raise SystemExit(1)


def raw_digest_of(ref: str, quiet: bool = False) -> str:
    """The digest of the raw manifest of <image ref>; raises registry.Absent (3) or registry.ReadError (4)."""
    return registry.sha256_of(registry.read("raw", ref, quiet=quiet))


def verify(ref: str, quiet: bool = False) -> int:
    """cosign verify with the verdict told apart: 0 verified, 5 not verified, 4 could not be completed (retried)."""
    return registry.verify_code(["--key", "cosign.pub", ref], sink=(lambda m: None) if quiet else ci.err)


def main():
    channel = env("CHANNEL") or sys.exit("CHANNEL: parameter null or not set")
    if channel not in ("latest", "testing"):
        die(f"Unknown channel '{channel}' (latest or testing)")
    force = env("FORCE") or "false"
    owner = (env("GITHUB_REPOSITORY_OWNER") or sys.exit("GITHUB_REPOSITORY_OWNER: parameter null or not set")).lower()
    variant = env("VARIANT") or "dx"
    if variant not in ("dx", "gx"):
        die(f"Unknown variant '{variant}' (dx or gx)")
    # The image names are parameters (octarine-os-nvidia-dx sets BASE_NAME=octarine-os-nvidia DX_NAME=octarine-os-nvidia-dx)
    base = f"ghcr.io/{owner}/{env('BASE_NAME') or 'octarine-os'}"
    dx = f"ghcr.io/{owner}/{env('DX_NAME') or f'octarine-os-{variant}'}"
    base_tag = channel
    l_base = "org.opencontainers.image.base.digest"
    l_inputs = f"io.github.redcodeworks.octarine-os.{variant}-inputs"

    # Registry reads follow ONE contract (registry.py): Absent = the tag does not exist, ReadError = the registry could not be read (retried). An unreadable registry is an ERROR here wherever a
    # "missing" answer would send the plan down another path (a different base, a rebuild instead of a promotion); it never means "absent".
    if channel == "testing":
        # nearest_image_for_inputs asks for the digest of testing-<sha> of the base image
        mine = f"testing-{ci.git('rev-parse', '--short=7', 'HEAD')}"
        try:
            raw_digest_of(f"{base}:{mine}")
            base_tag = mine
        except registry.Absent:
            try:
                found, _ = ih.nearest_image_for_inputs("HEAD", lambda tag: raw_digest_of(f"{base}:{tag}", quiet=True))
                base_tag = found
                print(f"No {base}:{mine} (the default build was reused): using the nearest earlier {base_tag}, built from the same default-image inputs")
            except ih.Unreadable:
                die("Could not read the registry while looking for an earlier testing image (a read error, not a missing image): not falling back to the floating tag")
            except ih.NoImage:
                base_tag = "testing"
                print(f"::warning::No {base}:{mine} and no earlier testing image with the same default-image inputs: falling back to the floating {base}:testing")
        except registry.RegistryError:
            die(f"Could not read {base}:{mine} (a registry read error, not a missing tag): not falling back to another base")
    pin = env("BASE_DIGEST_PIN") or ""
    if pin:
        # The default image this run is meant for, handed over by the pipeline that just published it (channel latest on main). `latest` is not moved before dx has passed, so it is NOT the base here:
        # the base is exactly this digest, which must exist as the image of the default repository and hash to itself. The signature is verified below like any other base.
        if channel != "latest":
            die(f"BASE_DIGEST_PIN is only for the channel latest (got {channel})")
        if not DIGEST_RE.fullmatch(pin):
            die(f"BASE_DIGEST_PIN '{pin}' is not sha256:<64 hex>")
        try:
            raw = registry.read("raw", f"{base}@{pin}")
        except registry.RegistryError:
            die(f"Cannot read {base}@{pin}")
        if registry.sha256_of(raw) != pin:
            die(f"{base}@{pin} does not hash to its digest")
        digest = pin
        base_tag = "latest"
        print(f"Base pinned by the pipeline: {base}@{digest}")
    else:
        try:
            digest = raw_digest_of(f"{base}:{base_tag}")
        except registry.RegistryError:
            die(f"Cannot read {base}:{base_tag}")
    if verify(f"{base}@{digest}") != 0:
        die(f"The base {base}@{digest} did not verify (or could not be checked: see the message above): nothing is built on it")
    print(f"Base image {base}:{base_tag} = {digest} (signature valid)")

    inputs = {"dx": ih.dx_inputs, "gx": ih.gx_inputs}[variant]("HEAD")
    print(f"{variant} inputs of this commit: {inputs}")

    def labels_of(tag):
        """(code, base digest, inputs): the labels of a published tag ('-' for a missing label), code 3 absent, 4 unreadable."""
        try:
            lab = registry.labels(registry.read("config", f"{dx}:{tag}"))
        except registry.RegistryError as e:
            return e.code, "", ""
        return 0, lab.get(l_base) or "-", lab.get(l_inputs) or "-"

    build, promote = True, False
    source_tag = source_digest = ""
    rc, cur_base, cur_inputs = labels_of(channel)
    if rc != 0:
        # absent (3) or unreadable (4): both mean "build, never skip" for the PUBLISHED image of this channel (a skip needs a positive read)
        cur_base = cur_inputs = ""
        if rc == 3:
            print(f"No published {dx}:{channel} yet")
        else:
            print(f"::warning::{dx}:{channel} could not be read (a read error): building, never skipping on a failed read")
    if force == "true":
        decision = f"forced: building although the published image is {cur_base or 'unknown'}"
    elif cur_base and cur_base == digest and cur_inputs == inputs:
        # No signature check here: the moving tags (`testing`, and `latest` by Publish latest) are moved only AFTER their digest is signed and verified, so a published tag is always a signed image
        # (a run cancelled earlier leaves the previous one in place)
        build = False
        decision = f"skipped: base and {variant} inputs unchanged ({channel}: {digest})"
    else:
        if cur_base:
            if cur_base != digest:
                print(f"The published {variant} image was built from {cur_base}, the base is now {digest}")
            if cur_inputs != inputs:
                print(f"The {variant} inputs changed since the published {variant} image ({cur_inputs} -> {inputs})")
        decision = "building"
        if channel == "latest" and (env("PROMOTE_FROM_TESTING") or "true") == "true":
            maximum = env("MAX_WALK") or "60"
            tags = ["testing"] + [f"testing-{ci.git('rev-parse', '--short=7', c)}" for c in ci.git("rev-list", f"--max-count={maximum}", "HEAD").split()]
            for t in tags:
                rc, t_base, t_inputs = labels_of(t)
                if rc == 3:
                    continue  # no such candidate tag
                if rc != 0:
                    die(f"Could not read the labels of {dx}:{t} (a registry read error, not a missing tag): not building instead of promoting")
                if not (t_base == digest and t_inputs == inputs):
                    continue
                try:
                    d = raw_digest_of(f"{dx}:{t}")
                except registry.RegistryError as e:
                    die(f"Could not read the manifest of {dx}:{t} (exit {e.code}): not building instead of promoting")
                rc = verify(f"{dx}@{d}", quiet=True)
                if rc == 0:
                    build, promote, source_tag, source_digest = False, True, t, d
                    decision = f"promoting {t} ({source_digest}): same base digest and {variant} inputs, signed"
                    break
                if rc != 5:
                    die(f"Could not complete the signature check of {dx}:{t} (a read error, not a bad signature): not building instead of promoting")
                print(f"::warning::{t} matches but its signature does not verify; not promoting it")
            if not promote:
                decision = f"building (no tested testing image with this base digest and these {variant} inputs)"
    print(f"{variant} {channel}: {decision}")
    ci.summary(f"{variant} {channel}: {decision}", echo=False)
    if not build and not promote:
        print(f"::notice::base unchanged, nothing to build ({channel}: {digest})")
    if not env("GITHUB_OUTPUT"):
        sys.exit("GITHUB_OUTPUT: parameter null or not set")
    for key, value in (("build", str(build).lower()), ("promote", str(promote).lower()), ("channel", channel), ("base_tag", base_tag), ("base_digest", digest), ("inputs", inputs),
                       ("source_tag", source_tag), ("source_digest", source_digest)):
        ci.output(key, value)
    return 0


if __name__ == "__main__":
    sys.exit(main())
