#!/usr/bin/env python3
"""Decides whether the digest pin of an EXTERNAL image (chunkah, which this repository does not own) has to move to its `latest` tag, and rewrites the pin when it has. Used by bump_run.py (the weekly
workflow bump-pins.yml); run from the weekly workflow through bump_run.py. Run from the repository root. Usage: bump_pin.py chunkah
(brew and octarine-bins are bumped through the `just brew-bump` / `just bins-bump` recipes.)

chunkah (quay.io/coreos/chunkah, pinned in config/chunkah.env as KEY=VALUE lines) is verified KEYLESS (the GitHub Actions OIDC issuer and an identity under https://github.com/coreos/chunkah/).

Steps: resolve the digest of <image>:latest (skopeo inspect --raw, sha256 of the manifest, the way the pins are made), verify its cosign signature, compare it with the pin, and when it differs rewrite
the pin's digest line and its tag line (the dated tag with the same digest, else `latest`; the tag is only a label for humans). Nothing else in the file changes. With GITHUB_OUTPUT set it writes
result, digest, tag and previous.

Exit status and result (the decision table):
  0  equal         the pin already is `latest`, the file is not touched
  10 different     `latest` is signed and newer, the pin was rewritten
  1  unreachable   `latest` could not be resolved (registry down, tag missing, empty answer): no decision possible
  2  badsignature  `latest` is not signed by the key: the file is not touched
  3  badpin        the pin in the file is missing or malformed, or an unknown image name
"""
import json
import os
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ci  # noqa: E402
import registry  # noqa: E402


def sed_value(text: str, key: str) -> str:
    """The value of the first `KEY=value` line (the `sed -n "s/^KEY=//p"` of the shell script); empty when there is none."""
    m = re.search(rf"^{key}=(.*)$", text, re.M)
    return m[1] if m else ""


def main(argv):
    image = argv[0] if argv else ""
    if image != "chunkah":
        print(f"::error::unknown image '{image}' (chunkah)")
        return 3
    file = Path(os.environ.get("CHUNKAH_ENV") or "config/chunkah.env")
    prefix, repo = "CHUNKAH", "quay.io/coreos/chunkah"

    def out(key, value):
        ci.output(key, value)

    text = file.read_text() if file.is_file() else ""
    current = sed_value(text, f"{prefix}_DIGEST")
    current_tag = sed_value(text, f"{prefix}_TAG")
    if not re.fullmatch(r"sha256:[0-9a-f]{64}", current):
        print(f"::error::{prefix}_DIGEST missing or malformed in {file}")
        out("result", "badpin")
        return 3
    out("previous", current)

    p = ci.capture(["skopeo", "inspect", "--raw", f"docker://{repo}:latest"])
    manifest = p.stdout.rstrip(b"\n") if p.returncode == 0 else b""
    if not manifest:
        print(f"::error::cannot resolve {repo}:latest (registry unreachable or the tag does not exist yet)")
        out("result", "unreachable")
        return 1
    latest = registry.sha256_of(manifest)
    out("digest", latest)

    verify = ["cosign", "verify", "--certificate-oidc-issuer", "https://token.actions.githubusercontent.com", "--certificate-identity-regexp", "^https://github.com/coreos/chunkah/", f"{repo}@{latest}"]
    if ci.run(verify, stdout=subprocess.DEVNULL).returncode != 0:
        print(f"::error::cosign verification failed for {repo}@{latest} ({file} is unchanged)")
        out("result", "badsignature")
        return 2
    print(f"{repo}:latest = {latest} (signature valid)")

    if latest == current:
        print(f"nothing to bump: {image} is pinned to {latest} ({current_tag})")
        out("result", "equal")
        out("tag", current_tag)
        return 0

    # the pin keeps a dated tag for humans: find the one that points at the same digest, else fall back to latest
    tag = "latest"
    try:
        tags = json.loads(ci.capture(["skopeo", "list-tags", f"docker://{repo}"]).stdout)["Tags"]
    except (ValueError, KeyError, TypeError):
        tags = []
    for t in sorted((x for x in tags if re.fullmatch(r"latest-\d{8}-[0-9a-f]{7}", x)), reverse=True)[:10]:
        raw = ci.capture(["skopeo", "inspect", "--raw", f"docker://{repo}:{t}"]).stdout
        if registry.sha256_of(raw) == latest:
            tag = t
            break
    new = re.sub(rf"^{prefix}_TAG=.*$", lambda m: f"{prefix}_TAG={tag}", text, flags=re.M)
    new = re.sub(rf"^{prefix}_DIGEST=.*$", lambda m: f"{prefix}_DIGEST={latest}", new, flags=re.M)
    file.write_text(new)
    print(f"{file} now pins {repo}:{tag}@{latest} (was {current_tag}@{current})")
    out("result", "different")
    out("tag", tag)
    return 10


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
