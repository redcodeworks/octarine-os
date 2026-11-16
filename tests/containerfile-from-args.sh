#!/usr/bin/env bash
# Guard: every variable used in a FROM line of any Containerfile must be declared by an ARG BEFORE the first FROM of that file.
# An ARG declared after a FROM belongs to that stage only and is EMPTY in a later FROM line (dx builds failed on testing with
# `datastore-images@: invalid reference format` for exactly that reason). Run: tests/containerfile-from-args.sh
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
python3 -I - "$here" <<'PY'
import os, re, sys
root = sys.argv[1]
files = []
for d, dirs, names in os.walk(root):
    dirs[:] = [x for x in dirs if x not in (".git", "node_modules")]
    files += [os.path.join(d, n) for n in names if n == "Containerfile" or n.startswith("Containerfile.")]
assert files, "no Containerfile found"
bad = []
for f in sorted(files):
    declared, seen_from = set(), False
    text = open(f).read().replace("\\\n", " ")
    for n, line in enumerate(text.split("\n"), 1):
        s = line.strip()
        if s.upper().startswith("FROM "):
            used = set(re.findall(r"\$\{(\w+)[^}]*\}", s)) | set(re.findall(r"\$(\w+)", s))
            missing = used - declared
            if missing:
                bad.append("%s: FROM line uses %s, not declared by an ARG before the first FROM: %s" % (os.path.relpath(f, root), sorted(missing), s))
            seen_from = True
        elif s.upper().startswith("ARG ") and not seen_from:
            declared.add(re.split(r"[= ]", s[4:].strip())[0])
for b in bad:
    print("FAIL " + b)
print("%d Containerfiles looked at, %d bad" % (len(files), len(bad)))
sys.exit(1 if bad else 0)
PY
