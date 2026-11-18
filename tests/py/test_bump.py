"""The weekly pin bump: bump_pin (decision table of the chunkah pin) and bump_weekly
(one independent pull request per pin) with real git (a bare origin and a clone), the
fake GitHub API and stub bump_run/bump_checks.
"""

import os
import shutil
import subprocess

import pytest

from conftest import SCRIPTS, git, script

CHUNKAH = "quay.io/coreos/chunkah"
OLD = "sha256:" + "1" * 64


@pytest.fixture
def pin_file(tmp_path, reg):
    """A pin file for the chunkah pin with an old digest.

    Returns the path of the file.
    """
    f = tmp_path / "chunkah.env"
    f.write_text(
        f"# the pin\nCHUNKAH_IMAGE={CHUNKAH}\nCHUNKAH_TAG=latest-old\nCHUNKAH_DIGEST={OLD}\n"
    )
    return f


def bump_pin(f, **extra):
    """Run bump_pin.py on a pin file and return the process and the outputs it wrote.

    Receives the pin file and extra environment variables; the outputs come from the
    GITHUB_OUTPUT file as a dict.
    """
    out = f.parent / "out"
    out.write_text("")
    p = script(
        "bump_pin.py",
        "chunkah",
        extra={"CHUNKAH_ENV": str(f), "GITHUB_OUTPUT": str(out), **extra},
    )
    # the GITHUB_OUTPUT file holds key=value lines
    return p, dict(line.split("=", 1) for line in out.read_text().splitlines())


def test_a_pin_that_equals_latest_is_left_alone(pin_file, reg):
    """A pin that already equals latest is left alone: result equal, file unchanged."""
    digest = reg.put(CHUNKAH, "latest", "m1")
    pin_file.write_text(pin_file.read_text().replace(OLD, digest))
    before = pin_file.read_text()
    p, out = bump_pin(pin_file)
    assert (
        p.returncode == 0
        and out["result"] == "equal"
        and pin_file.read_text() == before
    )


def test_a_newer_signed_latest_rewrites_only_the_pin_lines_with_the_dated_tag(
    pin_file, reg
):
    """A newer signed latest rewrites only the pin lines, labeling it with the dated
    tag.
    """
    digest = reg.put(CHUNKAH, "latest", "m2")
    # the dated tag of the same digest is the label
    reg.put(CHUNKAH, "latest-20261112-abcdef2", "m2")
    reg.put(CHUNKAH, "latest-20261110-abcdef1", "m1")
    p, out = bump_pin(pin_file)
    assert (
        p.returncode == 10 and out["result"] == "different" and out["digest"] == digest
    )
    assert (
        pin_file.read_text()
        == f"# the pin\nCHUNKAH_IMAGE={CHUNKAH}\nCHUNKAH_TAG=latest-20261112-abcdef2\nCHUNKAH_DIGEST={digest}\n"
    )


def test_a_signature_that_does_not_verify_leaves_the_file_untouched(pin_file, reg):
    """A signature that does not verify leaves the file untouched and exits 2."""
    reg.put(CHUNKAH, "latest", "m2")
    before = pin_file.read_text()
    p, out = bump_pin(pin_file, COSIGN_MODE="badsig")
    assert (
        p.returncode == 2
        and out["result"] == "badsignature"
        and pin_file.read_text() == before
    )


def test_an_unresolvable_latest_is_unreachable(pin_file, reg):
    """A latest that cannot be resolved is reported as unreachable with exit 1."""
    p, out = bump_pin(pin_file)
    assert p.returncode == 1 and out["result"] == "unreachable"


def test_a_malformed_pin_is_badpin(pin_file, reg):
    """A malformed pin is reported as badpin with exit 3."""
    pin_file.write_text("CHUNKAH_DIGEST=latest\n")
    p, out = bump_pin(pin_file)
    assert p.returncode == 3 and out["result"] == "badpin"


# ---- bump_weekly
STUB_RUN = """import os, re, subprocess, sys
pin = sys.argv[1]
new = os.environ.get("UPSTREAM_" + pin.upper(), "")
if new == "fail":
    print(f"::error::{pin}: cannot read upstream")
    sys.exit(1)
text = open("pins.txt").read()
cur = re.search(rf"^{pin}=(.*)$", text, re.M).group(1)
if new == cur:
    print(f"{pin}: nothing to bump")
    sys.exit(0)
open("pins.txt", "w").write(re.sub(rf"^{pin}=.*$", f"{pin}={new}", text, flags=re.M))
subprocess.run(["git", "commit", "-q", "-a", "-m", f"Bump {pin} to {new}\\n\\n{pin} | {cur} | {new} | upstream | 3"], check=True)
"""
STUB_CHECKS = 'import os, sys\nopen(os.environ["DB"] + "/checks", "a").write(" ".join(sys.argv[1:]) + "\\n")\n'


@pytest.fixture
def clone(tmp_path, github, monkeypatch):
    """A bare origin with testing (pins.txt and the stub scripts) and a clone of it on
    testing.
    """
    origin, work = tmp_path / "origin.git", tmp_path / "clone"

    # git identity for the commits the stub scripts make
    for key, value in {
        "GIT_AUTHOR_NAME": "t",
        "GIT_AUTHOR_EMAIL": "t@t",
        "GIT_COMMITTER_NAME": "t",
        "GIT_COMMITTER_EMAIL": "t@t",
    }.items():
        monkeypatch.setenv(key, value)
    subprocess.run(
        ["git", "init", "-q", "--bare", "-b", "testing", str(origin)], check=True
    )
    subprocess.run(
        ["git", "clone", "-q", str(origin), str(work)], check=True, capture_output=True
    )
    git(work, "checkout", "-q", "-b", "testing")
    scripts = work / ".github" / "scripts"
    scripts.mkdir(parents=True)

    # the real bump_weekly.py and ci.py, with stubs for the scripts it starts
    for name in ("bump_weekly.py", "ci.py"):
        shutil.copy(SCRIPTS / name, scripts)
    (scripts / "bump_run.py").write_text(STUB_RUN)
    (scripts / "bump_checks.py").write_text(STUB_CHECKS)
    (work / "pins.txt").write_text("chunkah=1\nbrew=1\nbins=1\n")
    git(work, "add", "-A")
    git(work, "commit", "-qm", "init")
    git(work, "push", "-q", "origin", "testing")
    db = tmp_path / "db"
    db.mkdir()

    class Clone:
        """The clone and its origin, with helpers to run the script and list branches."""

        path, origin_path, api = work, origin, github
        checks = db / "checks"

        def run(self, **env):
            """Run bump_weekly.py in the clone with the stub environment; returns the
            process.

            Extra keyword arguments add or override environment variables.
            """
            return subprocess.run(
                [os.sys.executable, "-I", ".github/scripts/bump_weekly.py"],
                cwd=work,
                capture_output=True,
                text=True,
                env={
                    **os.environ,
                    "DB": str(db),
                    "BUMP_PINS": "chunkah brew bins",
                    "BUMP_CHECKS_WAIT": "0",
                    "GITHUB_REPOSITORY": "o/r",
                    **env,
                },
            )

        def branches(self):
            """Return the sorted names of the bump branches on the origin."""
            out = git(
                origin, "for-each-ref", "--format=%(refname:short)", "refs/heads/bump/*"
            )
            return sorted(out.split())

    return Clone()


def test_a_pin_that_moved_gets_its_own_branch_commit_and_pull_request(clone):
    """A pin that moved gets its own branch, commit, pull request and check report."""
    p = clone.run(UPSTREAM_CHUNKAH="2", UPSTREAM_BREW="1", UPSTREAM_BINS="2")
    assert p.returncode == 0, p.stderr
    # the heads of the pull requests that were opened
    heads = [head for head, _ in clone.api.created]
    # none for the pin that did not move
    assert (
        len(heads) == 2
        and heads[0].startswith("bump/chunkah-")
        and heads[1].startswith("bump/bins-")
    )
    assert len(clone.checks.read_text().splitlines()) == 2

    # cut from testing: one commit, one changed pin line, no chain
    for branch in clone.branches():
        assert (
            git(clone.origin_path, "rev-list", "--count", f"testing..{branch}") == "1"
        )
        assert (
            git(clone.origin_path, "diff", "--numstat", "testing", branch).count("\n")
            == 0
        )
    # one title is exactly the expected bump title and none is too long
    assert any(
        title == "Bump chunkah: 1 to 2" for _, title in clone.api.created
    ) and all(len(title) <= 140 for _, title in clone.api.created)


def test_a_rerun_with_the_same_values_opens_nothing_and_closes_nothing(clone):
    """A rerun with the same values opens nothing and closes nothing."""
    clone.run(UPSTREAM_CHUNKAH="2", UPSTREAM_BREW="1", UPSTREAM_BINS="2")
    p = clone.run(UPSTREAM_CHUNKAH="2", UPSTREAM_BREW="1", UPSTREAM_BINS="2")
    assert p.returncode == 0 and len(clone.api.created) == 2 and clone.api.closed == []


def test_upstream_moving_again_opens_a_new_pull_request_and_closes_the_older_one(clone):
    """Upstream moving again opens a new pull request and closes the older one."""
    clone.run(UPSTREAM_CHUNKAH="2", UPSTREAM_BREW="1", UPSTREAM_BINS="2")
    p = clone.run(UPSTREAM_CHUNKAH="3", UPSTREAM_BREW="1", UPSTREAM_BINS="2")
    assert (
        p.returncode == 0 and len(clone.api.created) == 3 and len(clone.api.closed) == 1
    )
    # the heads of the pull requests that are open now
    open_heads = [pr["head"]["ref"] for pr in clone.api.prs]
    # exactly one open pull request per pin that moved
    assert (
        sum(h.startswith("bump/chunkah-") for h in open_heads) == 1
        and sum(h.startswith("bump/bins-") for h in open_heads) == 1
    )


def test_a_pin_that_testing_already_has_closes_its_stale_pull_request(clone):
    """A pin that testing already has closes its stale pull request."""
    clone.run(UPSTREAM_CHUNKAH="2", UPSTREAM_BREW="1", UPSTREAM_BINS="2")
    git(clone.path, "checkout", "-q", "testing")
    (clone.path / "pins.txt").write_text("chunkah=1\nbrew=1\nbins=2\n")
    git(clone.path, "commit", "-qam", "merged bins")
    git(clone.path, "push", "-q", "origin", "testing")
    p = clone.run(UPSTREAM_CHUNKAH="2", UPSTREAM_BREW="1", UPSTREAM_BINS="2")
    assert (
        p.returncode == 0 and len(clone.api.closed) == 1 and len(clone.api.created) == 2
    )
    # no pull request for the bins pin stays open
    assert not [
        pr for pr in clone.api.prs if pr["head"]["ref"].startswith("bump/bins-")
    ]


def test_a_failing_pin_turns_the_run_red_and_the_other_pins_still_get_their_pull_requests(
    clone,
):
    """A failing pin turns the run red while the other pins still get their pull
    requests.
    """
    p = clone.run(UPSTREAM_CHUNKAH="fail", UPSTREAM_BREW="2", UPSTREAM_BINS="2")
    # only the two pins that worked have pull requests
    assert (
        p.returncode != 0
        and len(clone.api.created) == 2
        and not any(head.startswith("bump/chunkah-") for head, _ in clone.api.created)
    )


def test_a_dry_run_pushes_and_creates_nothing(clone):
    """A dry run pushes nothing and creates nothing, but says what it would open."""
    p = clone.run(
        DRY_RUN="1", UPSTREAM_CHUNKAH="2", UPSTREAM_BREW="2", UPSTREAM_BINS="1"
    )
    assert (
        p.returncode == 0
        and p.stderr.count("would open") == 2
        and not clone.api.created
        and clone.branches() == []
    )


def test_a_real_run_from_a_checkout_that_is_not_origin_testing_is_refused(clone):
    """A real run from a checkout that is not origin/testing is refused."""
    git(clone.path, "commit", "-q", "--allow-empty", "-m", "local")
    p = clone.run(UPSTREAM_CHUNKAH="2")
    assert (
        p.returncode != 0
        and "must start from origin/testing" in p.stderr
        and not clone.api.created
    )
