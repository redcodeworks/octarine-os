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


def parse_env(path: Path) -> dict:
    """KEY=VALUE lines of a pin file: comments (#) and blank lines are skipped, anything else must be KEY=VALUE with an upper-case key."""
    values = {}
    for line in path.read_text().splitlines():
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        m = re.fullmatch(r"([A-Z_]+)=(.*)", line)
        if not m:
            ci.err(f"::error::{path}: not KEY=VALUE: '{line}'")
            raise SystemExit(1)
        values[m[1]] = m[2]
    return values


def main(argv):
    file = Path(argv[0] if argv else os.environ.get("CHUNKAH_ENV") or "config/chunkah.env")
    if not file.is_file():
        ci.err(f"::error::{file} not found")
        return 1
    v = parse_env(file)
    image, digest = v.get("CHUNKAH_IMAGE", ""), v.get("CHUNKAH_DIGEST", "")
    if not re.fullmatch(r"[a-z0-9.-]+(:[0-9]+)?(/[a-z0-9._-]+)+", image):
        ci.err(f"::error::bad CHUNKAH_IMAGE '{image}'")
        return 1
    if not re.fullmatch(r"sha256:[0-9a-f]{64}", digest):
        ci.err(f"::error::bad CHUNKAH_DIGEST '{digest}'")
        return 1
    ref = f"{image}@{digest}"
    verify = ["cosign", "verify", "--certificate-oidc-issuer", "https://token.actions.githubusercontent.com", "--certificate-identity-regexp", "^https://github.com/coreos/chunkah/", ref]
    if ci.retry_command(verify, quiet_stdout=True) != 0:
        ci.err(f"::error::cosign verification of {ref} failed: the chunkah image is not trusted, nothing is rechunked (a changed signing identity upstream, or a bad pin: check config/chunkah.env)")
        return 1
    # pull it now (with retries) so `just rechunk` does not pull inside its single `podman run`
    if ci.retry_command(["podman", "pull", ref], quiet_stdout=True) != 0:
        ci.err(f"::error::could not pull {ref}")
        return 1
    print(ref)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
