#!/usr/bin/env python3
"""Print the verified reference of the chunkah image for `just rechunk`:
<image>@<digest> from config/chunkah.env, after cosign accepted its keyless signature
(the GitHub Actions OIDC issuer, an identity under https://github.com/coreos/chunkah/).
Usage: chunkah_ref.py [config/chunkah.env]        (CHUNKAH_ENV overrides the path, for
tests)

Fails (exit 1) when the pin is malformed or the verification fails: a rechunk never runs
an unverified image. The tag in config/chunkah.env is only a label.
"""

import os
import re
import sys
from pathlib import Path

here = Path(__file__).resolve().parent
sys.path[:0] = [str(here.parent / "00-lib"), str(here)]
import ci  # noqa: E402
import registry  # noqa: E402


def parse_env(path: Path) -> dict:
    """KEY=VALUE lines of a pin file: comments (#) and blank lines are skipped, anything
    else must be KEY=VALUE with an upper-case key; ValueError otherwise.
    """
    values = {}

    # read the pin file line by line
    for line in path.read_text().splitlines():
        line = line.split("#", 1)[0].strip()
        # blank and comment-only lines carry nothing
        if not line:
            continue
        # any other line must be KEY=VALUE with an upper-case key
        if not (m := re.fullmatch(r"([A-Z_]+)=(.*)", line)):
            raise ValueError(f"{path}: not KEY=VALUE: '{line}'")
        values[m[1]] = m[2]
    return values


def main(argv=None):
    """Verify the pinned chunkah image and print its reference.

    Receives the pin file path (default config/chunkah.env or $CHUNKAH_ENV). Checks
    the pin is well formed, that cosign accepts the keyless signature of the digest
    and that the image can be pulled; writes `<image>@<digest>` as the result.
    Returns 0, or 1 with an error for a missing or malformed pin, a failed
    verification or a failed pull: an unverified image is never used.
    """
    ap = ci.arg_parser(__doc__)
    ap.add_argument(
        "file", nargs="?", default=os.environ.get("CHUNKAH_ENV") or "config/chunkah.env"
    )
    file = Path(ap.parse_args(argv).file)

    # the pin file must exist
    if not file.is_file():
        ci.log.error(f"{file} not found")
        return 1
    # a malformed pin file is an error, not an empty pin
    try:
        pin = parse_env(file)
    except ValueError as e:
        ci.log.error(str(e))
        return 1
    image, digest = pin.get("CHUNKAH_IMAGE", ""), pin.get("CHUNKAH_DIGEST", "")

    # the image must look like a registry reference
    if not re.fullmatch(r"[a-z0-9.-]+(:[0-9]+)?(/[a-z0-9._-]+)+", image):
        ci.log.error(f"bad CHUNKAH_IMAGE '{image}'")
        return 1
    # the digest must be a sha256 digest
    if not re.fullmatch(r"sha256:[0-9a-f]{64}", digest):
        ci.log.error(f"bad CHUNKAH_DIGEST '{digest}'")
        return 1
    ref = f"{image}@{digest}"

    # an image that does not verify (or cannot be checked) is not trusted
    try:
        registry.cosign_check(
            [
                "--certificate-oidc-issuer",
                "https://token.actions.githubusercontent.com",
                "--certificate-identity-regexp",
                "^https://github.com/coreos/chunkah/",
                ref,
            ]
        )
    except registry.NotVerified, registry.ReadError:
        ci.log.error(
            f"cosign verification of {ref} failed: the chunkah image is not trusted, nothing is rechunked (a changed signing identity upstream, or a bad pin: check config/chunkah.env)"
        )
        return 1

    # pull now, with retries, so the rechunk does not pull inside its own run
    try:
        # now, with retries, so `just rechunk` does not pull inside its single
        # `podman run`
        registry.pull(ref)
    except ci.NetworkError:
        ci.log.error(f"could not pull {ref}")
        return 1
    ci.result(ref)
    return 0


# run as a script, not when imported by a test
if __name__ == "__main__":
    sys.exit(main())
