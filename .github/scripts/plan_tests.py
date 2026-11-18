#!/usr/bin/env python3
"""The test groups of the `suite` matrix: one group per directory under tests/ (the directory tree is the only list). Prints the groups as a JSON array on stdout and, with
GITHUB_OUTPUT set, as `groups=<json>`. Fails when a tests/*.sh sits outside a group (it would never run) or a group directory has no *.sh. Run from anywhere:
`python3 -I .github/scripts/plan_tests.py`.
"""
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ci  # noqa: E402


def main():
    tests = Path(__file__).resolve().parents[2] / "tests"
    stray = sorted(p.name for p in tests.glob("*.sh"))
    if stray:
        ci.fail(f"tests/{stray[0]} is outside a group: move it into a tests/<group>/ directory ({' '.join(stray)})")
    groups = []
    for d in sorted(p for p in tests.iterdir() if p.is_dir()):
        if not list(d.glob("*.sh")):
            ci.fail(f"the test group tests/{d.name} has no *.sh")
        groups.append(d.name)
    if not groups:
        ci.fail("no test groups under tests/")
    text = json.dumps(groups, separators=(",", ":"))
    print(text)
    ci.output("groups", text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
