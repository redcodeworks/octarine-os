#!/usr/bin/env python3
"""The test groups of the `suite` matrix: one group per directory under tests/ (the
directory tree is the only list). Prints the groups as a JSON array on stdout and, with
GITHUB_OUTPUT set, as `groups=<json>`. (tests/py, the pytest suite of the CI scripts, is
not a group: it has its own job.) Fails when a tests/*.sh sits outside a group (it would
never run) or a group directory has no *.sh. Run from anywhere: `python3 -I
.github/scripts/10-plan/plan_tests.py`.
"""

import json
import sys
from pathlib import Path

here = Path(__file__).resolve().parent
sys.path[:0] = [str(here.parent / "00-lib"), str(here)]
import ci  # noqa: E402


def main(argv=None):
    """List the test groups (the directories of tests/ that hold *.sh) for the suite
    matrix.

    Returns 0 after writing the JSON list as the result and as the `groups` step
    output; returns 1, logging why, when a test sits outside a group, a group has no
    *.sh or no group exists.
    """
    ci.arg_parser(__doc__).parse_args(argv)
    tests = Path(__file__).resolve().parents[3] / "tests"
    # a *.sh directly under tests/ belongs to no group
    stray = sorted(p.name for p in tests.glob("*.sh"))

    # a stray test would never run, so fail
    if stray:
        ci.log.error(
            f"tests/{stray[0]} is outside a group: move it into a tests/<group>/ directory ({' '.join(stray)})"
        )
        return 1
    groups = []

    # every directory except tests/py is a group; tests/py has its own job
    for d in sorted(
        p for p in tests.iterdir() if p.is_dir() and p.name != "py"
    ):  # tests/py is the pytest suite: its own job, not a shell group
        # an empty group is a mistake
        if not list(d.glob("*.sh")):
            ci.log.error(f"the test group tests/{d.name} has no *.sh")
            return 1
        groups.append(d.name)

    # an empty list would make the matrix fail with a confusing message
    if not groups:
        ci.log.error("no test groups under tests/")
        return 1
    text = json.dumps(groups, separators=(",", ":"))
    ci.result(text)
    ci.append_to("GITHUB_OUTPUT", f"groups={text}")
    return 0


# run as a script, not when imported by a test
if __name__ == "__main__":
    sys.exit(main())
