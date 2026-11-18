#!/usr/bin/env python3
"""Pick the akmods-nvidia image whose kernel is EXACTLY the kernel of the base image, and print its reference.

Usage: nvidia_akmods_ref.py <kernel release with arch, e.g. 7.2.15-300.fc45.x86_64> <fedora version, e.g. 45>

Prints three lines: tag=<tag>, digest=sha256:<64 hex>, ref=<image>@<digest>. Exits 1, printing why, when the kernel is malformed, does not belong to the Fedora version, or no kernel-specific
tag exists. It NEVER falls back to the moving `main-<fedora>` tag: a mismatched kernel module would not load. The kernel-specific tag has the form `main-<fedora>-<kernel release>` with or
without the architecture suffix (the form is UNVERIFIED, so both are tried). Environment: AKMODS_IMAGE (default ghcr.io/ublue-os/akmods-nvidia-lts).
"""

import os
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ci  # noqa: E402
import registry  # noqa: E402


def main(argv=None):
    ap = ci.arg_parser(__doc__)
    ap.add_argument("kernel")
    ap.add_argument("fedora")
    args = ap.parse_args(argv)
    kernel, fedora = args.kernel, args.fedora
    image = os.environ.get("AKMODS_IMAGE") or "ghcr.io/ublue-os/akmods-nvidia-lts"
    if not (m := re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+-[0-9]+\.fc([0-9]+)\.x86_64", kernel)):
        ci.log.error(f"'{kernel}' is not a kernel release like 7.2.15-300.fc45.x86_64")
        return 1
    if m[1] != fedora:
        ci.log.error(f"kernel {kernel} belongs to Fedora {m[1]}, not {fedora}")
        return 1
    tags = [f"main-{fedora}-{kernel}", f"main-{fedora}-{kernel.removesuffix('.x86_64')}"]
    for tag in tags:
        try:
            digest = registry.digest(image, tag)
        except registry.Absent, registry.ReadError:
            continue
        print(f"tag={tag}\ndigest={digest}\nref={image}@{digest}")
        return 0
    ci.log.error(f"no {image} tag for kernel {kernel} (tried: {' '.join(tags)}). The akmods image may not be built for this kernel yet, or its tag form differs; nothing is published.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
