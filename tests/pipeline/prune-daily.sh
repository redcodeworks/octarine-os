#!/usr/bin/env bash
# Decision table of .github/scripts/prune-daily.py with a fixture list of package versions (no network, a fake gh):
# keep the newest 14 daily builds, never the bare latest, testing, other tags or untagged versions, protected digests, signature
# matching, the 30-version limit, dry run by default. Run: tests/pipeline/prune-daily.sh
set -uo pipefail
here=$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)
prune="$here/.github/scripts/prune-daily.py"
root=$(mktemp -d); trap 'rm -rf "$root"' EXIT
pass=0; failn=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { failn=$((failn + 1)); echo "FAIL $1"; sed 's/^/     /' "$root/out"; }

# gen N [python run with `vs`, v(id, k, day, tags), sig(id, k)]: N daily builds k=1..N (id 100+k, digest = k in hex, day k), oldest first
gen() {
    python3 -I - "$1" "${2:-}" <<'PY'
import json, sys
n, extra = int(sys.argv[1]), sys.argv[2]
def dg(k): return format(k, "064x")
def v(i, k, day, tags): return {"id": i, "name": "sha256:" + dg(k), "created_at": f"2026-01-{day:02d}T11:00:00Z", "metadata": {"container": {"tags": tags}}}
def sig(i, k): return v(i, 900 + k, 1, ["sha256-" + dg(k) + ".sig"])
vs = []
for k in range(1, n + 1):
    day = k if k <= 28 else 28
    d = f"202601{day:02d}"
    vs.append(v(100 + k, k, day, [f"daily-{d}", f"latest-{d}-abcdef{k % 10}", f"{d}-abcdef{k % 10}", d, f"latest-{d}"]))
    vs[-1]["created_at"] = f"2026-01-{day:02d}T{k % 24:02d}:00:00Z"
exec(extra)
print(json.dumps(vs))
PY
}
# run <env...>: json on stdin; sets rc; output in $root/out
run() { env DRY_RUN=true "$@" python3 -I "$prune" >"$root/out" 2>&1; rc=$?; }
ids() { grep -o 'DELETE image id=[0-9]*' "$root/out" | sed 's/.*=//' | sort -n | tr '\n' ' '; }
expect() { # description, then a condition as a command
    local d=$1; shift
    if "$@"; then ok "$d"; else bad "$d"; fi
}
deleted() { [[ "$(ids)" == "$1" ]]; }
has() { grep -q -- "$1" "$root/out"; }
hasnt() { ! grep -q -- "$1" "$root/out"; }
hex() { format=$(printf '%064x' "$1"); echo "sha256:${format}"; }

run < <(gen 14); expect "14 daily builds: nothing to prune" has "Nothing to prune"
run < <(gen 16); expect "16 daily builds: the 2 oldest (101 102) are planned, the newest 14 stay" deleted "101 102 "
expect "dry run is the default: the plan is printed and nothing is deleted" has "Dry run: 2 versions"
run < <(gen 16 "vs[0]['metadata']['container']['tags'].append('latest')"); expect "an old build that carries the bare latest is never deleted" deleted "102 "
run < <(gen 16 "vs[0]['metadata']['container']['tags'].append('testing-abc1234')"); expect "an old build that also carries a testing tag is never deleted" deleted "102 "
run < <(gen 16 "vs[0]['metadata']['container']['tags'].append('beta-20260101-abcdef0')"); expect "an old build with a beta or any other tag is never deleted" deleted "102 "
run < <(gen 16 "vs += [v(900, 50, 1, ['testing-1111111', 'testing']), v(901, 51, 1, []), v(902, 52, 1, ['latest-20260101-abcdef0'])]")
expect "testing builds, untagged versions and dated aliases without a daily tag are never candidates" deleted "101 102 "
run PROTECT="$(hex 1)" < <(gen 16); expect "a protected digest (the dx latest's base) is kept; the next old build still goes" deleted "102 "
run < <(gen 16 "vs += [sig(501, 1), sig(502, 2), sig(503, 5)]")
expect "the signature of a deleted image goes with it" has "DELETE sig   id=501 "
expect "...and of the other deleted image; the signature of a kept image stays" bash -c "grep -q 'DELETE sig   id=502 ' '$root/out' && ! grep -q 'id=503 ' '$root/out'"
run < <(gen 14 "vs += [sig(701, 77)]"); expect "an orphan signature (no version of this package has that digest) is planned for deletion" has "DELETE sig   id=701 "
run < <(gen 14 "vs += [sig(702, 3)]"); expect "a signature whose image exists is kept" hasnt "id=702"
run < <(gen 50); expect "a plan over 30 versions is refused (exit 1), also as a dry run" bash -c "[ $rc = 1 ] && grep -q 'Refusing to delete 36' '$root/out'"
run DRY_RUN=false < <(gen 16); expect "live without API_BASE fails before deleting" bash -c "[ $rc = 1 ] && grep -q 'API_BASE is required' '$root/out'"
mkdir -p "$root/bin"; printf '#!/usr/bin/env bash\necho "gh $*" >>"%s/log"\n' "$root" >"$root/bin/gh"; chmod +x "$root/bin/gh"
run DRY_RUN=false API_BASE=users/o/packages/container/img PATH="$root/bin:$PATH" < <(gen 16 "vs += [sig(501, 1)]")
expect "live: one gh api -X DELETE per planned version (2 images and 1 signature)" bash -c "[ $rc = 0 ] && [ \$(grep -c 'gh api -X DELETE users/o/packages/container/img/versions/' '$root/log') = 3 ]"
run KEEP=10 < <(gen 16); expect "KEEP changes the count (10 kept, 6 deleted)" bash -c "[ \$(grep -c 'DELETE image' '$root/out') = 6 ]"

echo "passed: $pass, failed: $failn"
[ "$failn" = 0 ]
