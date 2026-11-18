#!/usr/bin/env python3
"""Secure Boot check of the kernel in a built image, the way Bluefin and Aurora do it (their `secureboot` recipe): the kernel image (vmlinuz) must verify with sbverify against Universal Blue's
kernel signing key, downloaded from the akmods repository, so a base image with an unsigned or differently signed kernel fails the build instead of failing to boot on a machine that has the
Universal Blue key (MOK) enrolled. Usage: secureboot_check.py <image>

Environment: KERNEL_FILE (a vmlinuz to check instead of extracting one from the image; tests), UBLUE_KEY_URL (where the DER key comes from; default: the akmods repository, branch main; a
file:// URL works, which is how the test stubs the download).

1. the image must hold exactly one kernel under /usr/lib/modules; its vmlinuz is copied out (podman create and cp, nothing is run),
2. the key is downloaded (curl, retried by ci.retry_command; a failed download fails the check clearly) and converted from DER to PEM,
3. `sbverify --list` is printed for diagnosis (a base kernel normally carries two signatures: Fedora's kernel-signer and Universal Blue's "ublue kernel"),
4. `sbverify --cert <key>` decides: exit 0 verified; exit 1 otherwise ("Secureboot Signature Failed"). The Fedora signature is NOT checked.
Trust: the key is fetched live from the main branch of github.com/ublue-os/akmods on every run (see docs/signing-keys.md). Tools: podman (unless KERNEL_FILE), sbverify (sbsigntool/sbsigntools), curl, openssl.
"""
import os
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ci  # noqa: E402

DEVNULL = subprocess.DEVNULL


def main(argv):
    if len(argv) != 1:
        print("usage: secureboot_check.py <image>", file=sys.stderr)
        return 1
    image = argv[0]
    url = os.environ.get("UBLUE_KEY_URL") or "https://github.com/ublue-os/akmods/raw/main/certs/public_key.der"
    cid = ""
    with tempfile.TemporaryDirectory() as tmp:
        work = Path(tmp)
        try:
            if os.environ.get("KERNEL_FILE"):
                kernel, kver = os.environ["KERNEL_FILE"], "test"
            else:
                p = ci.capture(["podman", "create", image, "/nonexistent"])
                if p.returncode != 0:
                    sys.stderr.buffer.write(p.stderr)
                    return p.returncode
                cid = p.stdout.decode().strip()
                p = ci.capture(["podman", "run", "--rm", "--entrypoint", "ls", image, "/usr/lib/modules"])
                kvers = p.stdout.decode().strip()
                if p.returncode != 0:
                    sys.stderr.buffer.write(p.stderr)
                    return p.returncode
                if len(kvers.split()) != 1:
                    print(f"::error::{image} holds not exactly one kernel under /usr/lib/modules: {kvers}", file=sys.stderr)
                    return 1
                kver = kvers
                kernel = str(work / "vmlinuz")
                rc = ci.run(["podman", "cp", f"{cid}:/usr/lib/modules/{kver}/vmlinuz", kernel]).returncode
                if rc != 0:
                    return rc

            der, crt = work / "kernel-sign.der", work / "kernel-sign.crt"
            got = ci.retry_command(["curl", "--fail", "--silent", "--show-error", "--retry", "3", "-L", "-o", str(der), url]) == 0  # curl's own --retry covers only some errors; retry covers the rest
            if not got or not der.is_file() or der.stat().st_size == 0:
                print(f"::error::could not download the Universal Blue kernel signing key from {url}: the Secure Boot check cannot run (a network or upstream problem, not necessarily the kernel)", file=sys.stderr)
                return 1
            if ci.run(["openssl", "x509", "-inform", "DER", "-in", str(der), "-out", str(crt)], stderr=DEVNULL).returncode != 0:
                print(f"::error::the file downloaded from {url} is not a DER certificate", file=sys.stderr)
                return 1
            p = ci.capture(["openssl", "x509", "-in", str(crt), "-noout", "-fingerprint", "-sha256"])
            fp = p.stdout.decode().strip() if p.returncode == 0 else "fingerprint unreadable"
            print(f"== signing key: {url}", flush=True)
            ci.run(["openssl", "x509", "-in", str(crt), "-noout", "-subject", "-enddate"], stderr=DEVNULL)
            print(fp, flush=True)

            print(f"== kernel {kver} of {image}: sbverify --list", flush=True)
            ci.run(["sbverify", "--list", kernel])
            if ci.run(["sbverify", "--cert", str(crt), kernel]).returncode == 0:
                print(f"Secure Boot: the kernel {kver} of {image} verifies against the Universal Blue kernel key ({fp})")
                return 0
            print(f"::error::Secureboot Signature Failed: the kernel {kver} of {image} does NOT verify against the Universal Blue kernel key ({fp}); it would not boot on a machine with that key "
                  "enrolled (the signatures it does carry are listed above)", file=sys.stderr)
            return 1
        finally:
            if cid:
                ci.run(["podman", "rm", cid], stdout=DEVNULL, stderr=DEVNULL)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
