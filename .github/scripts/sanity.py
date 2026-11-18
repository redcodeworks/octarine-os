#!/usr/bin/env python3
"""The fast sanity check (first step of the required `test` job, about 10 s): only the cheapest obvious things. Every shell script parses (`bash -n`), every Python file compiles, and
every workflow file is valid YAML (a broken one gives a "workflow file issue" with no job and no useful message). Everything else shows where it matters: the behavior tests are the
separate `suite` job, and the image build fails in the step that needs a file or a config. Run from the repository root. The .archive/ folder (the kept shell originals) is skipped.
"""

import sys
from pathlib import Path

import yaml

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ci  # noqa: E402

ARCHIVE = ".archive/"  # the kept shell scripts: inert, never checked as live code


def tracked(*patterns):
    return [f for f in ci.git("ls-files", *patterns).splitlines() if not f.startswith(ARCHIVE)]


def bad_shell(f):
    return [f"bash -n {f}"] if ci.run(["bash", "-n", f]).returncode != 0 else []


def bad_python(f):
    try:
        compile(Path(f).read_text(), f, "exec")
    except SyntaxError as e:
        return [f"{f} does not compile: {e}"]
    return []


def bad_workflow(f):
    try:
        yaml.safe_load(f.read_text())
    except yaml.YAMLError as e:
        return [f"{f} does not parse: {e}"]
    return []


def problems():
    checks = (
        *map(bad_shell, tracked("*.sh", "githooks/pre-push")),
        *map(bad_python, tracked("*.py")),
        *map(bad_workflow, sorted(Path(".github/workflows").glob("*.yml"))),
    )
    return [problem for found in checks for problem in found]


def main(argv=None):
    ci.arg_parser(__doc__).parse_args(argv)
    found = problems()
    for problem in found:
        ci.log.error(problem)
    if not found:
        ci.log.info("sanity: all checks passed")
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
