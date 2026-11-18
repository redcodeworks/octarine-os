#!/usr/bin/env python3
"""Print the verified reference of the chunkah image for `just rechunk`: <image>@<digest> from config/chunkah.env, after cosign accepted its keyless signature (the GitHub Actions OIDC
issuer, an identity under https://github.com/coreos/chunkah/). Usage: chunkah_ref.py [config/chunkah.env]        (CHUNKAH_ENV overrides the path, for tests)

Fails (exit 1) when the pin is malformed or the verification fails: a rechunk never runs an unverified image. The tag in config/chunkah.env is only a label.
"""

import os
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ci  # noqa: E402
import registry  # noqa: E402


def parse_env(path: Path) -> dict:
    """KEY=VALUE lines of a pin file: comments (#) and blank lines are skipped, anything else must be KEY=VALUE with an upper-case key; ValueError otherwise."""
    values = {}
    for line in path.read_text().splitlines():
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        if not (m := re.fullmatch(r"([A-Z_]+)=(.*)", line)):
            raise ValueError(f"{path}: not KEY=VALUE: '{line}'")
        values[m[1]] = m[2]
    return values


def main(argv=None):
    ap = ci.arg_parser(__doc__)
    ap.add_argument("file", nargs="?", default=os.environ.get("CHUNKAH_ENV") or "config/chunkah.env")
    file = Path(ap.parse_args(argv).file)
    if not file.is_file():
        ci.log.error(f"{file} not found")
        return 1
    try:
        pin = parse_env(file)
    except ValueError as e:
        ci.log.error(str(e))
        return 1
    image, digest = pin.get("CHUNKAH_IMAGE", ""), pin.get("CHUNKAH_DIGEST", "")
    if not re.fullmatch(r"[a-z0-9.-]+(:[0-9]+)?(/[a-z0-9._-]+)+", image):
        ci.log.error(f"bad CHUNKAH_IMAGE '{image}'")
        return 1
    if not re.fullmatch(r"sha256:[0-9a-f]{64}", digest):
        ci.log.error(f"bad CHUNKAH_DIGEST '{digest}'")
        return 1
    ref = f"{image}@{digest}"
    try:
        registry.cosign_check(["--certificate-oidc-issuer", "https://token.actions.githubusercontent.com", "--certificate-identity-regexp", "^https://github.com/coreos/chunkah/", ref])
    except registry.NotVerified, registry.ReadError:
        ci.log.error(f"cosign verification of {ref} failed: the chunkah image is not trusted, nothing is rechunked (a changed signing identity upstream, or a bad pin: check config/chunkah.env)")
        return 1
    try:
        registry.pull(ref)  # now, with retries, so `just rechunk` does not pull inside its single `podman run`
    except ci.NetworkError:
        ci.log.error(f"could not pull {ref}")
        return 1
    print(ref)
    return 0


if __name__ == "__main__":
    sys.exit(main())
