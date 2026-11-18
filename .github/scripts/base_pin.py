#!/usr/bin/env python3
"""Resolve the FLOATING base image (${BASE_IMAGE}:${FEDORA_VERSION}, Universal Blue's
silverblue-main) to a digest ONCE at the start of a run, verify its cosign signature
with the pinned Universal Blue key and print the pin; the build then runs FROM that
digest, so one run uses one base, and a base that is not signed by that key never gets
built on (fail closed).

Usage: base_pin.py     env: BASE_IMAGE, FEDORA_VERSION, KEY (default
                       keys/ublue-os-main-cosign.pub), GITHUB_ENV / GITHUB_STEP_SUMMARY
                       / GITHUB_OUTPUT when set

Prints and exports BASE_PIN=sha256:<manifest digest of the tag> (the sha256 of `skopeo
inspect --raw`, the way every pin here is made). Verification: the signature of
BASE_IMAGE@<pin>; for a manifest LIST whose own digest carries no signature, the
linux/amd64 child it names (an index digest pins its children, so a verified child is
the one this build uses). Neither verifies: exit 1 with an error that names a rotated
key as one possible cause (compare keys/ublue-os-main-cosign.pub with
https://github.com/ublue-os/main/blob/main/cosign.pub). Exit 1 too when the tag cannot
be resolved.
"""

import json
import os
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ci  # noqa: E402
import registry  # noqa: E402


def amd64_child(manifest: bytes) -> str:
    """The digest of the linux/amd64 manifest a manifest list names, or ''."""
    # a body that is not JSON has no children
    try:
        children = json.loads(manifest).get("manifests") or []
    except ValueError:
        return ""
    # the first linux/amd64 entry of the manifest list, if there is one
    return next(
        (
            m.get("digest", "")
            for m in children
            if (m.get("platform") or {}).get("os") == "linux"
            and (m.get("platform") or {}).get("architecture") == "amd64"
        ),
        "",
    )


def verified_by(image: str, pin: str, manifest: bytes, key: str):
    """(what verified the pin or None, the verdicts of the failed checks, whether a
    check could not be completed): the digest itself first, then the linux/amd64 child
    of a manifest list.
    """
    errors, unfinished = [], False
    candidates = [(pin, f"the signature of {pin}")]
    child = amd64_child(manifest)
    # a plain image has no linux/amd64 child; only a well-formed digest is a candidate
    if re.fullmatch(r"sha256:[0-9a-f]{64}", child):
        candidates.append((child, f"the signature of its linux/amd64 manifest {child}"))
    # try the pin itself first, then its amd64 child
    for digest, what in candidates:
        # NotVerified is a verdict; ReadError means the check could not be completed
        try:
            registry.cosign_check(["--key", key, f"{image}@{digest}"])
            return what, errors, unfinished
        except registry.NotVerified as e:
            errors.append(str(e))
        except registry.ReadError as e:
            errors.append(str(e))
            unfinished = True
    return None, errors, unfinished


def main(argv=None):
    """Resolve the base image tag to a digest and verify its signature.

    Reads BASE_IMAGE, FEDORA_VERSION and optionally KEY (the cosign public key,
    default keys/ublue-os-main-cosign.pub). Writes `BASE_PIN=<digest>` as the
    result, to GITHUB_ENV and GITHUB_OUTPUT (as `pin`) and a line to the step
    summary. Returns 0, or 1 with an error that says whether the tag could not be
    read, the signature is not visible yet or the key does not match.
    """
    ci.arg_parser(__doc__).parse_args(argv)
    image, ver = os.environ["BASE_IMAGE"], os.environ["FEDORA_VERSION"]
    key = os.environ.get("KEY") or "keys/ublue-os-main-cosign.pub"
    # the tag is the Fedora release number
    if not ver.isdigit():  # a Fedora release number
        ci.log.error(f"FEDORA_VERSION '{ver}' is not a number")
        return 1
    base = f"{image}:{ver}"
    # a missing tag and an unreadable registry need different advice
    try:
        manifest = registry.read("raw", base)
    except registry.ReadError:
        ci.log.error(
            f"cannot read {base} (a registry read error after the retries, not a missing tag): re-run; nothing was built"
        )
        return 1
    except registry.Absent:
        ci.log.error(
            f"cannot resolve {base} (does the tag exist? skopeo list-tags docker://{image})"
        )
        return 1
    pin = registry.sha256_of(manifest)
    verified, errors, unfinished = verified_by(image, pin, manifest, key)
    # no signature verified the pin: say why, from the most to the least transient cause
    if verified is None:
        joined = " ".join(errors)
        tail = ci.text(joined, 300)
        # a check that could not finish is a transient failure, not a verdict on the key
        if unfinished:
            # a check could not be completed (network, registry): a TRANSIENT failure,
            # not a verdict on the key
            ci.log.error(
                f"the signature of {base} ({pin}) could not be checked after the retries (a read error, not a wrong key): re-run; nothing was built. {tail}"
            )
        elif re.search("no signatures found", joined, re.I) and not re.search(
            "no matching signatures", joined, re.I
        ):
            ci.log.error(
                f"no signature is visible for {base} ({pin}) yet: Universal Blue may still be publishing it (a re-run in a while usually passes); the build stops. {tail}"
            )
        else:
            ci.log.error(
                f"{base} ({pin}) is not signed by {key}: the build stops. Possible causes: Universal Blue rotated its signing key (compare {key} with "
                f"https://github.com/ublue-os/main/blob/main/cosign.pub and replace it only after reading why), the image is unsigned, or it was replaced. {tail}"
            )
        return 1
    ci.result(f"BASE_PIN={pin}")
    ci.append_to("GITHUB_ENV", f"BASE_PIN={pin}")
    ci.append_to("GITHUB_OUTPUT", f"pin={pin}")
    ci.append_to(
        "GITHUB_STEP_SUMMARY",
        f"Base image: `{base}` resolved ONCE to `{pin}` and verified ({verified}) with `{key}`; the build is FROM that digest.",
    )
    return 0


# run as a script, not when imported by a test
if __name__ == "__main__":
    sys.exit(main())
