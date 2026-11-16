#!/usr/bin/env bash
# The one real-writer-to-real-reader check of the binaries pipeline: the results binaries-decide.sh writes go through binaries-assemble.sh, and the COMPONENTS file it
# writes goes through the actual read loop of the assemble step in binaries.yml (every component's digest must reach cosign). Nothing is pulled or built.
# Needs: bash, python3 with PyYAML, jq. Run: tests/binaries-decide.sh
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
root=$(mktemp -d)
trap 'rm -rf -- "$root"' EXIT
pass=0; failn=0; rc=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { failn=$((failn + 1)); echo "FAIL $1"; [ -f "$root/run" ] && sed 's/^/     run: /' "$root/run"; }
check() { local d=$1; shift; if "$@" >"$root/out" 2>&1; then ok "$d"; else bad "$d"; fi; }
mkdir -p "$root/res2"
printf 'scx\nextest\nghostty\n' >"$root/comps.tsv"
D1=sha256:$(printf '1%.0s' {1..64}); D2=sha256:$(printf '2%.0s' {1..64}); D3=sha256:$(printf '3%.0s' {1..64})
K1=$(printf '1%.0s' {1..40}); K2=$(printf '2%.0s' {1..40}); K3=$(printf '3%.0s' {1..40})
# the result of a component, made by the REAL writer (binaries-decide.sh): res <name> built|reused|failed|validated <digest> <key>
res() {
    local e=(COMPONENT="$1" CHECK=success USABLE=false CHECK_DIGEST= KEY="$4" BUILD=success BUILD_OK=true PUBLISHED=true SIGN=success SIGN_DIGEST="$3" RESULT_DIR="$root/res2")
    case "$2" in
        reused) e+=(USABLE=true CHECK_DIGEST="$3") ;;
        failed) e+=(BUILD_OK=false) ;;
        validated) e+=(PUBLISHED=false SIGN=skipped) ;;
    esac
    env "${e[@]}" bash "$here/.github/scripts/binaries-decide.sh" >/dev/null 2>&1 || true
}
asm() { : >"$root/gho"; env GITHUB_OUTPUT="$root/gho" bash "$here/.github/scripts/binaries-assemble.sh" "$root/comps.tsv" "$root/res2" "$root/out2" >"$root/run" 2>&1; rc=$?; }
rm -f "$root/res2"/*; res scx built $D1 $K1 ""; res extest reused $D2 $K2 ""; res ghostty built $D3 $K3 ""
asm
# the REAL COMPONENTS (binaries-assemble.sh above) through the REAL read loop of the assemble step in binaries.yml: it must hand every component's digest to cosign
python3 -I - "$here" "$root" <<'PY'
import sys, yaml
here, root = sys.argv[1:3]
w = yaml.safe_load(open(f"{here}/.github/workflows/binaries.yml"))
run = [s for s in w["jobs"]["assemble"]["steps"] if s.get("id") == "assemble"][0]["run"]
open(f"{root}/assemble-loop.sh", "w").write(run.split("binaries/lib/assemble.sh")[0])
PY
mkdir -p "$root/loopimg"; cp "$root/out2/COMPONENTS" "$root/loopimg/COMPONENTS"
check "assemble step: the read loop of binaries.yml gets the digest of every component from the real COMPONENTS file" bash -c "cosign() { echo \"\$@\" >> '$root/cosign.log'; }; podman() { case \$1 in create) echo id ;; esac; }; tar() { :; }; export -f cosign podman tar; RUNNER_TEMP='$root/loopimg-tmp'; mkdir -p \$RUNNER_TEMP; cd '$root'; IMAGE=img RUNNER_TEMP='$root' bash -c 'mkdir -p image; cp loopimg/COMPONENTS image/COMPONENTS; . ./assemble-loop.sh' && [ \$(wc -l < '$root/cosign.log') = 3 ] && grep -q '@$D1' '$root/cosign.log' && grep -q '@$D3' '$root/cosign.log'"

echo
echo "passed: $pass, failed: $failn"
[ "$failn" = 0 ]
