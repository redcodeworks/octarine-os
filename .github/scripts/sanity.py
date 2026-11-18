#!/usr/bin/env python3
"""The fast sanity check (first step of the required `test` job, about 10 s): only the
cheapest obvious things. Every shell script parses (`bash -n`), every Python file
compiles, and every workflow file is valid YAML (a broken one gives a "workflow file
issue" with no job and no useful message). Everything else shows where it matters: the
behavior tests are the separate `suite` job, and the image build fails in the step that
needs a file or a config. Run from the repository root. The .archive/ folder (the kept
shell originals) is skipped.
"""

import sys
from pathlib import Path

import yaml

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ci  # noqa: E402

ARCHIVE = ".archive/"  # the kept shell scripts: inert, never checked as live code


def tracked(*patterns):
    """List the tracked files that match the patterns, leaving out the archived scripts.

    Receives git pathspecs; returns the file names.
    """
    # archived scripts are inert copies and are never checked as live code
    return [
        f
        for f in ci.git("ls-files", *patterns).splitlines()
        if not f.startswith(ARCHIVE)
    ]


def bad_shell(f):
    """Check a shell script with `bash -n`.

    Receives the file name; returns a list with one message when the syntax is
    wrong, else an empty list.
    """
    return [f"bash -n {f}"] if ci.run(["bash", "-n", f]).returncode != 0 else []


def bad_python(f):
    """Check that a Python file compiles.

    Receives the file name; returns a list with one message when it has a syntax
    error, else an empty list.
    """
    # a syntax error is the problem; any other error is a bug and should show
    try:
        compile(Path(f).read_text(), f, "exec")
    except SyntaxError as e:
        return [f"{f} does not compile: {e}"]
    return []


def bad_workflow(f):
    """Check that a workflow file parses as YAML.

    Receives the path; returns a list with one message when it does not parse, else
    an empty list.
    """
    # an unparsable workflow would fail every run that needs it
    try:
        yaml.safe_load(f.read_text())
    except yaml.YAMLError as e:
        return [f"{f} does not parse: {e}"]
    return []


def problems():
    """Run every check and collect the problems.

    Returns a flat list of messages (empty when everything is fine).
    """
    checks = (
        *map(bad_shell, tracked("*.sh", "githooks/pre-push")),
        *map(bad_python, tracked("*.py")),
        *map(bad_workflow, sorted(Path(".github/workflows").glob("*.yml"))),
    )
    # flatten the per-file lists of messages
    return [problem for found in checks for problem in found]


def main(argv=None):
    """Run the sanity checks that the image build would otherwise trip over.

    Checks the syntax of the tracked shell scripts and Python files and that each
    workflow file parses. Run from the repository root. Returns 0 when everything
    passes, 1 after logging every problem as an error.
    """
    ci.arg_parser(__doc__).parse_args(argv)
    found = problems()
    # one error annotation per problem
    for problem in found:
        ci.log.error(problem)
    # a clean run says so, so the log shows the check ran
    if not found:
        ci.log.info("sanity: all checks passed")
    return 1 if found else 0


# run as a script, not when imported by a test
if __name__ == "__main__":
    sys.exit(main())
