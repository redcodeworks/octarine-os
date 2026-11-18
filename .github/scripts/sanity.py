#!/usr/bin/env python3
"""The fast sanity check (first step of the required `test` job, about 10 s): only the cheapest obvious things. Every shell script parses (`bash -n`), every Python file compiles, and
every workflow file is valid YAML (a broken one gives a "workflow file issue" with no job and no useful message). Everything else shows where it matters: the behavior tests are the
separate `suite` job, and the image build fails in the step that needs a file or a config. Run from the repository root. The .archive/ folder (the kept shell originals) is skipped.
"""
import glob
import subprocess
import sys
from pathlib import Path

import yaml

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ci  # noqa: E402


def tracked(*patterns):
    out = subprocess.run(["git", "ls-files", *patterns], stdout=subprocess.PIPE, text=True, check=True).stdout
    return [f for f in out.splitlines() if not f.startswith(".archive/")]


def main():
    failed = False
    for f in tracked("*.sh", "githooks/pre-push"):
        if subprocess.run(["bash", "-n", f]).returncode != 0:
            print(f"FAIL: bash -n {f}")
            failed = True
    for f in tracked("*.py"):
        try:
            compile(Path(f).read_text(), f, "exec")
        except SyntaxError as e:
            print(f"FAIL: {f} does not compile: {e}")
            failed = True
    for f in sorted(glob.glob(".github/workflows/*.yml")):
        try:
            yaml.safe_load(Path(f).read_text())
        except yaml.YAMLError as e:
            print(f"FAIL: {f} does not parse: {e}")
            failed = True
            break  # the shell version stopped at the first broken file
    if not failed:
        print("sanity: all checks passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
