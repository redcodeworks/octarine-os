"""The scripts that move tags, pin the base, verify refs, file issues and open bump pull requests, run as real subprocesses against the fake registry, fake cosign/podman/sbverify and the fake GitHub API."""

import json
import os
import subprocess
import sys

import pytest

from conftest import FAKES, SCRIPTS, fixture, git, make_repo, pull, script

D = "sha256:" + "a" * 64


# ---- retry.py
def test_retry_gives_the_last_exit_status_after_the_tries(fakes, tmp_path):
    p = script("retry.py", "-n", "3", "-d", "0", "--", sys.executable, "-c", "import sys; sys.exit(7)")
    assert p.returncode == 7 and "failed (exit 7)" in p.stderr


def test_retry_runs_until_a_try_succeeds(fakes, tmp_path):
    marker = tmp_path / "n"
    code = f"import pathlib, sys; f = pathlib.Path({str(marker)!r}); n = int(f.read_text() or 0) + 1 if f.exists() else 1; f.write_text(str(n)); sys.exit(0 if n >= 3 else 1)"
    p = script("retry.py", "-d", "0", sys.executable, "-c", code)
    assert p.returncode == 0 and marker.read_text() == "3"


# ---- registry_read, registry_digest, cosign_check: the exit contract the workflow steps read
@pytest.mark.parametrize("mode, code", [("ok", 0), ("absent", 3), ("down", 4), ("empty", 4)])
def test_registry_read_exit_contract(fakes, mode, code):
    open(fakes["STATE"] + "/t", "w").write('{"manifest":1}')
    assert script("registry_read.py", "raw", "ghcr.io/o/i:t", extra={"MODE": mode}).returncode == code


@pytest.mark.parametrize("mode, code", [("ok", 0), ("nosig", 5), ("badsig", 5), ("down", 4)])
def test_cosign_check_exit_contract(fakes, mode, code):
    assert script("cosign_check.py", "--key", "k", "ghcr.io/o/i@sha256:x", extra={"COSIGN_MODE": mode}).returncode == code


def test_registry_digest_prints_the_digest_of_the_tag(reg):
    d = reg.put("ghcr.io/o/i", "t", "manifest")
    p = script("registry_digest.py", "ghcr.io/o/i", "t")
    assert p.returncode == 0 and p.stdout.strip() == d
    assert script("registry_digest.py", "ghcr.io/o/i", "missing").returncode == 3


# ---- move_tags
def test_move_tags_ends_every_tag_on_the_signed_digest(reg):
    image = "ghcr.io/o/i"
    d = reg.put(image, "testing-20261116", "signed")
    reg.put(image, "testing", "old")
    p = script("move_tags.py", image, d, "testing", "testing-x")
    assert p.returncode == 0 and reg.tag(image, "testing") == d == reg.tag(image, "testing-x")


def test_move_tags_fails_and_leaves_the_tag_when_the_copy_fails(reg):
    old = reg.put("ghcr.io/o/i", "testing", "old")
    p = script("move_tags.py", "ghcr.io/o/i", D, "testing")  # D is no manifest of the registry: the copy fails
    assert p.returncode == 1 and reg.tag("ghcr.io/o/i", "testing") == old


def test_move_tags_without_tags_does_nothing_and_a_bad_digest_is_refused(reg):
    assert script("move_tags.py", "ghcr.io/o/i", D).returncode == 0
    assert script("move_tags.py", "ghcr.io/o/i", "nope", "testing").returncode == 1


# ---- base_pin
BASE = "ghcr.io/ublue-os/silverblue-main"


@pytest.fixture
def pin(reg, tmp_path):
    reg.put(BASE, "45", '{"schemaVersion":2,"layers":[]}')
    (tmp_path / "key.pub").write_text("key\n")

    def run(**extra):
        for name in ("env", "sum"):
            (tmp_path / name).write_text("")
        return script(
            "base_pin.py",
            extra={"BASE_IMAGE": BASE, "FEDORA_VERSION": "45", "KEY": str(tmp_path / "key.pub"), "GITHUB_ENV": str(tmp_path / "env"), "GITHUB_STEP_SUMMARY": str(tmp_path / "sum"), **extra},
        )

    run.reg, run.tmp = reg, tmp_path
    return run


def test_a_signed_base_is_pinned_once_and_exported(pin):
    p = pin()
    digest = pin.reg.tag(BASE, "45")
    assert p.returncode == 0 and f"BASE_PIN={digest}" in p.stdout and (pin.tmp / "env").read_text().strip() == f"BASE_PIN={digest}" and "resolved ONCE" in (pin.tmp / "sum").read_text()


@pytest.mark.parametrize("mode, message", [("badsig", "is not signed by"), ("nosig", "no signature is visible"), ("down", "could not be checked")])
def test_an_unverified_base_fails_the_build_and_exports_nothing(pin, mode, message):
    p = pin(COSIGN_MODE=mode)
    assert p.returncode == 1 and message in p.stderr and (pin.tmp / "env").read_text() == ""


def test_an_unreadable_registry_is_a_read_error_not_a_missing_tag(pin):
    p = pin(REG_READ_ERROR=BASE)
    assert p.returncode == 1 and "registry read error" in p.stderr and "cannot resolve" not in p.stderr


# ---- chunkah_ref
@pytest.fixture
def chunkah(tmp_path, fakes):
    env = tmp_path / "chunkah.env"
    env.write_text(f"CHUNKAH_IMAGE=quay.io/coreos/chunkah\nCHUNKAH_TAG=latest\nCHUNKAH_DIGEST={D}\n")
    return env


def test_chunkah_ref_verifies_keyless_and_prints_the_pinned_reference(chunkah, fakes):
    p = script("chunkah_ref.py", str(chunkah))
    assert p.returncode == 0 and p.stdout.strip() == f"quay.io/coreos/chunkah@{D}"
    log = open(fakes["LOG"]).read()
    assert "--certificate-oidc-issuer https://token.actions.githubusercontent.com" in log and "podman pull" in log


def test_chunkah_ref_refuses_an_unverified_image_without_pulling_it(chunkah, fakes):
    p = script("chunkah_ref.py", str(chunkah), extra={"COSIGN_MODE": "badsig"})
    assert p.returncode == 1 and "not trusted" in p.stderr and "podman" not in open(fakes["LOG"]).read()


def test_chunkah_ref_refuses_a_floating_pin_before_cosign_runs(tmp_path, fakes):
    bad = tmp_path / "bad.env"
    bad.write_text("CHUNKAH_IMAGE=quay.io/coreos/chunkah\nCHUNKAH_DIGEST=latest\n")
    p = script("chunkah_ref.py", str(bad))
    assert p.returncode == 1 and not os.path.exists(fakes["LOG"])


def test_chunkah_ref_fails_on_a_missing_file(tmp_path, fakes):
    assert script("chunkah_ref.py", str(tmp_path / "missing.env")).returncode == 1


# ---- nvidia_akmods_ref
AKMODS = "ghcr.io/ublue-os/akmods-nvidia-lts"


@pytest.mark.parametrize("kernel, tag", [("7.2.15-300.fc45.x86_64", "main-45-7.2.15-300.fc45.x86_64"), ("7.2.15-300.fc45.x86_64", "main-45-7.2.15-300.fc45")])
def test_the_akmods_image_of_exactly_this_kernel_is_picked_in_either_tag_form(reg, kernel, tag):
    d = reg.put(AKMODS, tag, f"akmods {tag}")
    p = script("nvidia_akmods_ref.py", kernel, "45")
    assert p.returncode == 0 and p.stdout.splitlines() == [f"tag={tag}", f"digest={d}", f"ref={AKMODS}@{d}"]


def test_no_kernel_specific_tag_never_falls_back_to_the_moving_tag(reg):
    reg.put(AKMODS, "main-45", "moving")
    assert script("nvidia_akmods_ref.py", "7.2.15-300.fc45.x86_64", "45").returncode == 1


@pytest.mark.parametrize("kernel, fedora", [("7.2.15", "45"), ("7.2.15-300.fc44.x86_64", "45")])
def test_a_malformed_kernel_or_one_of_another_fedora_is_refused(reg, kernel, fedora):
    assert script("nvidia_akmods_ref.py", kernel, fedora).returncode == 1


# ---- ci_issue (fake GitHub API)
ENV = {
    "SHA": "0123456789abcdef0123456789abcdef01234567",
    "RUN_URL": "https://example/run/9",
    "NOW": "2026-11-14",
    "NEEDS_JSON": '{"plan":{"result":"success"},"build":{"result":"failure"},"sign":{"result":"skipped"}}',
}


def test_the_first_failure_opens_one_issue_with_the_label_and_the_failed_job(github, fakes):
    p = script("ci_issue.py", "fail", extra=ENV)
    assert p.returncode == 0 and len(github.opened) == 1 and github.labels == ["ci-failure-dx"] and not github.comments
    issue = github.opened[0]
    assert issue["labels"] == ["ci-failure-dx"] and issue["title"] == "dx/latest not published: latest 0123456" and "Failed job(s): build" in issue["body"] and "https://example/run/9" in issue["body"]


def test_a_failure_with_an_open_issue_comments_and_opens_no_second_one(github, fakes):
    github.issues = [fixture("issue", number=41)]
    p = script("ci_issue.py", "fail", extra=ENV)
    assert p.returncode == 0 and not github.opened and github.comments[0][0].endswith("/issues/41/comments") and "Failed again (2026-11-14): https://example/run/9" in github.comments[0][1]


def test_a_recovery_comments_and_closes_the_issue(github, fakes):
    github.issues = [fixture("issue", number=41)]
    assert script("ci_issue.py", "recover", extra=ENV).returncode == 0
    assert "recovered: https://example/run/9" in github.comments[0][1] and github.updates[0][0].endswith("/issues/41") and github.updates[0][1] == {"state": "closed"}


def test_a_recovery_without_an_open_issue_does_nothing(github, fakes):
    p = script("ci_issue.py", "recover", extra=ENV)
    assert p.returncode == 0 and not github.comments and not github.updates and "nothing to close" in p.stdout


# ---- secureboot_check
@pytest.fixture
def secureboot(tmp_path, fakes):
    key = tmp_path / "key.der"
    subprocess.run(
        ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-subj", "/O=Test/CN=ublue kernel", "-days", "2", "-outform", "DER", "-out", str(key), "-keyout", str(tmp_path / "k")],
        check=True,
        capture_output=True,
    )
    (tmp_path / "junk.der").write_text("junk\n")
    (tmp_path / "vmlinuz").write_text("kernel\n")

    def run(url="key.der", **extra):
        return script("secureboot_check.py", "img:test", extra={"KERNEL_FILE": str(tmp_path / "vmlinuz"), "UBLUE_KEY_URL": f"file://{tmp_path / url}", **extra})

    run.log = fakes["LOG"]
    return run


def test_a_kernel_that_verifies_against_the_downloaded_key_passes(secureboot):
    p = secureboot()
    log = open(secureboot.log).read()
    assert p.returncode == 0 and "verifies against the Universal Blue" in p.stdout and "Fingerprint=" in p.stdout and "sbverify --list" in log and log.count("sbverify --cert") == 1


def test_a_kernel_that_does_not_verify_fails_the_build_and_lists_the_signatures(secureboot):
    p = secureboot(SB_FAIL="1")
    assert p.returncode == 1 and "Secureboot Signature Failed" in p.stderr and "kernel-signer" in p.stdout


@pytest.mark.parametrize("url, message", [("missing.der", "could not download"), ("junk.der", "not a DER certificate")])
def test_a_bad_key_download_fails_clearly_without_running_the_verification(secureboot, url, message):
    p = secureboot(url)
    assert p.returncode == 1 and message in p.stderr and "sbverify --cert" not in (open(secureboot.log).read() if os.path.exists(secureboot.log) else "")


# ---- prune_daily
def versions(n):
    def dg(k):
        return format(k, "064x")

    out = []
    for k in range(1, n + 1):
        d = f"202601{min(k, 28):02d}"
        out.append(
            {
                "id": 100 + k,
                "name": "sha256:" + dg(k),
                "created_at": f"2026-01-{min(k, 28):02d}T{k % 24:02d}:00:00Z",
                "metadata": {"container": {"tags": [f"daily-{d}", f"latest-{d}-abcdef{k % 10}", d]}},
            }
        )
    return out


def prune(vs, **env):
    return subprocess.run([sys.executable, "-I", str(SCRIPTS / "prune_daily.py")], input=json.dumps(vs), capture_output=True, text=True, env={**os.environ, **env})


def test_prune_keeps_the_newest_fourteen_daily_builds():
    p = prune(versions(20))
    assert p.returncode == 0 and p.stdout.count("DELETE image") == 6 and "Dry run: 6 versions would be deleted." in p.stdout


def test_prune_never_deletes_a_protected_digest_or_a_version_with_another_tag():
    vs = versions(20)
    vs[0]["metadata"]["container"]["tags"].append("latest")
    p = prune(vs, PROTECT=vs[1]["name"])
    assert p.stdout.count("DELETE image") == 4


def test_prune_refuses_more_deletions_than_the_limit():
    p = prune(versions(60))
    assert p.returncode != 0 and "Refusing to delete" in p.stderr


def test_prune_with_dry_run_off_deletes_through_the_api(github):
    p = prune(versions(16), DRY_RUN="false", API_BASE="users/o/packages/container/i", GITHUB_API_URL=github.url, GITHUB_TOKEN="t")
    assert p.returncode == 0 and [r for r in github.requests if r[0] == "DELETE"] == [
        ("DELETE", "/users/o/packages/container/i/versions/102"),
        ("DELETE", "/users/o/packages/container/i/versions/101"),
    ]
