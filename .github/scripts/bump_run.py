#!/usr/bin/env python3
"""The weekly bump check of ONE pin: decide (the decision scripts of its kind) and, when something is newer, write the pin into the working tree and make ONE commit for it (its message ends with
the row of the pull request's table: pin | from | to | what changed upstream | days the new value has existed). Usage: bump_run.py chunkah|brew|bins

bump_weekly.py runs every pin one after the other, each on its own branch cut from testing, and opens one independent pull request per pin. Exits non-zero when the pin's check FAILED (a registry that
cannot be reached, a signature that does not verify, a bad pin); the working tree is restored then. Prints one line per pin (also into the job summary). Run from the repository root on a clean checkout,
with GH_TOKEN set, a git identity, and skopeo, cosign and just for the kinds that use them.

Kinds: the image digest pin of chunkah (bump_pin.py), the Homebrew files image (the `just brew-bump` recipe is the pin writer, so its cosign verification runs on every write) and the octarine-bins
image (`just bins-bump` is the pin writer: it resolves octarine-bins:latest, verifies the digest with keys/octarine-bins.pub and writes it; the scx, extest, Ghostty and builder pins live in the
octarine-bins repository).
"""

import json
import os
import re
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ci  # noqa: E402
import registry  # noqa: E402

HERE = Path(__file__).resolve().parent


class Fail(Exception):
    """The pin's check failed: `str(e)` is the status line."""


def say(line):
    ci.log.info(line)
    ci.append_to("GITHUB_STEP_SUMMARY", f"- {line}")


def days(iso: str) -> str:
    """An ISO date -> whole days since then, or "unknown"."""
    try:
        return str((int(time.time()) - ci.epoch(iso)) // 86400)
    except ValueError, TypeError:
        return "unknown"


def image_age(ref: str) -> str:
    """Days since the linux/amd64 image of `ref` was created, or "unknown"."""
    try:
        return days(json.loads(registry.read("config", ref, linux_amd64=True)).get("created") or "")
    except registry.Absent, registry.ReadError, ValueError, AttributeError:
        return days("")


def containerfile_arg(name: str) -> str:
    m = re.search(rf"^ARG {name}=(.*)$", Path("Containerfile").read_text(), re.M)
    return m[1] if m else ""


def just(*args) -> bool:
    return ci.run(["just", *args]).returncode == 0


class Pin:
    def __init__(self, name):
        self.name = name
        self.current = self.proposed = "-"
        self.status = "nothing to bump"
        self.files = []

    def fail(self, msg):
        ci.log.error(f"{self.name}: {msg}")
        self.status = msg
        raise Fail(msg)

    def commit_pin(self, subject, upstream, age):
        """The pin was written; check that only its files changed, commit them."""
        changed = ci.git("diff", "--name-only").split()
        if not changed:
            self.fail(f"the writer changed nothing for {self.proposed}")
        for f in changed:
            if f not in self.files:
                self.fail(f"the writer changed {f}, which is not one of the pin files ({' '.join(self.files)})")
        ci.git("commit", "-q", "-a", "-m", f"{subject}\n\n{self.name} | {self.current} | {self.proposed} | {upstream} | {age}")
        self.status = f"moved {self.current} to {self.proposed}"

    def chunkah(self):
        self.files = ["config/chunkah.env"]
        ref = "quay.io/coreos/chunkah:latest"
        src = f"{ref}, keyless cosign signature verified"
        with tempfile.TemporaryDirectory() as d:
            go = Path(d) / "out"
            go.touch()
            rc = subprocess.run([sys.executable, "-I", str(HERE / "bump_pin.py"), self.name], env={**os.environ, "GITHUB_OUTPUT": str(go)}).returncode
            lines = go.read_text().splitlines()

        def read_out(key):
            vals = [ln.split("=", 1)[1] for ln in lines if ln.startswith(f"{key}=")]
            return vals[-1] if vals else ""

        result, old, new, tag = read_out("result"), read_out("previous"), read_out("digest"), read_out("tag")
        self.current = old[:19]
        if rc not in (0, 10):
            self.fail(f"the check failed ({result or f'exit {rc}'})")
        if result == "equal":
            self.status = "nothing to bump: the pin equals latest"
        else:
            self.proposed = f"{tag} {new[:19]}"
            self.commit_pin(f"Bump the {self.name} pin to latest ({tag})", src, image_age(ref))

    def brew(self):
        self.current = containerfile_arg("BREW_TAG")
        try:
            tags = json.loads(ci.run(["skopeo", "list-tags", "docker://ghcr.io/ublue-os/brew"], capture=True).stdout)["Tags"]
            latest = sorted(t for t in tags if re.fullmatch(r"\d{8}", t))[-1]
        except ValueError, KeyError, TypeError, IndexError:
            latest = ""
        if not re.fullmatch(r"[0-9]{8}", latest):
            self.fail("cannot list the tags of ghcr.io/ublue-os/brew")
        if latest <= self.current:
            self.status = f"nothing to bump: the pinned {self.current} is the newest (or newer than the newest) dated tag {latest}"
            return
        self.files = ["Containerfile"]
        self.proposed = latest
        if not just("brew-bump", latest):
            self.fail(f"just brew-bump {latest} failed (digest or signature; nothing changed)")
        self.commit_pin(f"Bump the Homebrew files image to {latest}", f"ghcr.io/ublue-os/brew:{latest}, cosign signature verified", image_age(f"ghcr.io/ublue-os/brew:{latest}"))

    def bins(self):
        self.files = ["Containerfile"]
        cur, curtag = containerfile_arg("BINS_DIGEST"), containerfile_arg("BINS_TAG")
        if not re.fullmatch(r"sha256:[0-9a-f]{64}", cur):
            self.fail("BINS_DIGEST in the Containerfile is missing or malformed")
        self.current = f"{curtag} {cur[:19]}"
        ref = "ghcr.io/redcodeworks/octarine-bins"
        try:
            latest = registry.digest(ref, "latest")
        except registry.Absent, registry.ReadError:
            self.fail(f"cannot resolve {ref}:latest")
        if latest == cur:
            self.status = f"nothing to bump: the pin equals {ref}:latest ({curtag})"
            return
        if not just("bins-bump", "latest"):
            self.fail("just bins-bump failed (digest, signature or version label; nothing changed)")
        self.proposed = f"{containerfile_arg('BINS_TAG')} {containerfile_arg('BINS_DIGEST')[:19]}"
        self.commit_pin(
            f"Bump the octarine-bins image to {self.proposed.split(' ')[0]}",
            f"a new octarine-bins digest, {ref}:latest verified with keys/octarine-bins.pub; its testing build is the first OS build with these binaries",
            image_age(f"{ref}:latest"),
        )


def main(argv=None):
    ap = ci.arg_parser(__doc__)
    ap.add_argument("pin", help="chunkah, brew or bins")
    pin = Pin(ap.parse_args(argv).pin)
    try:
        if subprocess.run(["git", "diff", "--quiet"]).returncode != 0:
            pin.fail("the working tree is not clean")
        kinds = {"chunkah": pin.chunkah, "brew": pin.brew, "bins": pin.bins}
        if pin.name not in kinds:
            pin.fail(f"unknown pin '{pin.name}'")
        kinds[pin.name]()
    except Fail:
        ci.run(["git", "checkout", "-q", "--", "."], stderr=subprocess.DEVNULL)
        say(f"`{pin.name}`: FAILED, {pin.status}")
        return 1
    say(f"`{pin.name}`: {pin.status}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
