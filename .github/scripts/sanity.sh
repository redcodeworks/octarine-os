#!/usr/bin/env bash
# The fast sanity check (the required `test` job of test.yml, about a minute at most): only the OBVIOUS. Syntax of every shell script, shellcheck at error
# severity, every YAML/JSON/TOML file parses, `just check`, and every literal repository path that the workflows, Containerfiles and Justfile mention exists.
# The behavior tests are the separate `suite` job (tests/*.sh via run-tests.sh); real image problems show in the image build. Run from the repository root.
set -uo pipefail
fail=0
bad() { echo "FAIL: $*"; fail=1; }

while IFS= read -r f; do bash -n "$f" || bad "bash -n $f"; done < <(git ls-files '*.sh' githooks/pre-push)
git ls-files '*.sh' githooks/pre-push | xargs shellcheck -S error || bad "shellcheck"

python3 -I - <<'PY' || bad "a YAML, JSON or TOML file does not parse"
import json, subprocess, sys, tomllib, yaml
for f in subprocess.check_output(["git", "ls-files"], text=True).split("\n"):
    try:
        if f.endswith((".yml", ".yaml")): yaml.safe_load(open(f))
        elif f.endswith(".json"): json.load(open(f))
        elif f.endswith(".toml"): tomllib.load(open(f, "rb"))
    except Exception as e:
        print("parse error in %s: %s" % (f, e)); sys.exit(1)
PY

just check > /dev/null || bad "just check (just --fmt --check)"

# literal paths only: a path built from a variable ($, {, *) is not checked
while IFS= read -r p; do
  [[ -e "$p" ]] || bad "mentioned but missing: $p"
done < <(git ls-files '.github/workflows/*.yml' 'Containerfile' 'variants/*/Containerfile' 'Justfile' |
  xargs grep -hoP '(?<![\w./-])(\.github/scripts|\.github/actions|tests|build_files|system_files|variants)/[\w./-]++(?![*\${}])' | sed 's#[./-]*$##' | sort -u)

[[ "$fail" = 0 ]] && echo "sanity: all checks passed"
exit "$fail"
