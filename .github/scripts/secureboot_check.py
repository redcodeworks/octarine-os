#!/usr/bin/env python3
"""Secure Boot check of the kernel in a built image, the way Bluefin and Aurora do it (their `secureboot` recipe): the kernel image (vmlinuz) must verify with sbverify against Universal Blue's
kernel signing key, downloaded from the akmods repository, so a base image with an unsigned or differently signed kernel fails the build instead of failing to boot on a machine that has the
Universal Blue key (MOK) enrolled. Usage: secureboot_check.py <image>

Environment: KERNEL_FILE (a vmlinuz to check instead of extracting one from the image; tests), UBLUE_KEY_URL (where the DER key comes from; default: the akmods repository, branch main; a
file:// URL works, which is how the test stubs the download).

1. the image must hold exactly one kernel under /usr/lib/modules; its vmlinuz is copied out (podman create and cp, nothing is run),
2. the key is downloaded (curl, retried by @ci.retry; a failed download fails the check clearly) and converted from DER to PEM,
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


@ci.retry(on=(ci.NetworkError,))
def download(url, target):
    """curl the key (curl's own --retry covers only some errors; the decorator covers the rest of a transient failure of github.com)."""
    proc = ci.run(["curl", "--fail", "--silent", "--show-error", "--retry", "3", "-L", "-o", str(target), url])
    if proc.returncode != 0:
        raise ci.NetworkError(f"curl failed (exit {proc.returncode})")


def main(argv=None):
    ap = ci.arg_parser(__doc__)
    ap.add_argument("image")
    image = ap.parse_args(argv).image
    url = os.environ.get("UBLUE_KEY_URL") or "https://github.com/ublue-os/akmods/raw/main/certs/public_key.der"
    cid = ""
    with tempfile.TemporaryDirectory() as tmp:
        work = Path(tmp)
        try:
            if os.environ.get("KERNEL_FILE"):
                kernel, kver = os.environ["KERNEL_FILE"], "test"
            else:
                p = ci.run(["podman", "create", image, "/nonexistent"], capture=True)
                if p.returncode != 0:
                    sys.stderr.buffer.write(p.stderr)
                    return p.returncode
                cid = p.stdout.decode().strip()
                p = ci.run(["podman", "run", "--rm", "--entrypoint", "ls", image, "/usr/lib/modules"], capture=True)
                kvers = p.stdout.decode().strip()
                if p.returncode != 0:
                    sys.stderr.buffer.write(p.stderr)
                    return p.returncode
                if len(kvers.split()) != 1:
                    ci.log.error(f"{image} holds not exactly one kernel under /usr/lib/modules: {kvers}")
                    return 1
                kver = kvers
                kernel = str(work / "vmlinuz")
                rc = ci.run(["podman", "cp", f"{cid}:/usr/lib/modules/{kver}/vmlinuz", kernel]).returncode
                if rc != 0:
                    return rc

            der, crt = work / "kernel-sign.der", work / "kernel-sign.crt"
            try:
                download(url, der)
            except ci.NetworkError:
                pass
            if not der.is_file() or der.stat().st_size == 0:
                ci.log.error(f"could not download the Universal Blue kernel signing key from {url}: the Secure Boot check cannot run (a network or upstream problem, not necessarily the kernel)")
                return 1
            if ci.run(["openssl", "x509", "-inform", "DER", "-in", str(der), "-out", str(crt)], stderr=DEVNULL).returncode != 0:
                ci.log.error(f"the file downloaded from {url} is not a DER certificate")
                return 1
            p = ci.run(["openssl", "x509", "-in", str(crt), "-noout", "-fingerprint", "-sha256"], capture=True)
            fp = p.stdout.decode().strip() if p.returncode == 0 else "fingerprint unreadable"
            print(f"== signing key: {url}", flush=True)
            ci.run(["openssl", "x509", "-in", str(crt), "-noout", "-subject", "-enddate"], stderr=DEVNULL)
            print(fp, flush=True)

            print(f"== kernel {kver} of {image}: sbverify --list", flush=True)
            ci.run(["sbverify", "--list", kernel])
            if ci.run(["sbverify", "--cert", str(crt), kernel]).returncode == 0:
                print(f"Secure Boot: the kernel {kver} of {image} verifies against the Universal Blue kernel key ({fp})")
                return 0
            ci.log.error(
                f"Secureboot Signature Failed: the kernel {kver} of {image} does NOT verify against the Universal Blue kernel key ({fp}); it would not boot on a machine with that key "
                "enrolled (the signatures it does carry are listed above)"
            )
            return 1
        finally:
            if cid:
                ci.run(["podman", "rm", cid], stdout=DEVNULL, stderr=DEVNULL)


if __name__ == "__main__":
    sys.exit(main())
