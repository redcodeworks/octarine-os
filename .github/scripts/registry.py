"""Every registry and signature call of the pipeline (skopeo, cosign, podman push), each network call under `@ci.retry`, so "could not be read" is never taken for "is not there".

Typed answers: `Absent` = skopeo said explicitly that the tag or repository does not exist; `NotVerified` = cosign said explicitly the signature is missing or invalid. Both are
definitive, so they are NOT in a retry's `on` list and surface at once. `ReadError` = anything else (network, TLS, 5xx, rate limit): retried, and re-raised after the last try.
`ci.NetworkError` is the same for the write calls (copy, push, sign). Callers decide what each means: a missing candidate may mean "build instead", an unreadable registry must
never silently mean that.
"""
import hashlib
import json
import re
import subprocess
import tempfile
from pathlib import Path

import ci


class Absent(Exception):
    pass


class ReadError(Exception):
    pass


class NotVerified(Exception):
    pass


ABSENT = re.compile(r"manifest unknown|name unknown|MANIFEST_UNKNOWN|NAME_UNKNOWN|not found|\b404\b|no such manifest", re.I)
# What cosign says when the signature itself is missing or wrong. A missing IMAGE or TAG ("image tag not found", MANIFEST_UNKNOWN) is NOT here: right after a write the registry
# may not show it yet (read-after-write lag seen on GHCR), so that is a read error, retried.
UNSIGNED = re.compile(r"no signatures found|no matching signatures|invalid signature|signature verification failed|none of the expected identities", re.I)


def inspect_once(mode, ref, linux_amd64=False):
    """ONE `skopeo inspect --raw|--config` of an image reference without docker://; returns the bytes. No retry (read() adds it)."""
    flag = {"raw": "--raw", "config": "--config"}[mode]
    platform = ["--override-os", "linux", "--override-arch", "amd64"] if linux_amd64 else []
    proc = ci.run(["skopeo", "inspect", *platform, flag, f"docker://{ref}"], capture=True)
    if proc.returncode == 0 and proc.stdout:
        return proc.stdout
    err = ci.stderr_of(proc)
    if ABSENT.search(err):
        raise Absent(f"{ref} does not exist ({ci.text(err, 500)})")
    raise ReadError(f"could not read {ref} (a read error, NOT a missing image): {ci.text(err)}")


@ci.retry(on=(ReadError,))
def read(mode, ref, linux_amd64=False):
    """`skopeo inspect` with the retries: raw manifest or image config bytes; raises Absent at once, ReadError after the last try."""
    return inspect_once(mode, ref, linux_amd64)


def digest(image, tag):
    """The manifest digest of image:tag: the sha256 of the raw manifest bytes, so it is the same for every tag that points at the same content."""
    return "sha256:" + hashlib.sha256(read("raw", f"{image}:{tag}")).hexdigest()


def settled(image, tag, want):
    """Read a tag back after a write until it shows the expected digest: the registry may answer right after a push or copy with the PREVIOUS manifest of the tag (seen on GHCR
    2026-11-14), or fail the read for a moment. Reads READBACK_TRIES (6) times, READBACK_WAIT (5) seconds apart; raises ReadError naming what it saw (digest, absent, unreadable)."""
    @ci.retry(attempts=ci.int_env("READBACK_TRIES", 6), delay=ci.int_env("READBACK_WAIT", 5), backoff=False, on=(ReadError,))
    def read_back():
        try:
            got = "sha256:" + hashlib.sha256(inspect_once("raw", f"{image}:{tag}")).hexdigest()
        except Absent:
            got = "absent"
        except ReadError:
            got = "unreadable"
        if got != want:
            raise ReadError(f"{image}:{tag} is {got}, expected {want}")

    read_back()


@ci.retry(on=(ReadError,), attempts=5)
def cosign_check(args):
    """`cosign verify <args>`: returns when verified, raises NotVerified at once (cosign said the signature is missing or wrong) or ReadError after the retries (it could not
    complete, or the image or tag is not visible yet: 5 tries, 5 to 20 s apart)."""
    proc = ci.run(["cosign", "verify", *args], capture=True)
    if proc.returncode == 0:
        return
    err = ci.stderr_of(proc)
    if UNSIGNED.search(err):
        raise NotVerified(f"not verified: {ci.text(err)}")
    raise ReadError(f"could not complete the verification (a read error, NOT a bad signature): {ci.text(err)}")


def write(cmd, quiet=False):
    """One network command that changes something; its stdout passes through (`quiet`: is discarded), a failure raises NetworkError. The decorated calls below are the only users."""
    proc = ci.run(cmd, stdout=subprocess.DEVNULL if quiet else None, stderr=subprocess.PIPE)
    if proc.returncode != 0:
        raise ci.NetworkError(f"{' '.join(cmd[:2])} failed (exit {proc.returncode}): {ci.text(ci.stderr_of(proc), 200)}")


@ci.retry(on=(ci.NetworkError,))
def copy(source, target):
    """Registry-side copy of a digest to a tag (same digest, same signature): `skopeo copy --all --preserve-digests`."""
    write(["skopeo", "copy", "--all", "--preserve-digests", f"docker://{source}", f"docker://{target}"])


@ci.retry(on=(ci.NetworkError,))
def push(local_image, target):
    """`podman push` of a local image; returns the manifest digest podman reports (a push is idempotent for the same content)."""
    with tempfile.TemporaryDirectory() as tmp:
        digestfile = Path(tmp) / "digest"
        write(["podman", "push", f"--digestfile={digestfile}", local_image, target])
        value = digestfile.read_text().strip() if digestfile.exists() else ""
    if not re.fullmatch(r"sha256:[0-9a-f]{64}", value):
        raise ci.NetworkError(f"podman push gave no digest for {target} ('{value}')")
    return value


@ci.retry(on=(ci.NetworkError,))
def pull(reference):
    """`podman pull`, quietly (its output would end up in the stdout of a script that prints a reference)."""
    write(["podman", "pull", reference], quiet=True)


@ci.retry(on=(ci.NetworkError,), attempts=5)
def sign(reference):
    """`cosign sign` of image@digest with the key in COSIGN_PRIVATE_KEY, in the old bundle format (https://github.com/containers/container-libs/issues/388)."""
    write(["cosign", "sign", "-y", "--new-bundle-format=false", "--use-signing-config=false", "--key", "env://COSIGN_PRIVATE_KEY", reference])


@ci.retry(on=(ReadError, NotVerified), attempts=5)
def cosign_check_fresh(args):
    """`cosign verify` of something written seconds ago (a signature just made, a tag just copied): the registry may not show it yet, so "no signatures found" is retried too
    (5 tries, 5 to 20 s apart) before it counts as NotVerified. A wrong signature fails the same way, only later."""
    return cosign_check.__wrapped__(args)


def labels(config: bytes) -> dict:
    """The labels of an image config JSON (an image without labels gives an empty dict)."""
    return (json.loads(config).get("config") or {}).get("Labels") or {}


def sha256_of(raw: bytes) -> str:
    return "sha256:" + hashlib.sha256(raw).hexdigest()
