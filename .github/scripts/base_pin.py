#!/usr/bin/env python3
"""Resolve the FLOATING base image (${BASE_IMAGE}:${FEDORA_VERSION}, Universal Blue's silverblue-main) to a digest ONCE at the start of a run, verify its cosign signature with the pinned
Universal Blue key and print the pin; the build then runs FROM that digest, so one run uses one base, and a base that is not signed by that key never gets built on (fail closed).

Usage: base_pin.py     env: BASE_IMAGE, FEDORA_VERSION, KEY (default keys/ublue-os-main-cosign.pub), GITHUB_ENV / GITHUB_STEP_SUMMARY / GITHUB_OUTPUT when set

Prints and exports BASE_PIN=sha256:<manifest digest of the tag> (the sha256 of `skopeo inspect --raw`, the way every pin here is made). Verification: the signature of BASE_IMAGE@<pin>; for a
manifest LIST whose own digest carries no signature, the linux/amd64 child it names (an index digest pins its children, so a verified child is the one this build uses). Neither verifies:
exit 1 with an error that names a rotated key as one possible cause (compare keys/ublue-os-main-cosign.pub with https://github.com/ublue-os/main/blob/main/cosign.pub). Exit 1 too when the tag
cannot be resolved.
"""
import json
import os
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ci  # noqa: E402
import registry  # noqa: E402


def main():
    image = os.environ.get("BASE_IMAGE") or sys.exit("BASE_IMAGE: parameter null or not set")
    ver = os.environ.get("FEDORA_VERSION") or sys.exit("FEDORA_VERSION: parameter null or not set")
    key = os.environ.get("KEY") or "keys/ublue-os-main-cosign.pub"
    if not re.fullmatch(r"[0-9]+", ver):
        ci.err(f"::error::FEDORA_VERSION '{ver}' is not a number")
        return 1
    base = f"{image}:{ver}"
    try:
        manifest = registry.read("raw", base)
    except registry.ReadError:
        ci.err(f"::error::cannot read {base} (a registry read error after the retries, not a missing tag): re-run; nothing was built")
        return 1
    except registry.Absent:
        manifest = b""
    manifest = manifest.rstrip(b"\n")  # the shell kept the answer in a variable, which drops trailing newlines
    if not manifest:
        ci.err(f"::error::cannot resolve {base} (does the tag exist? skopeo list-tags docker://{image})")
        return 1
    pin = registry.sha256_of(manifest)
    verified = ""
    errs = []  # what the checks printed to stderr: it is only quoted in the message, never shown as it comes
    vrc = registry.verify_code(["--key", key, f"{image}@{pin}"], sink=errs.append)
    if vrc == 0:
        verified = f"the signature of {pin}"
    else:
        child = ""
        try:
            for m in json.loads(manifest).get("manifests") or []:
                p = m.get("platform") or {}
                if p.get("os") == "linux" and p.get("architecture") == "amd64":
                    child = m.get("digest", "")
                    break
        except (ValueError, AttributeError):
            child = ""
        if re.fullmatch(r"sha256:[0-9a-f]{64}", child):
            crc = registry.verify_code(["--key", key, f"{image}@{child}"], sink=errs.append)
            if crc == 0:
                verified = f"the signature of its linux/amd64 manifest {child}"
            elif crc == 4:
                vrc = 4
    if not verified:
        log = "\n".join(errs) + "\n" if errs else ""
        tail = log.encode()[-300:].decode(errors="replace").replace("\n", " ")
        if vrc == 4:
            # the check could not be completed (network, registry): a TRANSIENT failure, not a verdict on the key
            ci.err(f"::error::the signature of {base} ({pin}) could not be checked after the retries (a read error, not a wrong key): re-run; nothing was built. {tail}")
        elif re.search("no signatures found", log, re.I) and not re.search("no matching signatures", log, re.I):
            ci.err(f"::error::no signature is visible for {base} ({pin}) yet: Universal Blue may still be publishing it (a re-run in a while usually passes); the build stops. {tail}")
        else:
            ci.err(f"::error::{base} ({pin}) is not signed by {key}: the build stops. Possible causes: Universal Blue rotated its signing key (compare {key} with "
                   f"https://github.com/ublue-os/main/blob/main/cosign.pub and replace it only after reading why), the image is unsigned, or it was replaced. {tail}")
        return 1
    print(f"BASE_PIN={pin}")
    ci.append_to("GITHUB_ENV", f"BASE_PIN={pin}")
    ci.output("pin", pin)
    ci.append_to("GITHUB_STEP_SUMMARY", f"Base image: `{base}` resolved ONCE to `{pin}` and verified ({verified}) with `{key}`; the build is FROM that digest.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
