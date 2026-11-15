#!/usr/bin/env bash
# Guard for the in-image smoke tests of the workflows (and any script with the same `check "<description>" "<command>"` helper): a call with the two
# strings joined (`check "a""b"`, a missing space) runs `eval` on nothing and passes vacuously (found 2026-11-15 in build.yml and build-beta.yml).
# Every line that starts with `check "` must hold exactly two shell words after `check` (description, command) when it is a complete one-line call.
# Run: tests/check-call-shape.sh
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
python3 -I - "$here" <<'PY'
import glob, re, shlex, sys
here = sys.argv[1]
files = glob.glob(here + "/.github/workflows/*.yml") + glob.glob(here + "/.github/scripts/*.sh")
bad, seen = [], 0
for f in files:
    for n, line in enumerate(open(f), 1):
        s = line.strip()
        if not s.startswith('check "'):
            continue
        seen += 1
        if re.match(r'check "[^"\\]*""', s):
            bad.append((f, n, "joined strings"))
            continue
        try:
            words = shlex.split(s, comments=False)
        except ValueError:
            continue  # a call that continues on the next line
        if len(words) != 3 and not s.endswith("\\"):
            bad.append((f, n, "%d words" % len(words)))
for b in bad:
    print("FAIL %s:%d %s" % (b[0].replace(here + "/", ""), b[1], b[2]))
print("%d check calls looked at, %d bad" % (seen, len(bad)))
sys.exit(1 if bad else 0)
PY
