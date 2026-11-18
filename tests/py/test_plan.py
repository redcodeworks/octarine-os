"""The scripts that decide what the pipeline builds, promotes or reuses (inputs_hash,
plan_promote, plan_vanilla_reuse, plan_dx) in real git repositories against the fake
registry.
"""

import subprocess
from pathlib import Path

import pytest

from conftest import git, script

IMAGE = "ghcr.io/redcodeworks/octarine-os"


def commit(repo, message, **files):
    """Commit the files of the `files` dict (path: text)"""
    files = {**files.pop("files", {}), **files}

    # write each file, creating its directories
    for name, text in files.items():
        path = repo / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
    git(repo, "add", "-A")
    git(repo, "commit", "-qm", message)
    return git(repo, "rev-parse", "HEAD")


def hashes(repo, rev="HEAD"):
    """Return the (vanilla, dx, gx) input hashes of a revision, as inputs_hash.py prints
    them.
    """
    # one script run per kind of hash
    return tuple(
        script("inputs_hash.py", kind, rev, cwd=repo).stdout.strip()
        for kind in ("vanilla", "dx", "gx")
    )


@pytest.fixture
def repo(tmp_path):
    """A repository on branch testing with one file in each input group (default, dx,
    gx, docs, tests, shared and pipeline-only).
    """
    r = tmp_path / "repo"
    r.mkdir()
    git(r, "init", "-q", "-b", "testing", ".")
    commit(
        r,
        "base",
        files={
            "system_files/x": "a",
            "variants/dx/f": "a",
            "variants/gx/f": "a",
            "README.md": "a",
            "docs/n.md": "a",
            "tests/t.sh": "a",
            "keys/redcodeworks-toolbox-cosign.pub": "a",
            ".github/workflows/dx-image.yml": "a",
            ".github/scripts/plan_dx.py": "a",
            ".github/workflows/test.yml": "a",
        },
    )
    return r


@pytest.mark.parametrize(
    "change, moves",
    [
        ({"README.md": "b"}, ()),  # docs: no image input
        ({"docs/n.md": "b"}, ()),
        ({"tests/t.sh": "b"}, ()),  # tests are no input of any image
        ({".github/workflows/test.yml": "b"}, ()),  # pipeline-only
        ({"system_files/x": "b"}, (0,)),  # the default image
        ({"variants/dx/f": "b"}, (1,)),  # dx only
        ({"variants/gx/f": "b"}, (2,)),  # gx only
        ({".github/workflows/dx-image.yml": "b"}, (1, 2)),  # shared by both variants
        ({".github/scripts/plan_dx.py": "b"}, (1, 2)),
    ],
)
def test_which_input_hashes_a_change_moves(repo, change, moves):
    """Which input hashes a change moves."""
    before = hashes(repo)
    commit(repo, "change", files=change)
    after = hashes(repo)
    # the indexes of the hashes that changed
    assert tuple(i for i in range(3) if before[i] != after[i]) == moves


def test_an_unknown_revision_fails(repo):
    """An unknown revision fails."""
    p = script("inputs_hash.py", "vanilla", "nope", cwd=repo)
    assert p.returncode == 1 and "unknown revision" in p.stderr


def outputs(p):
    """Parse the `key=value` lines of a script's stdout into a dict."""
    # only lines with an = carry a result
    return dict(line.split("=", 1) for line in p.stdout.splitlines() if "=" in line)


def short(repo, rev):
    """Return the 7-character short sha of a revision."""
    return git(repo, "rev-parse", "--short=7", rev)


@pytest.fixture
def merged(repo):
    """main = base; testing = base + code commit + docs-only tip; main merged testing (a
    merge commit whose second parent is the docs-only tip).
    """
    git(repo, "branch", "-m", "main")
    git(repo, "checkout", "-q", "-b", "testing")
    code = commit(repo, "code", files={"system_files/x": "b"})
    docs = commit(repo, "docs", files={"README.md": "b"})
    git(repo, "checkout", "-q", "main")
    git(repo, "merge", "-q", "--no-ff", "-m", "promote", "testing")
    return {
        "repo": repo,
        "code": code,
        "docs": docs,
        "after": git(repo, "rev-parse", "HEAD"),
    }


def promote(m, **extra):
    """Run plan_promote.py for the merge commit of the `merged` fixture.

    Extra keyword arguments add or override environment variables.
    """
    return script(
        "plan_promote.py",
        "push",
        "refs/heads/main",
        m["after"],
        cwd=m["repo"],
        extra={"PROMOTE_ENABLED": "true", "IMAGE": IMAGE, **extra},
    )


def test_a_docs_only_testing_tip_promotes_the_image_of_the_commit_behind_it(
    merged, reg
):
    """A docs only testing tip promotes the image of the commit behind it."""
    reg.put(IMAGE, f"testing-{short(merged['repo'], merged['code'])}", "tested")
    out = outputs(promote(merged))
    assert (
        out["promote"] == "true"
        and out["source_tag"] == f"testing-{short(merged['repo'], merged['code'])}"
        and out["source_digest"] == reg.tag(IMAGE, out["source_tag"])
    )


def test_no_tested_image_means_build(merged, reg):
    """No tested image means build."""
    assert outputs(promote(merged))["promote"] == "false"


def test_a_default_image_change_between_the_tip_and_the_image_means_build(merged, reg):
    """A default image change between the tip and the image means build."""
    reg.put(IMAGE, f"testing-{short(merged['repo'], merged['code'] + '~1')}", "older")
    assert outputs(promote(merged))["promote"] == "false"


def test_an_unreadable_registry_fails_the_plan_instead_of_rebuilding_untested_content(
    merged, reg
):
    """An unreadable registry fails the plan instead of rebuilding untested content."""
    p = promote(merged, REG_READ_ERROR=IMAGE)
    assert (
        p.returncode == 1
        and "cannot decide" in p.stderr
        and "promote=true" not in p.stdout
    )


@pytest.mark.parametrize("extra", [{"PROMOTE_ENABLED": "false"}])
def test_promotion_can_be_disabled(merged, reg, extra):
    """Promotion can be disabled."""
    reg.put(IMAGE, f"testing-{short(merged['repo'], merged['code'])}", "tested")
    assert outputs(promote(merged, **extra))["promote"] == "false"


def test_a_push_that_is_not_a_merge_does_not_promote(merged, reg):
    """A push that is not a merge does not promote."""
    p = script(
        "plan_promote.py",
        "push",
        "refs/heads/main",
        merged["code"],
        cwd=merged["repo"],
        extra={"PROMOTE_ENABLED": "true", "IMAGE": IMAGE},
    )
    assert outputs(p)["promote"] == "false"


def reuse(repo, after, **extra):
    """Run plan_vanilla_reuse.py for a commit on testing.

    Extra keyword arguments add or override environment variables.
    """
    return script(
        "plan_vanilla_reuse.py",
        "push",
        "refs/heads/testing",
        after,
        cwd=repo,
        extra={"IMAGE": IMAGE, **extra},
    )


def test_a_dx_only_or_docs_only_change_reuses_the_default_image_of_the_commit_behind(
    repo, reg
):
    """A dx only or docs only change reuses the default image of the commit behind."""
    code = commit(repo, "code", files={"system_files/x": "b"})
    reg.put(IMAGE, f"testing-{short(repo, code)}", "tested")
    tip = commit(repo, "docs", files={"README.md": "b"})
    out = outputs(reuse(repo, tip))
    assert (
        out["reuse"] == "true" and out["source_tag"] == f"testing-{short(repo, code)}"
    )


def test_a_default_image_change_at_the_tip_builds(repo, reg):
    """A default image change at the tip builds."""
    code = commit(repo, "code", files={"system_files/x": "b"})
    reg.put(IMAGE, f"testing-{short(repo, code)}", "tested")
    tip = commit(repo, "more code", files={"system_files/x": "c"})
    assert outputs(reuse(repo, tip))["reuse"] == "false"


def test_an_unreadable_registry_builds_instead_of_reusing(repo, reg):
    """An unreadable registry builds instead of reusing."""
    tip = commit(repo, "docs", files={"README.md": "b"})
    p = reuse(repo, tip, REG_READ_ERROR=IMAGE)
    assert (
        p.returncode == 0
        and outputs(p)["reuse"] == "false"
        and "building instead" in p.stderr
    )


def test_only_a_push_to_testing_reuses(repo, reg):
    """Only a push to testing reuses."""
    p = script(
        "plan_vanilla_reuse.py",
        "push",
        "refs/heads/main",
        "HEAD",
        cwd=repo,
        extra={"IMAGE": IMAGE},
    )
    assert outputs(p)["reuse"] == "false"


# ---- plan_dx: skip, promote or build per channel
DX = "ghcr.io/redcodeworks/octarine-os-dx"
BASE_LABEL, INPUTS_LABEL = (
    "org.opencontainers.image.base.digest",
    "io.github.redcodeworks.octarine-os.dx-inputs",
)


@pytest.fixture
def dx_world(repo, reg, tmp_path):
    """A world for plan_dx: a repository, a fake registry with a signed default image at
    latest, and the dx input hash of HEAD.
    """
    (repo / "cosign.pub").write_text("key\n")
    base = reg.put(IMAGE, "latest", "the base")
    inputs = hashes(repo)[1]
    return {
        "repo": repo,
        "reg": reg,
        "base": base,
        "inputs": inputs,
        "out": tmp_path / "plan-out",
    }


def plan_dx(w, **extra):
    """Run plan_dx.py for the world; returns the process and its step outputs as a dict.

    Extra keyword arguments add or override environment variables.
    """
    w["out"].write_text("")
    p = script(
        "plan_dx.py",
        cwd=w["repo"],
        extra={
            "CHANNEL": "latest",
            "GITHUB_REPOSITORY_OWNER": "RedCodeWorks",
            "GITHUB_OUTPUT": str(w["out"]),
            **extra,
        },
    )
    # the step outputs are key=value lines
    return p, dict(line.split("=", 1) for line in w["out"].read_text().splitlines())


def publish_dx(w, tag, base=None, inputs=None, content=None):
    """Publish a dx image tag with the two labels (base digest and inputs); returns its
    digest.

    The base and inputs default to the world's current values.
    """
    return w["reg"].put(
        DX,
        tag,
        content or f"dx {tag}",
        {BASE_LABEL: base or w["base"], INPUTS_LABEL: inputs or w["inputs"]},
    )


def test_unchanged_base_and_inputs_skip(dx_world):
    """Unchanged base and inputs skip."""
    publish_dx(dx_world, "latest")
    p, out = plan_dx(dx_world)
    assert (
        p.returncode == 0
        and (out["build"], out["promote"]) == ("false", "false")
        and out["base_digest"] == dx_world["base"]
    )


def test_a_changed_base_builds(dx_world):
    """A changed base builds."""
    publish_dx(dx_world, "latest", base="sha256:" + "e" * 64)
    assert plan_dx(dx_world)[1]["build"] == "true"


def test_nothing_published_builds(dx_world):
    """Nothing published builds."""
    assert plan_dx(dx_world)[1]["build"] == "true"


def test_force_builds_although_nothing_changed(dx_world):
    """Force builds although nothing changed."""
    publish_dx(dx_world, "latest")
    assert plan_dx(dx_world, FORCE="true")[1]["build"] == "true"


def test_a_signed_tested_image_with_the_same_labels_is_promoted(dx_world):
    """A signed tested image with the same labels is promoted."""
    publish_dx(dx_world, "latest", inputs="sha256:other")
    digest = publish_dx(dx_world, f"testing-{short(dx_world['repo'], 'HEAD')}")
    p, out = plan_dx(dx_world)
    assert (out["build"], out["promote"], out["source_digest"]) == (
        "false",
        "true",
        digest,
    )


def test_a_matching_image_whose_signature_does_not_verify_is_not_promoted(dx_world):
    """A matching image whose signature does not verify is not promoted."""
    publish_dx(dx_world, "latest", inputs="sha256:other")
    publish_dx(dx_world, f"testing-{short(dx_world['repo'], 'HEAD')}")
    p, out = plan_dx(dx_world, COSIGN_MODE="nosig")
    assert (
        p.returncode == 1
    )  # the base itself must verify first: nothing is built on an unverified base


def test_an_unreadable_published_image_never_skips(dx_world):
    """An unreadable published image never skips."""
    publish_dx(dx_world, "latest")
    p, out = plan_dx(dx_world, REG_READ_ERROR=f"{DX}:latest")
    assert out["build"] == "true"
