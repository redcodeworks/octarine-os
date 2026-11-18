"""The readers that keep "could not read" apart from "is not there" (registry.py and the
scripts around it), with fake skopeo and cosign.
"""

import hashlib

import pytest

import ci
import registry
from conftest import script


def calls(fakes):
    """Return how many times the fake skopeo or cosign was called (the COUNT file)."""
    return int(open(fakes["COUNT"]).read())


def test_absent_is_not_retried(fakes, monkeypatch):
    """A missing tag is a definitive answer: one call, no retry."""
    monkeypatch.setenv("MODE", "absent")

    # the registry says the tag does not exist
    with pytest.raises(registry.Absent):
        registry.read("raw", "ghcr.io/o/i:t")
    assert calls(fakes) == 1


def test_transient_failures_are_retried(fakes, monkeypatch):
    """A flaky registry is retried until it answers (three calls)."""
    monkeypatch.setenv("MODE", "flaky")
    open(fakes["STATE"] + "/t", "w").write('{"manifest":1}')
    assert registry.read("raw", "ghcr.io/o/i:t") == b'{"manifest":1}'
    assert calls(fakes) == 3


@pytest.mark.parametrize("mode", ["down", "empty"])
def test_a_registry_that_stays_down_is_a_read_error_never_absent(
    fakes, monkeypatch, mode
):
    """A registry that stays down is a read error after three tries, never "absent"."""
    monkeypatch.setenv("MODE", mode)

    # a read error, not an absent tag
    with pytest.raises(registry.ReadError):
        registry.read("raw", "ghcr.io/o/i:t")
    assert calls(fakes) == 3


def test_digest_is_the_sha256_of_the_manifest_bytes(fakes):
    """The digest is the sha256 of the raw manifest bytes."""
    (open(fakes["STATE"] + "/testing", "w")).write("some manifest")
    assert (
        registry.digest("ghcr.io/o/i", "testing")
        == "sha256:" + hashlib.sha256(b"some manifest").hexdigest()
    )


def test_cosign_not_verified_is_definitive_and_not_retried(fakes, monkeypatch):
    """A missing or wrong signature is a verdict: one call, no retry."""
    monkeypatch.setenv("COSIGN_MODE", "nosig")

    # cosign said the signature is missing
    with pytest.raises(registry.NotVerified):
        registry.cosign_check(["--key", "k", "ghcr.io/o/i@sha256:x"])
    assert calls(fakes) == 1


def test_cosign_that_cannot_complete_is_a_read_error_after_five_tries(
    fakes, monkeypatch
):
    """A cosign that cannot complete is a read error after five tries, not a bad
    signature.
    """
    monkeypatch.setenv("COSIGN_MODE", "down")

    # five tries, then a read error that says it is not a bad signature
    with pytest.raises(
        registry.ReadError, match="NOT a bad signature.*failed 5 attempts"
    ):
        registry.cosign_check(["--key", "k", "x"])
    assert calls(fakes) == 5


def test_cosign_flaky_then_verified(fakes, monkeypatch):
    """A flaky cosign that verifies on a later try passes."""
    monkeypatch.setenv("COSIGN_MODE", "flaky")
    registry.cosign_check(["--key", "k", "x"])


def test_settled_fails_naming_unreadable_when_the_registry_stays_down(
    fakes, monkeypatch
):
    """settled names the tag as unreadable when the registry stays down."""
    monkeypatch.setenv("MODE", "down")

    # the message says the read failed rather than naming a digest
    with pytest.raises(registry.ReadError, match="is unreadable"):
        registry.settled("ghcr.io/o/i", "t", "sha256:" + "a" * 64)


def test_settled_passes_when_the_tag_shows_the_digest(fakes):
    """settled returns when the tag already shows the digest."""
    (open(fakes["STATE"] + "/t", "w")).write("m")
    registry.settled("ghcr.io/o/i", "t", "sha256:" + hashlib.sha256(b"m").hexdigest())


def test_a_failing_copy_is_retried_and_then_raised(fakes, monkeypatch):
    """A failing copy is retried and then raised with the attempt count.

    The write helper is replaced by one that always fails.
    """
    monkeypatch.setenv("MODE", "down")
    # every attempt of the copy fails
    monkeypatch.setattr(
        registry,
        "write",
        lambda cmd: (_ for _ in ()).throw(ci.NetworkError("copy failed")),
    )

    # three attempts, then the error with the count
    with pytest.raises(ci.NetworkError, match="failed 3 attempts"):
        registry.copy("a@sha256:x", "a:testing")


def test_a_tag_that_cosign_cannot_see_yet_is_a_read_error_never_not_verified(
    fakes, monkeypatch
):
    """The real failure of the dx sign job: right after the copy, cosign said 'image tag
    not found ... MANIFEST_UNKNOWN' (registry lag). That is not a signature verdict.
    """
    monkeypatch.setenv("LAG_FILE", fakes["LOG"] + ".lag")
    monkeypatch.setenv("COSIGN_LAG", "99")

    # cosign says the tag is not found yet (registry lag): a read error with its message
    with pytest.raises(registry.ReadError, match="MANIFEST_UNKNOWN"):
        registry.cosign_check(["--key", "k", "ghcr.io/o/i:testing"])
    assert int(open(fakes["LOG"] + ".lag").read()) == 5


def test_a_signature_written_a_moment_ago_may_take_a_few_tries_but_a_wrong_one_still_fails(
    fakes, monkeypatch
):
    """A signature written a moment ago may take a few tries, but a wrong one still
    fails.
    """
    monkeypatch.setenv("LAG_FILE", fakes["LOG"] + ".lag")
    monkeypatch.setenv("COSIGN_UNSIGNED_FIRST", "2")
    registry.cosign_check_fresh(
        ["--key", "k", "x"]
    )  # no signatures found twice, then verified
    monkeypatch.setenv("COSIGN_MODE", "nosig")

    # a signature that is wrong stays a verdict even under the fresh check
    with pytest.raises(registry.NotVerified):
        registry.cosign_check_fresh(["--key", "k", "x"])
