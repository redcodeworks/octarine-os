#!/usr/bin/env python3
"""Pick the akmods-nvidia image whose kernel is EXACTLY the kernel of the base image, and print its reference.

Usage: nvidia_akmods_ref.py <kernel release with arch, e.g. 7.2.15-300.fc45.x86_64> <fedora version, e.g. 45>

Prints three lines: tag=<tag>, digest=sha256:<64 hex>, ref=<image>@<digest>. Exits 1, printing why, when the kernel is malformed, does not belong to the Fedora version, or no kernel-specific
tag exists. It NEVER falls back to the moving `main-<fedora>` tag: a mismatched kernel module would not load. The kernel-specific tag has the form `main-<fedora>-<kernel release>` with or
without the architecture suffix (the form is UNVERIFIED, so both are tried). Environment: AKMODS_IMAGE (default ghcr.io/ublue-os/akmods-nvidia-lts), SKOPEO (default skopeo; tests use a stub).
"""
import os
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ci  # noqa: E402
import registry  # noqa: E402


def fail(msg):
    print(f"ERROR: {msg}", file=sys.stderr)
    return 1


def main(argv):
    if len(argv) != 2:
        print("usage: nvidia_akmods_ref.py <kernel release> <fedora version>", file=sys.stderr)
        return 1
    kernel, fedora = argv
    image = os.environ.get("AKMODS_IMAGE") or "ghcr.io/ublue-os/akmods-nvidia-lts"
    skopeo = os.environ.get("SKOPEO") or "skopeo"
    m = re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+-[0-9]+\.fc([0-9]+)\.x86_64", kernel)
    if not m:
        return fail(f"'{kernel}' is not a kernel release like 7.2.15-300.fc45.x86_64")
    if m[1] != fedora:
        return fail(f"kernel {kernel} belongs to Fedora {m[1]}, not {fedora}")
    tried = []
    for tag in (f"main-{fedora}-{kernel}", f"main-{fedora}-{kernel.removesuffix('.x86_64')}"):
        tried.append(tag)
        p = ci.capture([skopeo, "inspect", "--raw", f"docker://{image}:{tag}"])
        raw = p.stdout.rstrip(b"\n")  # the shell kept the answer in a variable, which drops trailing newlines
        if p.returncode != 0 or not raw:
            continue
        digest = registry.sha256_of(raw)
        print(f"tag={tag}")
        print(f"digest={digest}")
        print(f"ref={image}@{digest}")
        return 0
    return fail(f"no {image} tag for kernel {kernel} (tried: {' '.join(tried)}). The akmods image may not be built for this kernel yet, or its tag form differs; nothing is published.")


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
