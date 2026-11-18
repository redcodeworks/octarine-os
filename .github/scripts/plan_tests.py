#!/usr/bin/env python3
"""The test groups of the `suite` matrix: one group per directory under tests/ (the directory tree is the only list). Prints the groups as a JSON array on stdout and, with
GITHUB_OUTPUT set, as `groups=<json>`. (tests/py, the pytest suite of the CI scripts, is not a group: it has its own job.) Fails when a tests/*.sh sits outside a group (it would never run) or a group directory has no *.sh. Run from anywhere:
`python3 -I .github/scripts/plan_tests.py`.
"""

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ci  # noqa: E402


def main(argv=None):
    ci.arg_parser(__doc__).parse_args(argv)
    tests = Path(__file__).resolve().parents[2] / "tests"
    stray = sorted(p.name for p in tests.glob("*.sh"))
    if stray:
        ci.log.error(
            f"tests/{stray[0]} is outside a group: move it into a tests/<group>/ directory ({' '.join(stray)})"
        )
        return 1
    groups = []
    for d in sorted(
        p for p in tests.iterdir() if p.is_dir() and p.name != "py"
    ):  # tests/py is the pytest suite: its own job, not a shell group
        if not list(d.glob("*.sh")):
            ci.log.error(f"the test group tests/{d.name} has no *.sh")
            return 1
        groups.append(d.name)
    if not groups:
        ci.log.error("no test groups under tests/")
        return 1
    text = json.dumps(groups, separators=(",", ":"))
    ci.result(text)
    ci.append_to("GITHUB_OUTPUT", f"groups={text}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
