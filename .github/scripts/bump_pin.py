#!/usr/bin/env python3
"""Decides whether the digest pin of an EXTERNAL image (chunkah, which this repository
does not own) has to move to its `latest` tag, and rewrites the pin when it has. Used by
bump_run.py (the weekly workflow bump-pins.yml); run from the weekly workflow through
bump_run.py. Run from the repository root. Usage: bump_pin.py chunkah (brew and
octarine-bins are bumped through the `just brew-bump` / `just bins-bump` recipes.)

chunkah (quay.io/coreos/chunkah, pinned in config/chunkah.env as KEY=VALUE lines) is
verified KEYLESS (the GitHub Actions OIDC issuer and an identity under
https://github.com/coreos/chunkah/).

Steps: resolve the digest of <image>:latest (skopeo inspect --raw, sha256 of the
manifest, the way the pins are made), verify its cosign signature, compare it with the
pin, and when it differs rewrite the pin's digest line and its tag line (the dated tag
with the same digest, else `latest`; the tag is only a label for humans). Nothing else
in the file changes. With GITHUB_OUTPUT set it writes result, digest, tag and previous.

Exit status and result (the decision table):
  0  equal         the pin already is `latest`, the file is not touched
  10 different     `latest` is signed and newer, the pin was rewritten
  1  unreachable   `latest` could not be resolved (registry down, tag missing, empty
     answer): no decision possible
  2  badsignature  `latest` is not signed by the key: the file is not touched
  3  badpin        the pin in the file is missing or malformed, or an unknown image name
"""

import json
import os
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ci  # noqa: E402
import registry  # noqa: E402


def sed_value(text: str, key: str) -> str:
    """The value of the first `KEY=value` line (the `sed -n "s/^KEY=//p"` of the shell
    script); empty when there is none.
    """
    m = re.search(rf"^{key}=(.*)$", text, re.M)
    return m[1] if m else ""


def main(argv=None):
    """Look up the latest chunkah digest and write it into the pin file when it differs.

    Receives the image name (only chunkah). Reads CHUNKAH_ENV (default
    config/chunkah.env) and writes `result`, `previous`, `digest` and `tag` to
    GITHUB_OUTPUT. Exit status: 0 already current, 10 the pin file was changed, 1
    registry unreachable, 2 signature not verified, 3 the existing pin is malformed.
    """
    ap = ci.arg_parser(__doc__)
    ap.add_argument("image", choices=["chunkah"])
    ap.parse_args(argv)
    file = Path(os.environ.get("CHUNKAH_ENV") or "config/chunkah.env")
    prefix, repo = "CHUNKAH", "quay.io/coreos/chunkah"

    def out(key, value):
        """Write one step output.

        Receives the key and the value; appends `key=value` to GITHUB_OUTPUT
        when it is set.
        """
        ci.append_to("GITHUB_OUTPUT", f"{key}={value}")

    text = file.read_text() if file.is_file() else ""
    current = sed_value(text, f"{prefix}_DIGEST")
    current_tag = sed_value(text, f"{prefix}_TAG")

    # a malformed current pin is a mistake in the file, not something to bump over
    if not re.fullmatch(r"sha256:[0-9a-f]{64}", current):
        ci.log.error(f"{prefix}_DIGEST missing or malformed in {file}")
        out("result", "badpin")
        return 3
    out("previous", current)

    # the latest tag must resolve to a digest
    try:
        latest = registry.digest(repo, "latest")
    except registry.Absent, registry.ReadError:
        ci.log.error(
            f"cannot resolve {repo}:latest (registry unreachable or the tag does not exist yet)"
        )
        out("result", "unreachable")
        return 1
    out("digest", latest)

    # never pin an image whose signature does not verify
    try:
        registry.cosign_check(
            [
                "--certificate-oidc-issuer",
                "https://token.actions.githubusercontent.com",
                "--certificate-identity-regexp",
                "^https://github.com/coreos/chunkah/",
                f"{repo}@{latest}",
            ]
        )
    except registry.NotVerified, registry.ReadError:
        ci.log.error(
            f"cosign verification failed for {repo}@{latest} ({file} is unchanged)"
        )
        out("result", "badsignature")
        return 2
    ci.log.info(f"{repo}:latest = {latest} (signature valid)")

    # nothing to do when the pin already is the latest digest
    if latest == current:
        ci.log.info(f"nothing to bump: chunkah is pinned to {latest} ({current_tag})")
        out("result", "equal")
        out("tag", current_tag)
        return 0

    # the pin keeps a dated tag for humans: find the one that points at the same digest,
    # else fall back to latest
    tag = "latest"

    # the dated tags let a human read the pin; find the one with this digest
    try:
        tags = json.loads(
            ci.run(["skopeo", "list-tags", f"docker://{repo}"], capture=True).stdout
        )["Tags"]
    except ValueError, KeyError, TypeError:
        tags = []

    # check the ten newest dated tags for one with the same digest
    for t in sorted(
        (x for x in tags if re.fullmatch(r"latest-\d{8}-[0-9a-f]{7}", x)), reverse=True
    )[:10]:
        # a tag that cannot be read is skipped
        try:
            # the first dated tag with the same digest is the label
            if registry.digest(repo, t) == latest:
                tag = t
                break
        except registry.Absent, registry.ReadError:
            continue
    new = re.sub(
        rf"^{prefix}_TAG=.*$", lambda m: f"{prefix}_TAG={tag}", text, flags=re.M
    )
    new = re.sub(
        rf"^{prefix}_DIGEST=.*$", lambda m: f"{prefix}_DIGEST={latest}", new, flags=re.M
    )
    file.write_text(new)
    ci.log.info(f"{file} now pins {repo}:{tag}@{latest} (was {current_tag}@{current})")
    out("result", "different")
    out("tag", tag)
    return 10


# run as a script, not when imported by a test
if __name__ == "__main__":
    sys.exit(main())
