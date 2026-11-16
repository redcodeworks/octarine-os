#!/usr/bin/env bash
# Tests .github/scripts/binaries-arm.sh (last-good-<component> -> the signed c-<component>-<key> image of the current tree) with a stub skopeo registry (one file
# per tag) and a stub cosign. Run: tests/binaries-arm.sh
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
root=$(mktemp -d)
trap 'rm -rf -- "${root:?}"' EXIT
pass=0; failn=0; rc=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { failn=$((failn + 1)); echo "FAIL $1"; sed 's/^/     /' "$root/run" 2> /dev/null; echo "     rc=$rc"; }
check() { local d=$1; shift; if "$@" > "$root/out" 2>&1; then ok "$d"; else bad "$d"; fi; }
bin="$root/bin"; reg="$root/reg"; mkdir -p "$bin" "$reg"
cat > "$bin/skopeo" <<'F'
#!/usr/bin/env bash
echo "skopeo $*" >> "$LOG"
tagof() { local r=${1#docker://}; echo "${r##*:}"; }
case "$1" in
    inspect) f="$REG/$(tagof "${@: -1}")"; [[ -f "$f" ]] && cat "$f" || exit 1 ;;
    copy)
        src=${@: -2:1}; dst=${@: -1}; d=${src##*@sha256:}
        for f in "$REG"/*; do [[ "$(sha256sum < "$f" | cut -d' ' -f1)" == "$d" ]] && { [[ -z "${COPY_FAIL:-}" ]] || exit 1; cp "$f" "$REG/$(tagof "$dst")"; exit 0; }; done; exit 1 ;;
esac
F
cat > "$bin/cosign" <<'F'
#!/usr/bin/env bash
echo "cosign $*" >> "$LOG"
[[ -z "${BAD_SIG:-}" ]]
F
chmod +x "$bin"/*
export LOG="$root/log" REG="$reg" REPO_ROOT="$here"
img=ghcr.io/o/octarine-os-binaries
comps=$("$here/.github/scripts/binaries-key.sh" --components | tr '\n' ' ')
mk() { for c in $comps; do printf 'manifest of %s' "$c" > "$reg/c-$c-$("$here/.github/scripts/binaries-key.sh" "$c")"; done; }
run() { : > "$LOG"; (env "$@" PATH="$bin:$PATH" bash "$here/.github/scripts/binaries-arm.sh" "$img") > "$root/run" 2>&1; rc=$?; }
dg() { sha256sum < "$1" | cut -d' ' -f1; }
mk; run X=1
check "every component with a signed c-<component>-<key> image gets last-good-<component> pointing at exactly that digest" bash -c "[ $rc = 0 ] && for c in $comps; do k=\$('$here/.github/scripts/binaries-key.sh' \$c); [ \"\$(sha256sum < '$reg/last-good-'\$c | cut -d' ' -f1)\" = \"\$(sha256sum < '$reg/c-'\$c'-'\$k | cut -d' ' -f1)\" ] || exit 1; done"
check "the tag names are the ones the fallback reads (binaries-component.yml passes last-good-\${COMPONENT}) and the copy keeps the digest" bash -c "grep -q 'last-good-\${COMPONENT}' '$here/.github/workflows/binaries-component.yml' && grep -q 'preserve-digests' '$here/.github/scripts/binaries-arm.sh' && grep -q 'skopeo copy --all --preserve-digests' '$LOG'"
run X=1
check "a second run changes nothing (already armed: no copy)" bash -c "[ $rc = 0 ] && ! grep -q 'skopeo copy' '$LOG' && grep -q 'already is' '$root/run'"
rm -f "$reg"/last-good-*; run BAD_SIG=1
check "an image whose signature does not verify is NOT armed (warning, exit 0, no tag)" bash -c "[ $rc = 0 ] && ! ls '$reg'/last-good-* > /dev/null 2>&1 && grep -q '::warning::last-good-' '$root/run'"
rm -f "$reg"/c-ghostty-* "$reg"/last-good-*; run X=1
check "an optional component that was left out (no image) keeps no tag, the others are armed, exit 0" bash -c "[ $rc = 0 ] && [ ! -e '$reg/last-good-ghostty' ] && [ -e '$reg/last-good-scx' ] && [ -e '$reg/last-good-extest' ]"
rm -f "$reg"/last-good-*; run COPY_FAIL=1
check "a failed copy is a warning, not a failure of the promotion" bash -c "[ $rc = 0 ] && grep -q 'could not copy' '$root/run'"
check "build.yml: the promote job runs it after the retag, never fails the promotion (continue-on-error), and still has packages: write only" python3 -I - "$here" <<'PY'
import sys, yaml
w = yaml.safe_load(open(sys.argv[1] + "/.github/workflows/build.yml"))
j = w["jobs"]["promote"]
names = [s.get("name") for s in j["steps"]]
i = names.index("Retag the tested digest"); k = names.index("Arm the binaries fallback (last-good tags)")
assert i < k and j["steps"][k]["continue-on-error"] is True and "binaries-arm.sh" in j["steps"][k]["run"]
assert j["permissions"] == {"contents": "read", "packages": "write"}
PY
echo; echo "passed: $pass, failed: $failn"
[ "$failn" = 0 ]
