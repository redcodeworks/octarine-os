"""Registry-facing pipeline scripts: push-tags, prune-testing, the three pin bumps and the upstream check.

Registries and GitHub are stubs (podman, skopeo, cosign, gh). Assertions are on exit codes, file contents and the
list of stub calls, never on output wording.
"""
from __future__ import annotations

import hashlib
import json
import re
import shutil
import subprocess
from pathlib import Path

import pytest

from conftest import REPO, SCRIPTS
from helpers.stubs import GhTable

# =====================================================================================================================
# push-tags: one push, every other tag a digest copy
# =====================================================================================================================

PODMAN_BODY = r"""
[[ "$1" == push ]] || exit 1
for a in "$@"; do case "$a" in --digestfile=*) df="${a#--digestfile=}" ;; esac; done
tag="${@: -1}"; tag="${tag##*:}"
n=$(( $(cat "$STUB_DIR/n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$STUB_DIR/n"
printf 'manifest-%s-%s' "$tag" "$n" > "${REG}/${tag}"
echo "sha256:$(sha256sum < "${REG}/${tag}" | sed 's/ .*//')" > "${df}"
"""
SKOPEO_BODY = r"""
case "$1 $2" in
    "inspect --raw") tag="${3##*:}"; [[ -f "${REG}/${tag}" ]] && cat "${REG}/${tag}" || exit 1 ;;
    "copy --all")
        [[ "$3" == --preserve-digests ]] || exit 1
        src="${4#docker://}"; dst="${5#docker://}"; want="${src##*@}"
        for f in "${REG}"/*; do
            [[ "sha256:$(sha256sum < "${f}" | sed 's/ .*//')" == "${want}" ]] || continue
            if [[ "${BREAK_COPY:-}" == 1 ]]; then echo other > "${REG}/${dst##*:}"; else cp "${f}" "${REG}/${dst##*:}"; fi
            exit 0
        done
        exit 1 ;;
    *) exit 1 ;;
esac
"""


class PushTags:
    def __init__(self, sandbox, stubs):
        self.sbx = sandbox
        self.reg = sandbox.tmp / "reg"
        self.reg.mkdir()
        self.out = sandbox.tmp / "gh-output"
        self.out.write_text("")
        self.podman = stubs.add("podman", script=PODMAN_BODY)
        self.skopeo = stubs.add("skopeo", script=SKOPEO_BODY)

    def run(self, *args, **env):
        return self.sbx.bash(SCRIPTS / "push-tags.sh", "local:build", "ghcr.io/o/img", *args,
                             env={"REG": str(self.reg), "GITHUB_OUTPUT": str(self.out), **env})

    def digest(self, tag):
        return "sha256:" + hashlib.sha256((self.reg / tag).read_bytes()).hexdigest()

    def pushes(self):
        return [c for c in self.podman.calls if c[1] == "push"]

    def copies(self):
        return [c for c in self.skopeo.calls if c[1] == "copy"]


@pytest.fixture
def pt(sandbox, stubs):
    return PushTags(sandbox, stubs)


@pytest.mark.parametrize("tags", [["testing-abc1234", "testing"],
                                  ["latest-1", "latest-20261110-abc1234", "20261110-abc1234", "20261110", "latest", "latest-20261110"],
                                  ["only"]], ids=["two tags", "six tags", "one tag"])
def test_push_tags_one_push_one_digest(pt, tags):
    """One podman push; every other tag is a registry-side copy of the pushed digest, so all tags share one
    manifest digest and the output is that single digest.

    OLD: push-tags: two tags: succeeds
    OLD: push-tags: exactly one podman push
    OLD: push-tags: every tag has the same manifest digest
    OLD: push-tags: the second tag is a digest copy of the pushed digest
    OLD: push-tags: the output is the single digest, which the sign job signs
    OLD: push-tags: six tags: one push, five copies
    OLD: push-tags: six tags share one digest
    OLD: push-tags: one tag: a push and no copy
    """
    r = pt.run(*tags)
    assert r.rc == 0, r.err
    assert len(pt.pushes()) == 1
    digests = {pt.digest(t) for t in tags}
    assert len(digests) == 1
    (digest,) = digests
    assert len(pt.copies()) == len(tags) - 1
    for tag, call in zip(tags[1:], pt.copies()):
        assert call[-2:] == [f"docker://ghcr.io/o/img@{digest}", f"docker://ghcr.io/o/img:{tag}"]
        assert "--preserve-digests" in call
    assert r.output("digests") == digest
    assert pt.out.read_text().strip() == f"digests={digest}"


@pytest.mark.security
def test_push_tags_fails_when_a_copy_changes_the_digest(pt):
    """A copy whose registry digest differs from the pushed one fails the step (the tag would not carry the
    signature).

    OLD: push-tags: a copy that changes the digest fails the step
    """
    r = pt.run("a", "b", BREAK_COPY="1")
    assert r.rc != 0
    assert any(l.startswith("::error::") for l in (r.out + r.err).splitlines())


def test_push_tags_needs_a_tag(pt):
    """OLD: push-tags: no tag: fails"""
    assert pt.run().rc != 0


WORKFLOWS = ["build", "build-beta", "build-dx", "build-nvidia"]


@pytest.mark.parametrize("wf", WORKFLOWS)
@pytest.mark.static
def test_image_workflows_publish_through_push_tags(wf):
    """The four image workflows push once through push-tags.sh (a second `podman push` of one image gives a
    second digest) and the sign job signs the digests output.

    OLD: push-tags: *.yml: no podman push in the workflow (a second push of one image gives another digest)
    OLD: push-tags: *.yml: pushes once through push-tags.sh
    OLD: push-tags: *.yml: the sign job still signs the digests output
    """
    text = (REPO / ".github" / "workflows" / f"{wf}.yml").read_text()
    assert "podman push" not in text
    assert len(re.findall(r"\.github/scripts/push-tags\.sh ", text)) == 1
    assert "for digest in ${DIGESTS}" in text


@pytest.mark.static
def test_build_workflow_publishes_every_alias_tag():
    """OLD: push-tags: build.yml: first alias tag is the local image, all alias tags are published"""
    text = (REPO / ".github/workflows/build.yml").read_text()
    assert 'push-tags.sh "${IMAGE_NAME}:${first}" "${IMAGE_REGISTRY}/${IMAGE_NAME}" ${ALIAS_TAGS}' in text


# =====================================================================================================================
# prune-testing: never delete a promoted version
# =====================================================================================================================

PRUNE = SCRIPTS / "prune-testing.py"


def _version(i, created, tags):
    return {"id": i, "name": "sha256:" + format(i, "x") * 64, "created_at": created, "metadata": {"container": {"tags": tags}}}


@pytest.mark.security
def test_prune_never_deletes_a_promoted_version(sandbox):
    """A version carrying a latest* tag next to testing* tags is never deleted, however old; a plain old testing
    build is.

    OLD: prune-testing: old testing-only build is deleted
    OLD: prune-testing: versions with latest tags are kept
    """
    versions = [
        _version(1, "2026-01-01T00:00:00Z", ["testing-1111111", "latest", "latest-20260101-2222222", "20260101"]),
        _version(2, "2026-01-02T00:00:00Z", ["testing-3333333", "latest-20260102"]),
        _version(3, "2026-01-03T00:00:00Z", ["testing-4444444"]),
        _version(4, "2026-01-04T00:00:00Z", ["testing-5555555"]),
    ]
    r = sandbox.run(["python3", "-I", PRUNE], stdin=json.dumps(versions), env={"KEEP": "1", "DRY_RUN": "true"})
    assert r.rc == 0, r.err
    deleted = {int(m) for m in re.findall(r"DELETE image id=(\d+) ", r.out)}
    assert 3 in deleted
    assert not deleted & {1, 2}


# =====================================================================================================================
# bump-pin.sh (dev-packages): the decision table
# =====================================================================================================================

SKOPEO_PIN = r"""
case "$1" in
    inspect)
        [ "${SKOPEO_FAIL:-0}" = 1 ] && { echo "unauthorized or unreachable" >&2; exit 1; }
        [ "${SKOPEO_EMPTY:-0}" = 1 ] && exit 0
        ref="${@: -1}"
        # a dated tag answers like :latest when DATED_TAG names it
        [ -n "${DATED_TAG:-}" ] && ref="${ref/:${DATED_TAG}/:latest}"
        printf 'manifest of %s' "$ref" ;;
    list-tags)
        if [ -n "${TAGS_JSON:-}" ]; then echo "$TAGS_JSON"; else echo '{"Tags":[]}'; fi ;;
esac
"""
COSIGN_PIN = 'exit "${COSIGN_RC:-0}"'
PIN_FILE = "variants/dx/Containerfile"
PIN_LINES = r"^ARG DEV_PACKAGES_(TAG|DIGEST)="


def pin_digest(text):
    return re.search(r"^ARG DEV_PACKAGES_DIGEST=(.*)$", text, re.M).group(1)


def manifest_digest(image, tag):
    return hashlib.sha256(f"manifest of docker://ghcr.io/redcodeworks/{image}:{tag}".encode()).hexdigest()


class Bump:
    """A scratch tree with the real dx Containerfile and key, a skopeo and a cosign stub."""

    def __init__(self, sandbox, stubs):
        self.sbx = sandbox
        self.root = sandbox.tmp / "tree"
        (self.root / "keys").mkdir(parents=True)
        (self.root / "variants/dx").mkdir(parents=True)
        (self.root / "keys/redcodeworks-toolbox-cosign.pub").write_text("key\n")
        shutil.copy(REPO / PIN_FILE, self.root / PIN_FILE)
        self.original = (self.root / PIN_FILE).read_text()
        self.gho = sandbox.tmp / "gho"
        self.gho.write_text("")
        stubs.add("skopeo", script=SKOPEO_PIN)
        stubs.add("cosign", script=COSIGN_PIN)
        self.stubs = stubs

    @property
    def file(self):
        return (self.root / PIN_FILE).read_text()

    def set_pin(self, digest=None, raw=None):
        text = self.file
        value = raw if raw is not None else f"sha256:{digest}"
        (self.root / PIN_FILE).write_text(re.sub(r"^ARG DEV_PACKAGES_DIGEST=.*$", f"ARG DEV_PACKAGES_DIGEST={value}", text, flags=re.M))

    def run(self, image="dev-packages", **env):
        self.r = self.sbx.bash(SCRIPTS / "bump-pin.sh", image, cwd=self.root, env={"GITHUB_OUTPUT": str(self.gho), **env})
        return self.r

    def out(self, key):
        for line in self.gho.read_text().splitlines():
            if line.startswith(key + "="):
                return line.split("=", 1)[1]
        return None

    def untouched(self):
        return self.file == self.before

    def snapshot(self):
        self.before = self.file


@pytest.fixture
def bump(sandbox, stubs):
    return Bump(sandbox, stubs)


LATEST = manifest_digest("dev-packages", "latest")

# (id, pin digest (None = keep the file's), raw pin, image, env, expected rc, file changes, result)
BUMP_ROWS = [
    ("equal", LATEST, None, "dev-packages", {}, 0, False, "equal"),
    ("different", None, None, "dev-packages", {}, 10, True, "different"),
    ("unreachable registry", None, None, "dev-packages", {"SKOPEO_FAIL": "1"}, 1, False, "unreachable"),
    ("empty answer (latest missing)", None, None, "dev-packages", {"SKOPEO_EMPTY": "1"}, 1, False, None),
    ("bad signature", None, None, "dev-packages", {"COSIGN_RC": "1"}, 2, False, "badsignature"),
    ("bad signature with an equal digest", LATEST, None, "dev-packages", {"COSIGN_RC": "1"}, 2, False, "badsignature"),
    ("malformed pin in the file", None, "sha256:short", "dev-packages", {}, 3, False, "badpin"),
    ("unknown image name", None, None, "nothing", {}, 3, False, None),
]


@pytest.mark.security
@pytest.mark.parametrize("row", BUMP_ROWS, ids=[r[0] for r in BUMP_ROWS])
def test_bump_pin_decision_table(bump, row):
    """Exit codes 0 equal, 10 different (pin rewritten), 1 unreachable, 2 bad signature (the file is never touched),
    3 bad pin or unknown image; a bad signature fails even when the digest is equal.

    OLD: bump-pins: decision equal: exit 0, 'nothing to bump', file untouched, cosign still verified latest
    OLD: bump-pins: decision different, no dated tag matches: pin moves to latest, exit 10, only the pin lines change
    OLD: bump-pins: decision unreachable registry: exit 1, file untouched, no cosign call, result=unreachable
    OLD: bump-pins: decision empty answer (latest missing): exit 1, file untouched
    OLD: bump-pins: decision bad signature: exit 2, file untouched, result=badsignature
    OLD: bump-pins: decision bad signature with an equal digest still fails
    OLD: bump-pins: a malformed pin in the file: exit 3, no registry call
    OLD: bump-pins: an unknown image name: exit 3
    """
    _, digest, raw, image, env, rc, changes, result = row
    if digest or raw:
        bump.set_pin(digest, raw)
    bump.snapshot()
    r = bump.run(image, **env)
    assert r.rc == rc, r.out + r.err
    assert (bump.file != bump.before) is changes
    if result:
        assert bump.out("result") == result
    cosign_calls = bump.stubs["cosign"].calls
    if rc == 1:
        assert not cosign_calls, "cosign must not run when latest cannot be resolved"
    if rc == 3:
        assert not bump.stubs["skopeo"].calls, "a bad pin must not reach the registry"


@pytest.mark.security
def test_bump_pin_verifies_the_signature_of_latest_with_the_toolbox_key(bump):
    """Even when nothing changes, the digest of latest is verified against the toolbox key.

    OLD: bump-pins: decision equal: exit 0, 'nothing to bump', file untouched, cosign still verified latest
    """
    bump.set_pin(LATEST)
    bump.run()
    assert ["cosign", "verify", "--key", "keys/redcodeworks-toolbox-cosign.pub",
            f"ghcr.io/redcodeworks/dev-packages@sha256:{LATEST}"] in bump.stubs["cosign"].calls


@pytest.mark.parametrize("dated", [None, "latest-20261117-2222222"], ids=["no dated tag matches", "a dated tag has the same digest"])
def test_bump_pin_rewrites_only_the_pin_lines(bump, dated):
    """A newer signed latest moves the digest line, and the tag line to the dated tag with the same digest (else
    `latest`); nothing else in the file changes, and the previous digest is reported.

    OLD: bump-pins: decision different, no dated tag matches: pin moves to latest, exit 10, only the pin lines change
    OLD: bump-pins: decision different, a dated tag has the same digest: the tag line records it (and nothing else changes)
    """
    previous = pin_digest(bump.original)
    env = {"TAGS_JSON": json.dumps({"Tags": ["latest", "testing", "latest-20261109-1111111", "latest-20261117-2222222"]})}
    if dated:
        env["DATED_TAG"] = dated
    bump.snapshot()
    assert bump.run(**env).rc == 10
    new = bump.file
    assert f"ARG DEV_PACKAGES_DIGEST=sha256:{LATEST}" in new.splitlines()
    assert f"ARG DEV_PACKAGES_TAG={dated or 'latest'}" in new.splitlines()
    strip = lambda t: [l for l in t.splitlines() if not re.match(PIN_LINES, l)]
    assert strip(new) == strip(bump.before)
    assert bump.out("result") == "different" and bump.out("previous") == previous


# =====================================================================================================================
# brew-bump: the Justfile recipe that moves the Homebrew image pin
# =====================================================================================================================

SKOPEO_BREW = r"""
case "$1" in
    inspect) printf 'manifest of %s' "${@: -1}" ;;
    list-tags) echo '{"Tags":["latest","20261101","20261115","20261108","stable"]}' ;;
esac
"""


@pytest.mark.static
def test_containerfile_brew_pin_format():
    """The pin in the real Containerfile is a dated tag plus a sha256 digest, used together in the image reference.

    OLD: brew-bump: Containerfile: the tag is YYYYMMDD
    OLD: brew-bump: Containerfile: the digest is sha256: plus 64 hex characters
    OLD: brew-bump: Containerfile: the brew image reference uses the tag and the digest
    """
    text = (REPO / "Containerfile").read_text()
    assert re.search(r"^ARG BREW_TAG=\d{8}$", text, re.M)
    assert re.search(r"^ARG BREW_DIGEST=sha256:[0-9a-f]{64}$", text, re.M)
    assert "ARG BREW_IMAGE=ghcr.io/ublue-os/brew:${BREW_TAG}@${BREW_DIGEST}" in text


class BrewBump:
    def __init__(self, sandbox, stubs):
        self.sbx = sandbox
        self.work = sandbox.tmp / "work"
        (self.work / "keys").mkdir(parents=True)
        for f in ("Justfile", "Containerfile"):
            shutil.copy(REPO / f, self.work / f)
        (self.work / "keys/ublue-os-brew-cosign.pub").write_text("key\n")
        for d in ("githooks",):
            if (REPO / d).is_dir():
                shutil.copytree(REPO / d, self.work / d)
        if (REPO / "image-template.env").is_file():
            shutil.copy(REPO / "image-template.env", self.work / "image-template.env")
        self.original = (REPO / "Containerfile").read_text()
        stubs.add("skopeo", script=SKOPEO_BREW)
        stubs.add("cosign", script='exit "${COSIGN_RC:-0}"')
        self.stubs = stubs

    def run(self, *args, **env):
        return self.sbx.run(["just", "--justfile", "Justfile", "--working-directory", ".", "brew-bump", *args], cwd=self.work, env=env)

    @property
    def containerfile(self):
        return (self.work / "Containerfile").read_text()


@pytest.fixture
def brew(sandbox, stubs):
    return BrewBump(sandbox, stubs)


def _arg_free(text):
    return [l for l in text.splitlines() if not re.match(r"^ARG BREW_(TAG|DIGEST)=", l)]


@pytest.mark.security
def test_brew_bump_pins_the_verified_digest_of_a_tag(brew):
    """Bumping to a tag writes the digest of the raw manifest and the tag, after cosign verified that digest
    reference; the rest of the Containerfile is untouched.

    OLD: brew-bump: bump with a tag: exit 0
    OLD: brew-bump: bump: the digest comes from the raw manifest
    OLD: brew-bump: bump: the tag is written
    OLD: brew-bump: bump: cosign verified the digest reference first
    OLD: brew-bump: bump: the rest of the Containerfile is untouched
    """
    r = brew.run("20261122")
    digest = hashlib.sha256(b"manifest of docker://ghcr.io/ublue-os/brew:20261122").hexdigest()
    assert r.rc == 0, r.out + r.err
    lines = brew.containerfile.splitlines()
    assert f"ARG BREW_DIGEST=sha256:{digest}" in lines and "ARG BREW_TAG=20261122" in lines
    assert ["cosign", "verify", "--key", "keys/ublue-os-brew-cosign.pub", f"ghcr.io/ublue-os/brew@sha256:{digest}"] in brew.stubs["cosign"].calls
    assert _arg_free(brew.containerfile) == _arg_free(brew.original)


@pytest.mark.security
def test_brew_bump_leaves_the_file_alone_when_verification_fails(brew):
    """OLD: brew-bump: verification failure: exit 1
    OLD: brew-bump: verification failure: the Containerfile is unchanged
    """
    r = brew.run("20261122", COSIGN_RC="1")
    assert r.rc == 1 and brew.containerfile == brew.original


def test_brew_bump_refuses_a_bad_tag(brew):
    """OLD: brew-bump: a bad tag is refused
    OLD: brew-bump: a bad tag leaves the Containerfile alone
    """
    r = brew.run("notatag")
    assert r.rc == 1 and brew.containerfile == brew.original


def test_brew_bump_default_is_the_newest_dated_tag(brew):
    """OLD: brew-bump: default: the newest dated tag"""
    assert brew.run().rc == 0
    assert "ARG BREW_TAG=20261115" in brew.containerfile.splitlines()


# =====================================================================================================================
# datastore-pin-bump.sh: newest patch inside the pinned major
# =====================================================================================================================

SKOPEO_DS = r"""
case "$1" in
    list-tags) [ "${SKOPEO_FAIL:-0}" = 1 ] && exit 1; echo "{\"Tags\":[${TAGS}]}" ;;
    inspect) printf 'manifest of %s' "${@: -1}" ;;
esac
"""

# synthetic pins in the format of variants/dx/datastore/datastore.env (the real file moves with every bump)
DS_ENV = """\
POSTGRESQL_IMAGE=docker.io/library/postgres
POSTGRESQL_TAG=17.12-alpine
POSTGRESQL_DIGEST=sha256:{d}
POSTGRESQL_MAJOR=17
VALKEY_IMAGE=docker.io/valkey/valkey
VALKEY_TAG=9.1.3-alpine
VALKEY_DIGEST=sha256:{d}
VALKEY_MAJOR=9
SEAWEEDFS_IMAGE=docker.io/chrislusf/seaweedfs
SEAWEEDFS_TAG=3.99
SEAWEEDFS_DIGEST=sha256:{d}
SEAWEEDFS_MAJOR=3
KAFKA_IMAGE=docker.io/apache/kafka
KAFKA_TAG=4.3.2
KAFKA_DIGEST=sha256:{d}
KAFKA_MAJOR=4
""".format(d="0" * 64)

PGTAGS = '"latest","17-alpine","17.12-alpine","17.13-alpine","17.13","17.14-alpine","17.14-rc1-alpine","16.9-alpine","alpine"'


class Datastore:
    def __init__(self, sandbox, stubs):
        self.sbx, self.stubs = sandbox, stubs
        self.env = sandbox.tmp / "ds.env"
        self.env.write_text(DS_ENV)
        self.gho = sandbox.tmp / "gho"
        self.gho.write_text("")
        stubs.add("skopeo", script=SKOPEO_DS)

    def edit(self, key, value):
        self.env.write_text(re.sub(rf"^{key}=.*$", f"{key}={value}", self.env.read_text(), flags=re.M))

    def run(self, svc, tags="", **env):
        self.r = self.sbx.bash(SCRIPTS / "datastore-pin-bump.sh", svc,
                               env={"TAGS": tags, "DATASTORE_ENV": str(self.env), "GITHUB_OUTPUT": str(self.gho), **env})
        return self.r

    def out(self, key):
        for line in self.gho.read_text().splitlines():
            if line.startswith(key + "="):
                return line.split("=", 1)[1]
        return None

    def value(self, key):
        return re.search(rf"^{key}=(.*)$", self.env.read_text(), re.M).group(1)


@pytest.fixture
def ds(sandbox, stubs):
    return Datastore(sandbox, stubs)


def ds_digest(image, tag):
    return "sha256:" + hashlib.sha256(f"manifest of docker://{image}:{tag}".encode()).hexdigest()


# (id, service, tags, expected rc, expected new tag (None = file unchanged), expected major note fragment)
DS_ROWS = [
    ("newer patch with the same suffix", "postgresql", PGTAGS, 10, "17.14-alpine", None),
    ("a newer major is only reported", "postgresql", '"17.12-alpine","17.11-alpine","18.1-alpine","18.2-alpine"', 0, None, "18"),
    ("already the newest", "postgresql", '"17.12-alpine","17.11-alpine"', 0, None, None),
    ("bare version tags", "kafka", '"4.3.2","4.4.0","4.4.1","4.4.1-rc1","5.0.0","latest"', 10, "4.4.1", "5"),
    ("version sort is numeric", "seaweedfs", '"3.99","3.100","3.101","4.60"', 10, "3.101", "4"),
    ("suffix is kept, other shapes ignored", "valkey", '"9.1.3-alpine","9.1.4-alpine","9.2.0-alpine","9.2-alpine","9.2.0","9.1.4-bookworm"', 10, "9.2.0-alpine", None),
]


@pytest.mark.parametrize("row", DS_ROWS, ids=[r[0] for r in DS_ROWS])
def test_datastore_bump_picks_the_newest_tag_inside_the_major(ds, row):
    """Only same-shape, same-suffix, non-prerelease tags of the pinned major are candidates (numeric version
    order); a newer major is reported in major_note and never applied; only the tag and digest lines change.

    OLD: datastore-bump: newer patch in the pinned major with the same suffix: pin rewritten to 17.14-alpine with its digest, exit 10, nothing else changes
    OLD: datastore-bump: release candidates, the suffix-less 17.13, floating tags and other majors are never chosen
    OLD: datastore-bump: a newer major is only reported (major_note) and the pin stays: exit 0, file unchanged
    OLD: datastore-bump: already the newest: equal, nothing to bump, exit 0
    OLD: datastore-bump: bare version tags (kafka 4.3.2): 4.4.1 chosen inside major 4, 5.0.0 reported as a newer major
    OLD: datastore-bump: version sort is numeric (3.101 beats 3.99), 4.60 is a newer major
    OLD: datastore-bump: valkey: the -alpine suffix is kept (9.2.0-alpine), the two-part 9.2-alpine and other suffixes are ignored
    """
    _, svc, tags, rc, new_tag, note = row
    before = ds.env.read_text()
    r = ds.run(svc, tags)
    assert r.rc == rc, r.out + r.err
    upper = svc.upper()
    if new_tag:
        image = ds.value(f"{upper}_IMAGE")
        assert ds.value(f"{upper}_TAG") == new_tag
        assert ds.value(f"{upper}_DIGEST") == ds_digest(image, new_tag)
        strip = lambda t: [l for l in t.splitlines() if not re.match(rf"{upper}_(TAG|DIGEST)=", l)]
        assert strip(ds.env.read_text()) == strip(before)
        assert ds.out("result") == "different"
    else:
        assert ds.env.read_text() == before
        assert ds.out("result") == "equal"
    if note:
        assert f"({note})" in (ds.out("major_note") or "")
    else:
        assert not ds.out("major_note")


# (id, service, edit (key, value) or None, tags, env, expected rc, registry reached)
DS_FAIL_ROWS = [
    ("unreachable registry", "postgresql", None, "", {"SKOPEO_FAIL": "1"}, 1, True),
    ("no tag that looks like the pin", "postgresql", None, '"latest","alpine"', {}, 1, True),
    ("malformed pin", "kafka", ("KAFKA_DIGEST", "sha256:short"), '"4.4.0"', {}, 3, False),
    ("unknown service", "nosuch", None, "", {}, 3, False),
    ("tag outside the pinned major in the file", "postgresql", ("POSTGRESQL_TAG", "18.1-alpine"), '"18.1-alpine"', {}, 3, False),
]


@pytest.mark.parametrize("row", DS_FAIL_ROWS, ids=[r[0] for r in DS_FAIL_ROWS])
def test_datastore_bump_failures_leave_the_file_alone(ds, row):
    """No decision possible (1) or a bad pin / unknown service (3, before any registry call): the file never changes.

    OLD: datastore-bump: an unreachable registry: exit 1, file unchanged, result=unreachable
    OLD: datastore-bump: no tag that looks like the pin: exit 1, file unchanged
    OLD: datastore-bump: a malformed pin: exit 3, no registry call
    OLD: datastore-bump: an unknown service: exit 3
    OLD: datastore-bump: a tag outside the pinned major in the file is a bad pin
    """
    _, svc, edit, tags, env, rc, reached = row
    if edit:
        ds.edit(*edit)
    before = ds.env.read_text()
    assert ds.run(svc, tags, **env).rc == rc
    assert ds.env.read_text() == before
    assert bool(ds.stubs["skopeo"].calls) is reached


@pytest.mark.static
@pytest.mark.parametrize("svc", ["postgresql", "valkey", "seaweedfs", "kafka"])
def test_real_datastore_pins_are_well_formed(ds, svc):
    """The bump accepts the pins of the real datastore.env (an unreachable registry gives 1, a bad pin would give 3).
    NEW: the old tests copied the real pins as test data and broke when a bump moved them."""
    ds.env.write_text((REPO / "variants/dx/datastore/datastore.env").read_text())
    assert ds.run(svc, "", SKOPEO_FAIL="1").rc == 1


# =====================================================================================================================
# upstream-check.sh and bump-upstream.sh
# =====================================================================================================================

def sha(ch):
    return ch * 40


class Upstream:
    """A scratch repo root holding upstream-env.sh and the check script, a stub gh with a GET table."""

    def __init__(self, sandbox, stubs):
        self.sbx, self.stubs = sandbox, stubs
        self.root = sandbox.tmp / "crepo"
        (self.root / "binaries/lib").mkdir(parents=True)
        (self.root / ".github/scripts").mkdir(parents=True)
        (self.root / "img").mkdir()
        shutil.copy(REPO / "binaries/lib/upstream-env.sh", self.root / "binaries/lib/")
        shutil.copy(SCRIPTS / "upstream-check.sh", self.root / ".github/scripts/")
        self.gh = GhTable(stubs)

    def pin(self, repo="o/p", tag="v1.1.4", commit=None, watch=None):
        lines = [f"UPSTREAM_REPO={repo}"] + ([f"UPSTREAM_WATCH={watch}"] if watch else []) + [f"UPSTREAM_TAG={tag}", f"UPSTREAM_COMMIT={commit or sha('a')}"]
        (self.root / "img/upstream.env").write_text("\n".join(lines) + "\n")

    def check(self):
        r = self.sbx.bash(self.root / ".github/scripts/upstream-check.sh", "img", env={"REPO_ROOT": str(self.root)})
        return r.out.strip(), r

    def reply(self, *pairs):
        self.gh.reply(*pairs)

    def compare(self, a, b, status):
        return (f"repos/o/p/compare/{a}...{b}", status)


@pytest.fixture
def up(sandbox, stubs):
    return Upstream(sandbox, stubs)


# Each row: (id, pin kwargs, replies (a function of nothing: literal), expected first word, expected rest or None).
def _rows():
    a = sha("a")
    cmp = lambda x, y, s: (f"repos/o/p/compare/{x}...{y}", s)
    rel = lambda t: ("repos/o/p/releases/latest", t)
    com = lambda t, c: (f"repos/o/p/commits/{t}", c)
    tagpin = dict(tag="v1.1.4")
    commitpin = dict(tag="")
    fork = dict(repo="f/ork", watch="o/p", tag="")
    return [
        ("tag pin: the pinned tag is the latest release", tagpin, [rel("v1.1.4")], "current", None),
        ("tag pin: a newer release", tagpin, [rel("v1.1.5"), com("v1.1.5", sha("b"))], "bump", f"v1.1.5 {sha('b')}"),
        ("tag pin: versions compare numerically", tagpin, [rel("v1.10.0"), com("v1.10.0", sha("c"))], "bump", f"v1.10.0 {sha('c')}"),
        ("tag pin: a pin ahead of the latest release is current", tagpin, [rel("v1.0.9")], "current", None),
        ("tag pin: upstream unreachable fails soft", tagpin, [], "unreachable", None),
        ("tag pin: a tag that cannot be resolved to a commit fails soft", tagpin, [rel("v1.1.5")], "unreachable", None),
        ("commit pin: only an older release reports", commitpin, [rel("1.0.3"), com("1.0.3", sha("d")), cmp(a, sha("d"), "behind")], "report", None),
        ("commit pin: diverged release bumps", commitpin, [rel("1.1.0"), com("1.1.0", sha("e")), cmp(a, sha("e"), "diverged")], "bump", f"1.1.0 {sha('e')}"),
        ("commit pin: a release ahead of the pin bumps", commitpin, [rel("1.1.0"), com("1.1.0", sha("e")), cmp(a, sha("e"), "ahead")], "bump", f"1.1.0 {sha('e')}"),
        ("commit pin: no release object, newest tag ahead", commitpin, [("repos/o/p/tags", "1.2.0"), com("1.2.0", sha("f")), cmp(a, sha("f"), "ahead")], "bump", f"1.2.0 {sha('f')}"),
        ("commit pin: no release and no tag reports", commitpin, [("repos/o/p/tags", "")], "report", None),
        ("commit pin: the pinned commit is the latest release", commitpin, [rel("1.0.3"), com("1.0.3", a), cmp(a, a, "identical")], "current", None),
        ("fork: the latest release is behind the pin", fork, [rel("1.0.3"), com("1.0.3", sha("d")), cmp(a, sha("d"), "behind")], "report", None),
        ("fork: a release the fork already has", fork, [rel("1.1.0"), com("1.1.0", sha("e")), cmp(a, sha("e"), "ahead"), ("repos/f/ork", "main"), (f"repos/f/ork/compare/{sha('e')}...main", "ahead")], "bump", f"1.1.0 {sha('e')}"),
        ("fork: a release the fork does not have yet", fork, [rel("1.1.0"), com("1.1.0", sha("e")), cmp(a, sha("e"), "ahead"), ("repos/f/ork", "main"), (f"repos/f/ork/compare/{sha('e')}...main", "diverged")], "forkbehind", None),
        ("fork: a failing fork compare counts as behind", fork, [rel("1.1.0"), com("1.1.0", sha("e")), cmp(a, sha("e"), "ahead"), ("repos/f/ork", "main")], "forkbehind", None),
        ("fork: the fork cannot be read", fork, [rel("1.1.0"), com("1.1.0", sha("e")), cmp(a, sha("e"), "ahead")], "unreachable", None),
        ("fork: the tag label is the latest release", dict(repo="f/ork", watch="o/p", tag="1.1.0", commit=sha("e")), [rel("1.1.0")], "current", None),
    ]


UP_ROWS = _rows()


@pytest.mark.parametrize("row", UP_ROWS, ids=[r[0] for r in UP_ROWS])
def test_upstream_check_decision(up, row):
    """One decision line: current, bump <tag> <commit>, report, forkbehind or unreachable (fail soft, exit 0). The
    check only reads (gh api GET) and asks the watched project, never the fork, for releases.

    OLD: upstream-check: check: the pinned tag is the latest release: current
    OLD: upstream-check: check: a newer release: bump with the tag and its commit
    OLD: upstream-check: check: versions compare numerically (v1.10.0 is newer than v1.1.4)
    OLD: upstream-check: check: a pin ahead of the latest release is current
    OLD: upstream-check: check: upstream unreachable fails soft with a notice
    OLD: upstream-check: check: a tag that cannot be resolved to a commit fails soft
    OLD: upstream-check: check: a commit pin with only an older release reports and opens nothing
    OLD: upstream-check: check: a tag that is not an ancestor of the pinned commit (diverged): bump
    OLD: upstream-check: check: a commit pin with a release ahead of it: bump
    OLD: upstream-check: check: no release object, newest tag ahead of the commit: bump
    OLD: upstream-check: check: no release and no tag: report only
    OLD: upstream-check: check: the pinned commit is the latest release: current
    OLD: upstream-check: check (fork): the latest release is behind the pin: report, nothing to open
    OLD: upstream-check: check (fork): a new release that the fork already has: bump (pin = commit, tag = label)
    OLD: upstream-check: check (fork): a new release the fork does not have yet: forkbehind, no bump
    OLD: upstream-check: check (fork): a fork compare that fails counts as the fork being behind
    OLD: upstream-check: check (fork): the fork itself cannot be read: fail soft
    OLD: upstream-check: check (fork): the tag label is the latest release: current
    OLD: upstream-check: check (fork): releases are asked of the watched project, never of the fork
    OLD: upstream-check: check: only reads (gh api GET)
    """
    _, pin, replies, word, rest = row
    up.pin(**pin)
    up.reply(*replies)
    out, r = up.check()
    assert r.rc == 0, r.err
    assert out.split(" ")[0] == word, out
    if rest:
        assert out.split(" ", 1)[1] == rest
    calls = up.stubs["gh"].calls
    assert calls and all(c[1] == "api" for c in calls), calls
    assert not any(a in ("--method", "-X") for c in calls for a in c)
    assert not any(re.match(r"repos/f/ork/(tags|releases)", c[2]) for c in calls)


# ---- bump-upstream.sh with a local origin and a stub gh

class BumpUpstream:
    def __init__(self, sandbox, stubs, rc=None):
        self.sbx, self.stubs = sandbox, stubs
        self.gh = GhTable(stubs, rc=rc)
        self.origin = sandbox.tmp / "origin.git"
        subprocess.run(["git", "init", "-q", "--bare", "-b", "testing", str(self.origin)], check=True)
        self.wc = sandbox.tmp / "wc"
        (self.wc / "binaries/lib").mkdir(parents=True)
        (self.wc / ".github/scripts").mkdir(parents=True)
        (self.wc / "img").mkdir()
        shutil.copy(REPO / "binaries/lib/upstream-env.sh", self.wc / "binaries/lib/")
        shutil.copy(SCRIPTS / "bump-upstream.sh", self.wc / ".github/scripts/")
        (self.wc / "img/upstream.env").write_text(f"# pin\nUPSTREAM_REPO=o/p\nUPSTREAM_TAG=v1.1.4\nUPSTREAM_COMMIT={sha('a')}\n")
        self.git("init", "-q", "-b", "testing")
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "base")
        self.git("remote", "add", "origin", str(self.origin))
        self.git("push", "-q", "origin", "testing")

    def git(self, *args, repo=None):
        env = {"GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.invalid", "GIT_COMMITTER_NAME": "t",
               "GIT_COMMITTER_EMAIL": "t@example.invalid", "GIT_CONFIG_GLOBAL": "/dev/null", "PATH": "/usr/bin:/bin"}
        p = subprocess.run(["git", *args], cwd=repo or self.wc, env=env, capture_output=True, text=True, check=True)
        return p.stdout.strip()

    def bump(self, tag, commit):
        self.r = self.sbx.bash(self.wc / ".github/scripts/bump-upstream.sh", "img", tag, commit, env={"REPO_ROOT": str(self.wc)})
        return self.r

    def gh_calls(self):
        return self.stubs["gh"].calls

    def pr_calls(self, kind):
        return [c for c in self.gh_calls() if c[1:3] == ["pr", kind]]

    def dispatches(self):
        return [c for c in self.gh_calls() if c[1:3] == ["workflow", "run"]]

    def branch_file(self, branch="bump/img", path="img/upstream.env"):
        return self.git("show", f"{branch}:{path}", repo=self.origin)


def flag(call, name):
    return call[call.index(name) + 1]


@pytest.fixture
def bu(sandbox, stubs):
    return BumpUpstream(sandbox, stubs)


def test_bump_opens_one_pull_request_and_dispatches_the_checks(bu):
    """A new bump: branch bump/<name> into testing, only upstream.env changes, a PR titled with the version whose
    body links release notes and compare and says how to start the checks, the Test workflow dispatched on the
    branch, no commit trailers.

    OLD: upstream-check: bump: a new PR is opened
    OLD: upstream-check: bump: PR from bump/<name> into testing, titled with the version
    OLD: upstream-check: bump: body links the release notes and the compare URL
    OLD: upstream-check: bump: the body says how to start the checks by hand
    OLD: upstream-check: bump: the Test workflow is dispatched on the bump branch after the PR is created
    OLD: upstream-check: bump: the branch carries the new pin
    OLD: upstream-check: bump: only upstream.env changes
    OLD: upstream-check: bump: no commit trailers
    """
    r = bu.bump("v1.1.5", sha("b"))
    assert r.rc == 0, r.out + r.err
    (create,) = bu.pr_calls("create")
    assert flag(create, "--base") == "testing" and flag(create, "--head") == "bump/img"
    assert "v1.1.5" in flag(create, "--title")
    body = flag(create, "--body")
    assert "releases/tag/v1.1.5" in body and "compare/v1.1.4...v1.1.5" in body
    assert "gh workflow run test.yml --ref bump/img" in body
    assert [c[-2:] for c in bu.dispatches()] == [["--ref", "bump/img"]]
    assert sha("b") in bu.branch_file()
    assert bu.git("diff", "--name-only", "testing", "bump/img", repo=bu.origin).split() == ["img/upstream.env"]
    assert "co-authored-by" not in bu.git("log", "--format=%B", "bump/img", repo=bu.origin).lower()


def test_bump_failed_dispatch_is_a_warning(sandbox, stubs):
    """OLD: upstream-check: bump: a failed dispatch is a warning, not a failure"""
    bu = BumpUpstream(sandbox, stubs, rc={"workflow run": 1})
    r = bu.bump("v1.1.5", sha("b"))
    assert r.rc == 0
    assert any(l.startswith("::warning::") for l in r.out.splitlines())


def test_bump_with_the_version_already_open_does_nothing(bu):
    """OLD: upstream-check: bump: a PR for that version is already open: nothing happens, no dispatch"""
    bu.gh.set_pr_list(json.dumps({"number": 7, "title": "Bump img to v1.1.5"}) + "\n")
    r = bu.bump("v1.1.5", sha("b"))
    assert r.rc == 0
    assert not bu.pr_calls("create") and not bu.pr_calls("edit") and not bu.dispatches()


def test_bump_updates_an_open_pr_for_an_older_version_without_force_push(bu):
    """An open PR for an older version is edited (not duplicated), the checks are dispatched again, and the branch
    gets one more commit on top (a force-push would rewrite it).

    OLD: upstream-check: bump: a PR for an older version is updated, not duplicated, and the checks are dispatched again
    OLD: upstream-check: bump: the update is a new commit on the same branch (no force-push)
    """
    assert bu.bump("v1.1.5", sha("b")).rc == 0
    first_tip = bu.git("rev-parse", "bump/img", repo=bu.origin)
    bu.gh.set_pr_list(json.dumps({"number": 7, "title": "Bump img to v1.1.5"}) + "\n")
    r = bu.bump("v1.1.6", sha("c"))
    assert r.rc == 0, r.out + r.err
    (edit,) = bu.pr_calls("edit")
    assert edit[3] == "7" and "v1.1.6" in flag(edit, "--title")
    assert len(bu.dispatches()) == 2
    assert bu.git("merge-base", "--is-ancestor", first_tip, "bump/img", repo=bu.origin) == ""
    assert int(bu.git("rev-list", "--count", "testing..bump/img", repo=bu.origin)) >= 2
    assert sha("c") in bu.branch_file()


def test_bump_of_a_fork_links_the_followed_project(bu):
    """A fork pin: the PR links the followed project's release and compare and says the pin is the fork's commit
    and the tag only a label.

    OLD: upstream-check: bump (fork): links the followed project and says the pin is the fork's commit, the tag a label
    """
    (bu.wc / "img/upstream.env").write_text(f"UPSTREAM_REPO=f/ork\nUPSTREAM_WATCH=o/p\nUPSTREAM_TAG=1.0.3\nUPSTREAM_COMMIT={sha('a')}\n")
    bu.git("commit", "-q", "-a", "-m", "fork pin")
    bu.git("push", "-q", "origin", "testing")
    r = bu.bump("1.1.0", sha("b"))
    assert r.rc == 0, r.out + r.err
    (create,) = bu.pr_calls("create")
    body = flag(create, "--body")
    assert "github.com/o/p/releases/tag/1.1.0" in body and "github.com/o/p/compare/1.0.3...1.1.0" in body
    assert "f/ork" in body
