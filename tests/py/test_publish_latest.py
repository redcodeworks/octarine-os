"""publish_latest.py (the one step that moves the `latest` of ONE image) against a fake
registry (fakes/skopeo with REG), fake cosign and a throwaway git repository that plays
main.
"""

import pytest

from conftest import git, make_repo, script

OWNER = "redcodeworks"
IMG = f"ghcr.io/{OWNER}/octarine-os"
DX = f"ghcr.io/{OWNER}/octarine-os-dx"


@pytest.fixture
def world(tmp_path, reg, monkeypatch):
    """main has c1 c2 c3; a side branch has a commit that is not on main. Returns a
    namespace-like dict.
    """
    repo = tmp_path / "repo"
    c1, c2, c3 = make_repo(repo, "c1", "c2", "c3")
    git(repo, "checkout", "-q", "-b", "side")
    (repo / "f").write_text("side\n")
    git(repo, "commit", "-qam", "side")
    side = git(repo, "rev-parse", "HEAD")
    git(repo, "checkout", "-q", "main")
    git(repo, "update-ref", "refs/remotes/origin/main", "main")
    (repo / "cosign.pub").write_text("key\n")
    return {
        "repo": repo,
        "c1": c1,
        "c2": c2,
        "c3": c3,
        "side": side,
        "reg": reg,
        "out": tmp_path / "out",
        "sum": tmp_path / "sum",
    }


def image(world, name, tag, rev, created, base=None, *tags):
    """Publish an image with labels (and extra tags with the same content) into the fake
    registry.

    Receives the world, the image name, the tag, the revision label, the created
    label and optionally a base digest. Returns the digest.
    """
    labels = {
        "org.opencontainers.image.revision": rev,
        "org.opencontainers.image.created": created,
        **({"org.opencontainers.image.base.digest": base} if base else {}),
    }
    digest = world["reg"].put(name, tag, f"{name} {tag} {rev} {created}", labels)

    # the extra tags point at the same content
    for t in tags:
        world["reg"].put(name, t, f"{name} {tag} {rev} {created}", labels)
    return digest


def publish(world, fakes, **env):
    """Run publish_latest.py in the world's repository with the usual environment.

    Extra keyword arguments override environment variables; returns the
    CompletedProcess.
    """
    world["out"].write_text("")
    base = {
        "OWNER": "RedCodeWorks",
        "MAIN_REF": "refs/remotes/origin/main",
        "WRITE": "true",
        "GITHUB_OUTPUT": str(world["out"]),
        "GITHUB_STEP_SUMMARY": str(world["sum"]),
    }
    return script("publish_latest.py", cwd=world["repo"], extra={**base, **env})


def moved(world):
    """Whether the run wrote `moved=true` to the step output."""
    return "moved=true" in world["out"].read_text()


def test_a_newer_signed_image_from_main_moves_latest(world, fakes):
    """A newer signed image built from main becomes latest."""
    old = image(
        world, IMG, "latest-old", world["c1"], "2026-11-10T00:00:00Z", None, "latest"
    )
    new = image(world, IMG, "latest-new", world["c3"], "2026-11-13T00:00:00Z")
    p = publish(world, fakes, IMAGE="default", DIGEST=new)
    assert p.returncode == 0, p.stderr
    assert world["reg"].tag(IMG, "latest") == new != old and moved(world)


def test_a_latest_that_already_has_the_digest_is_left_alone(world, fakes):
    """When latest already has the candidate's digest nothing is moved."""
    cur = image(
        world, IMG, "latest-x", world["c3"], "2026-11-13T00:00:00Z", None, "latest"
    )
    p = publish(world, fakes, IMAGE="default", DIGEST=cur)
    assert p.returncode == 0 and not moved(world)


def test_an_older_candidate_is_held_not_failed(world, fakes):
    """An older candidate than the current latest is held with exit 0, not failed."""
    cur = image(
        world, IMG, "latest-new", world["c3"], "2026-11-13T00:00:00Z", None, "latest"
    )
    old = image(world, IMG, "latest-old", world["c1"], "2026-11-10T00:00:00Z")
    p = publish(world, fakes, IMAGE="default", DIGEST=old)
    assert (
        p.returncode == 0
        and world["reg"].tag(IMG, "latest") == cur
        and not moved(world)
        and "latest held" in p.stderr
    )


def test_a_rollback_may_put_an_older_verified_image_under_latest(world, fakes):
    """With ALLOW_BACKWARDS an older verified image may be put under latest."""
    image(world, IMG, "latest-new", world["c3"], "2026-11-13T00:00:00Z", None, "latest")
    old = image(world, IMG, "latest-old", world["c1"], "2026-11-10T00:00:00Z")
    p = publish(world, fakes, IMAGE="default", DIGEST=old, ALLOW_BACKWARDS="true")
    assert p.returncode == 0 and world["reg"].tag(IMG, "latest") == old and moved(world)


def test_an_image_not_built_from_main_is_refused(world, fakes):
    """An image whose revision is not on main is refused."""
    cur = image(
        world, IMG, "latest-cur", world["c1"], "2026-11-10T00:00:00Z", None, "latest"
    )
    bad = image(world, IMG, "latest-bad", world["side"], "2026-11-14T00:00:00Z")
    p = publish(world, fakes, IMAGE="default", DIGEST=bad)
    assert (
        p.returncode == 1
        and world["reg"].tag(IMG, "latest") == cur
        and "not on" in p.stderr
    )


def test_an_unsigned_image_is_refused(world, fakes):
    """An unsigned candidate is refused."""
    cur = image(
        world, IMG, "latest-cur", world["c1"], "2026-11-10T00:00:00Z", None, "latest"
    )
    new = image(world, IMG, "latest-new", world["c3"], "2026-11-13T00:00:00Z")
    p = publish(world, fakes, IMAGE="default", DIGEST=new, COSIGN_MODE="nosig")
    assert p.returncode == 1 and world["reg"].tag(IMG, "latest") == cur


def test_a_dry_run_moves_nothing(world, fakes):
    """A dry run reports the plan and moves nothing."""
    cur = image(
        world, IMG, "latest-cur", world["c1"], "2026-11-10T00:00:00Z", None, "latest"
    )
    new = image(world, IMG, "latest-new", world["c3"], "2026-11-13T00:00:00Z")
    p = publish(world, fakes, IMAGE="default", DIGEST=new, DRY_RUN="true")
    assert (
        p.returncode == 0
        and world["reg"].tag(IMG, "latest") == cur
        and "DRY RUN" in p.stderr
    )


def test_an_unreadable_latest_fails_the_run_instead_of_moving_unguarded(world, fakes):
    """A latest that cannot be read fails the run instead of moving latest unguarded."""
    new = image(world, IMG, "latest-new", world["c3"], "2026-11-13T00:00:00Z")
    image(world, IMG, "latest-cur", world["c1"], "2026-11-10T00:00:00Z", None, "latest")
    p = publish(
        world, fakes, IMAGE="default", DIGEST=new, REG_READ_ERROR=f"{IMG}:latest"
    )
    assert p.returncode == 1 and "read error" in p.stderr and not moved(world)


def test_a_variant_moves_its_own_latest_when_its_base_is_a_signed_image_from_main(
    world, fakes
):
    """A variant moves its own latest when its base is signed and built from main."""
    base = image(world, IMG, "latest-base", world["c3"], "2026-11-13T00:00:00Z")
    old = image(
        world, DX, "latest-old", world["c1"], "2026-11-10T00:00:00Z", None, "latest"
    )
    new = image(
        world, DX, "latest-20261113-abc1234", world["c3"], "2026-11-13T01:00:00Z", base
    )
    p = publish(world, fakes, IMAGE="dx", TAG="latest-20261113-abc1234")
    assert p.returncode == 0, p.stderr
    assert (
        world["reg"].tag(DX, "latest") == new != old
        and world["reg"].tag(IMG, "latest") is None
    )  # only dx moved


@pytest.mark.parametrize("tag", ["testing-abc1234", "latest", "foo"])
def test_a_tag_that_is_not_a_dated_tag_is_refused(world, fakes, tag):
    """A tag that is not a dated tag is refused."""
    p = publish(world, fakes, IMAGE="dx", TAG=tag)
    assert p.returncode == 1 and "not a dated tag" in p.stderr
