#!/usr/bin/env python3
"""The three input hashes that decide which image has to be built (one place, tested by
tests/py/test_plan.py).

  inputs_hash.py vanilla|dx|gx [<rev>]     print the hash of <rev> (default HEAD)

Imported by the plan scripts: is_dx_only, is_gx_only, is_variant_shared,
is_pipeline_only, vanilla_inputs(rev), dx_inputs(rev), gx_inputs(rev) and
nearest_image_for_inputs.

  dx_inputs       hash of the committed files that only the developer image uses
                  (is_dx_only) plus the ones both variants share (is_variant_shared)
  gx_inputs       hash of the committed files that only the gamer image uses
                  (is_gx_only) plus the ones both variants share (is_variant_shared)
  vanilla_inputs  hash of every other committed file (neither dx-only, gx-only nor
                  shared), docs-only files (docs_only.py) left out too

All hash the sorted `git ls-tree -r` entries (mode, blob id, path) that pass the filter,
so they are stable and do not depend on commit ids, dates or the order of anything. A
change that touches only dx files leaves vanilla_inputs and gx_inputs equal; a change
that touches only the default image leaves dx_inputs and gx_inputs equal; a change to a
shared file (the reusable workflow, the plan script, the toolbox key) moves both variant
hashes and not vanilla_inputs.
"""

import hashlib
import os
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ci  # noqa: E402
import docs_only  # noqa: E402
import registry  # noqa: E402


def is_dx_only(path: str) -> bool:
    """The paths of ONE variant: the dx directory, its package lists (packages/dx) and
    its smoke test; the gx directory, its package lists (packages/gx) and its smoke test
    (the workflow files are shared since 2026-11-17, see below). The tests are no input
    of any image (docs_only lists tests/** with the docs). Everything else
    (Containerfile, build_files, system_files, packages/default, Justfile, the other
    workflows and scripts) belongs to the default image: a change there rebuilds it, and
    then the variants follow its new digest.
    """
    return (
        path.startswith(("variants/dx/", "packages/dx/"))
        or path == ".github/scripts/dx-smoke.sh"
    )


def is_gx_only(path: str) -> bool:
    """Whether a path belongs to the gx variant only.

    Receives a repository path; returns True for the gx directory, its package lists
    and its smoke test, False otherwise. See is_dx_only for how the groups divide
    the tree.
    """
    return (
        path.startswith(("variants/gx/", "packages/gx/"))
        or path == ".github/scripts/gx-smoke.sh"
    )


def is_variant_shared(path: str) -> bool:
    """The paths BOTH variants are built with: the reusable workflow (dx-image.yml,
    parameterized by the variant), the one caller of the two required variants
    (build-variant.yml, added 2026-11-17: editing it rebuilds dx AND gx), its plan and
    result scripts, the key the list-image pins are verified with. They count in
    dx_inputs and in gx_inputs, never in vanilla_inputs.
    """
    return path in (
        ".github/workflows/dx-image.yml",
        ".github/workflows/build-variant.yml",
        ".github/scripts/plan_dx.py",
        ".github/scripts/aggregate_dx.py",
        "keys/redcodeworks-toolbox-cosign.pub",
    )


def is_pipeline_only(path: str) -> bool:
    """The pipeline-only paths: files that run in CI but are not read by any image
    build, so changing one rebuilds neither image: the publication of `latest` and the
    rollback, the variant dispatch, the failure issue, the bump automation, the daily
    prune, the required-branch and test workflows, the audit and secret-scan config, the
    git hooks, and the NVIDIA variant and the extra variants (built by their own
    dispatch-only workflows from a published image). (build.yml, build-variant.yml and
    the scripts they call still count: they contain the builds.) The prebuilt binaries
    are no special case any more (2026-11-16): the digest pin of octarine-bins in the
    Containerfile is an ordinary image input, so a bump rebuilds the image on testing.
    """
    # the scripts and workflows of the pipeline itself
    if path in (
        ".github/scripts/dispatch_variant.py",
        ".github/scripts/publish_latest.py",
        ".github/scripts/ci_issue.py",
        ".github/scripts/sanity.py",
        ".github/scripts/prune_daily.py",
    ):
        return True
    # every bump script, however many there are
    if path.startswith(".github/scripts/bump_") and path.endswith(".py"):
        return True
    # workflows that publish, roll back, bump, prune or guard branches
    if path in (
        ".github/workflows/publish-latest.yml",
        ".github/workflows/rollback-latest.yml",
        ".github/workflows/bump-pins.yml",
        ".github/workflows/prune-daily.yml",
        ".github/workflows/require-testing-branch.yml",
        ".github/workflows/test.yml",
    ):
        return True
    # the NVIDIA variant and the extra variants have their own dispatch-only workflows
    if path in (
        ".github/workflows/build-nvidia.yml",
        ".github/workflows/build-extra.yml",
        ".github/scripts/nvidia-smoke.sh",
        ".github/scripts/nvidia_akmods_ref.py",
    ) or path.startswith("variants/nvidia/"):
        return True
    return path in (
        ".github/zizmor.yml",
        ".github/dependabot.yml",
        ".gitleaks.toml",
    ) or path.startswith("githooks/")


def kinds_of(path: str) -> set[str]:
    """The kinds whose hash a file belongs to (none for a pipeline-only or docs-only
    file).
    """
    # pipeline-only files rebuild nothing
    if is_pipeline_only(path):
        return set()
    # files both variants are built with count for dx and gx
    if is_variant_shared(path):
        return {"dx", "gx"}
    # dx-only files count for dx
    if is_dx_only(path):
        return {"dx"}
    # gx-only files count for gx
    if is_gx_only(path):
        return {"gx"}
    return set() if docs_only.is_docs(path) else {"vanilla"}


def _inputs(kind: str, rev: str = "HEAD") -> str:
    """The hash of one kind (vanilla, dx or gx) at <rev>; SystemExit(1) for an unknown
    revision.
    """
    # an unknown revision is the caller's mistake: fail clearly instead of hashing
    # nothing
    if (
        subprocess.run(
            ["git", "rev-parse", "--verify", "--quiet", f"{rev}^{{tree}}"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        ).returncode
        != 0
    ):
        ci.log.error(f"inputs-hash: unknown revision '{rev}'")
        raise SystemExit(1)
    tree = subprocess.run(
        ["git", "ls-tree", "-r", "--full-tree", rev],
        stdout=subprocess.PIPE,
        text=True,
        check=True,
    ).stdout
    # one (mode/type/object, path) pair per tracked file at the revision
    entries = (entry.partition("\t") for entry in tree.splitlines())
    # keep the files that belong to this kind, as bytes so sorting matches LC_ALL=C
    lines = [
        f"{meta}\t{path}\n".encode()
        for meta, _, path in entries
        if kind in kinds_of(path)
    ]
    return hashlib.sha256(
        b"".join(sorted(lines))
    ).hexdigest()  # sorted bytes, like LC_ALL=C sort


def vanilla_inputs(rev="HEAD"):
    """The hash of the default-image inputs at a revision (default HEAD).

    Returns a sha256 hex string; exits 1 through _inputs for an unknown revision.
    """
    return _inputs("vanilla", rev)


def dx_inputs(rev="HEAD"):
    """The hash of the dx inputs at a revision (default HEAD).

    Returns a sha256 hex string; exits 1 through _inputs for an unknown revision.
    """
    return _inputs("dx", rev)


def gx_inputs(rev="HEAD"):
    """The hash of the gx inputs at a revision (default HEAD).

    Returns a sha256 hex string; exits 1 through _inputs for an unknown revision.
    """
    return _inputs("gx", rev)


class NoImage(Exception):
    """No tested image covers the commit (walk ended, a default-image change lies
    between, no tag): the message says why.
    """


class Unreadable(Exception):
    """The registry could not be read while looking: never to be taken for "no image"."""


def lookup(tag: str) -> str:
    """The digest of `testing-<sha>` of the image named by $IMAGE. Raises
    registry.Absent or registry.ReadError.
    """
    return registry.digest(os.environ["IMAGE"], tag)


def nearest_image_for_inputs(tip: str, lookup_fn=None) -> tuple[str, str]:
    """Walk the first-parent history back from <tip> (itself included) and find the
    nearest commit that has a published image `testing-<short sha>` (lookup_fn(tag)
    returns the digest, raises registry.Absent or registry.ReadError; default:
    `lookup`). The walk stops, without a match, at the first commit whose vanilla_inputs
    differ from <tip>'s (a default-image change lies between). Returns (tag, digest);
    raises NoImage (with the reason) or Unreadable.
    """
    lookup_fn = lookup_fn or lookup
    maximum = int(os.environ.get("MAX_WALK") or 50)
    want = vanilla_inputs(tip)
    # walk the first-parent history from the tip, nearest commit first
    for n, c in enumerate(ci.git("rev-list", "--first-parent", tip).split()):
        # give up after MAX_WALK commits instead of walking the whole history
        if n > maximum:
            raise NoImage(f"no image within {maximum} commits")
        # a change to the default-image inputs means older images were built from other
        # content
        if vanilla_inputs(c) != want:
            raise NoImage(
                f"a default-image change lies between {tip} and the nearest commit with an image"
            )
        # git abbreviates by length: try the default and the 7-character form of the tag
        for sha in (
            ci.git("rev-parse", "--short", c),
            ci.git("rev-parse", "--short=7", c),
        ):
            # ask the registry for the image of this commit
            try:
                digest = lookup_fn(f"testing-{sha}")
            except registry.Absent:
                # the lookup contract: 3 = the tag does not exist (keep walking)
                continue
            except registry.ReadError as e:
                # anything else = the registry could not be read: that is an ERROR,
                # never "no image"
                raise Unreadable(
                    f"could not read the registry while looking for testing-{sha} ({e}): not treating that as a missing image"
                )
            # a digest means the tag exists and points at an image
            if digest:
                return f"testing-{sha}", digest
    raise NoImage("no testing image found")


def main(argv=None):
    """Print the input hash of one kind.

    Receives the kind (vanilla, dx or gx) and an optional revision (default HEAD);
    writes the sha256 as the result. Returns 0; an unknown revision exits 1.
    """
    ap = ci.arg_parser(__doc__)
    ap.add_argument("kind", choices=["vanilla", "dx", "gx"])
    ap.add_argument("rev", nargs="?", default="HEAD")
    args = ap.parse_args(argv)
    ci.result(_inputs(args.kind, args.rev))
    return 0


# run as a script, not when imported by a test
if __name__ == "__main__":
    sys.exit(main())
