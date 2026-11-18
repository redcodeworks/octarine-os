"""Reading a registry and verifying signatures so that "could not read" is never mistaken for "is not there" (the one reader of the pipeline's decisions: what is published, what to
promote, what to skip). Library of registry_read.py, registry_digest.py, registry_settled.py and cosign_check.py, and imported by the plan, push and publish scripts.

The contract (the exit status of those four scripts, and the exception `.code` here): 3 ABSENT (skopeo said explicitly that the tag or repository does not exist; never retried),
4 READ ERROR (anything else: network, TLS, 5xx, rate limit, a timeout; retried, still failing after the last try), 5 NOT VERIFIED (cosign said so explicitly; never retried).
Callers decide: a missing candidate may mean "build instead", an unreadable registry must never silently mean that.
Environment (read when called, so a test can shorten them): RETRY_TRIES (3), RETRY_DELAY (5, the pause before try k+1 is DELAY*k), READBACK_TRIES (6), READBACK_WAIT (5).
"""
import hashlib
import json
import re
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ci  # noqa: E402

ABSENT_RE = re.compile(r"manifest unknown|name unknown|MANIFEST_UNKNOWN|NAME_UNKNOWN|not found|\b404\b|no such manifest", re.I)
NOT_VERIFIED_RE = re.compile(r"no signatures found|no matching signatures|invalid signature|signature verification failed|MANIFEST_UNKNOWN|NAME_UNKNOWN|manifest unknown|not found"
                             r"|none of the expected identities", re.I)


class RegistryError(Exception):
    code = 4


class Absent(RegistryError):
    code = 3


class ReadError(RegistryError):
    code = 4


class NotVerified(RegistryError):
    code = 5


def read(mode: str, ref: str, quiet: bool = False, tries: int | None = None) -> bytes:
    """The raw manifest (mode raw: skopeo inspect --raw) or the image config JSON (mode config) of `ref` (no docker:// prefix). Raises Absent or ReadError."""
    flag = {"raw": "--raw", "config": "--config"}[mode]
    tries = ci.int_env("RETRY_TRIES", 3) if tries is None else tries
    delay = ci.int_env("RETRY_DELAY", 5)
    say = (lambda m: None) if quiet else ci.err
    last = b""
    for i in range(1, tries + 1):
        p = ci.capture(["skopeo", "inspect", flag, f"docker://{ref}"])
        last = p.stderr
        if p.returncode == 0 and p.stdout:
            return p.stdout
        if ABSENT_RE.search(p.stderr.decode(errors="replace")):
            say(f"registry-read: {ref} does not exist ({ci.snippet(p.stderr, 200)})")
            raise Absent(f"{ref} does not exist")
        if i < tries:
            say(f"::warning::registry read of {ref} failed (try {i}/{tries}): {ci.snippet(p.stderr, 200)}; retrying in {delay * i} s")
            time.sleep(delay * i)
    say(f"::error::registry-read: could not read {ref} after {tries} tries (a read error, NOT a missing image): {ci.snippet(last, 300)}")
    raise ReadError(f"could not read {ref}")


def manifest_digest(raw: bytes) -> str:
    """The digest of manifest bytes, as `skopeo manifest-digest` computes it (sha256 of the bytes), asked of skopeo itself."""
    with tempfile.TemporaryDirectory() as d:
        f = Path(d) / "manifest"
        f.write_bytes(raw)
        p = ci.capture(["skopeo", "manifest-digest", str(f)])
    if p.returncode != 0:
        raise ReadError("skopeo manifest-digest failed")
    return p.stdout.decode().strip()


def sha256_of(raw: bytes) -> str:
    return "sha256:" + hashlib.sha256(raw).hexdigest()


def digest(image: str, tag: str, quiet: bool = False, tries: int | None = None) -> str:
    """The manifest digest of <image>:<tag> (image is registry/owner/name): the same for every tag that points at the same content. Raises Absent or ReadError."""
    return manifest_digest(read("raw", f"{image}:{tag}", quiet=quiet, tries=tries))


def settled(image: str, tag: str, want: str) -> None:
    """Read a tag back after a write until it shows the expected digest: the registry may answer a read right after a push or a copy with the PREVIOUS manifest of the tag (seen
    on GHCR 2026-11-14), or fail the read for a moment. Returns when one read shows it; otherwise prints `::error::` with the last answer (the digest, absent or unreadable) and exits 1."""
    tries = ci.int_env("READBACK_TRIES", 6)
    wait = ci.int_env("READBACK_WAIT", 5)
    got = ""
    for i in range(1, tries + 1):
        try:
            got = digest(image, tag, quiet=True, tries=1)
        except Absent:
            got = "absent"
        except RegistryError:
            got = "unreadable"
        if got == want:
            return
        if i != tries:
            time.sleep(wait)
    ci.err(f"::error::{image}:{tag} is {got}, expected {want} (after {tries} reads)")
    raise SystemExit(1)


def verify(args, sink=ci.err) -> None:
    """`cosign verify <args>` with the verdict told apart; the stdout of cosign is discarded. Returns when verified; raises NotVerified (cosign said so; no retry) or ReadError
    (anything else, retried). `sink` receives the messages (stderr by default)."""
    tries = ci.int_env("RETRY_TRIES", 3)
    delay = ci.int_env("RETRY_DELAY", 5)
    last = b""
    for i in range(1, tries + 1):
        p = ci.capture(["cosign", "verify", *args])
        if p.returncode == 0:
            return
        last = p.stderr
        if NOT_VERIFIED_RE.search(last.decode(errors="replace")):
            sink(f"cosign-check: not verified: {ci.snippet(last, 300)}")
            raise NotVerified("not verified")
        if i < tries:
            sink(f"::warning::cosign verify failed (try {i}/{tries}): {ci.snippet(last, 200)}; retrying in {delay * i} s")
            time.sleep(delay * i)
    sink(f"::error::cosign-check: could not complete the verification after {tries} tries (a read error, NOT a bad signature): {ci.snippet(last, 300)}")
    raise ReadError("could not verify")


def verify_code(args, sink=ci.err) -> int:
    """verify() as the exit status of cosign_check.py: 0 verified, 5 not verified, 4 could not be checked."""
    try:
        verify(args, sink)
    except RegistryError as e:
        return e.code
    return 0


def labels(config: bytes) -> dict:
    """The labels of an image config JSON (an image without labels gives an empty dict)."""
    return (json.loads(config).get("config") or {}).get("Labels") or {}
