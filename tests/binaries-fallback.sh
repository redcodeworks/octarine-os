#!/usr/bin/env bash
# Tests for the fallback of the DAILY image build to the last good binaries image: the candidate checks (binaries-fallback.sh: signature,
# layout contract, this tree's installer), the decision in the result job of binaries.yml (run from the workflow's own script with
# every combination of build, sign, event), the wiring in build.yml, the plan-skip rule, the installer's FALLBACK records, the label and
# the issue mechanics. Fake skopeo, cosign, podman and gh; nothing is pulled or built. Run: tests/binaries-fallback.sh
# Needs: bash, python3 with PyYAML, jq, tar.
# shellcheck disable=SC2016
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
root=$(mktemp -d)
trap 'rm -rf -- "$root"' EXIT
pass=0; failn=0; rc=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { failn=$((failn + 1)); echo "FAIL $1"; [ -f "$root/run" ] && sed 's/^/     run: /' "$root/run"; }
check() { local d=$1; shift; if "$@" >"$root/out" 2>&1; then ok "$d"; else bad "$d"; fi; }
IMG=ghcr.io/redcodeworks/octarine-os-binaries
H40=$(printf 'b%.0s' {1..40})
bin="$root/bin"; mkdir -p "$bin"

# ---- fixture: an exported binaries image that satisfies this tree's installer (real scheduler names from the real manifest)
mkfix() { # dir
    local d=$1 n
    rm -rf "$d"; mkdir -p "$d/scx/bin" "$d/scx/LICENSES" "$d/extest/lib" "$d/extest/lib64" "$d/extest/LICENSES" "$d/LICENSES"
    : >"$d/scx/schedulers.tsv"
    for n in $(grep -vE '^[[:space:]]*(#|$)' "$here/binaries/scx/schedulers.tsv" | cut -f1); do
        printf '#!/bin/sh\n' >"$d/scx/bin/$n"; chmod +x "$d/scx/bin/$n"
        printf '%s\tbin/%s\t\tdescription\n' "$n" "$n" >>"$d/scx/schedulers.tsv"
    done
    printf '                    GNU GENERAL PUBLIC LICENSE\n' >"$d/scx/LICENSES/scx-LICENSE"
    printf 'MIT License\n' >"$d/extest/LICENSES/extest-LICENSE"
    echo 32 >"$d/extest/lib/libextest.so"; echo 64 >"$d/extest/lib64/libextest.so"
    for c in scx extest; do echo src >"$d/$c/SOURCE"; echo build >"$d/$c/BUILDINFO"; done
    cp "$d/scx/LICENSES/scx-LICENSE" "$d/extest/LICENSES/extest-LICENSE" "$d/LICENSES/"; echo src >"$d/SOURCE"; echo build >"$d/BUILDINFO"
}
fix="$root/fix"

cat >"$bin/skopeo" <<'F'
#!/usr/bin/env bash
echo "skopeo $*" >>"$LOG"
case "$2" in
    --raw) [ "${NO_TAG:-0}" = 1 ] && exit 1; printf 'manifest of %s' "${@: -1}" ;;
    --config) printf '{"config":{"Labels":{"org.opencontainers.image.version":"%s","org.opencontainers.image.created":"2026-11-10T04:00:00Z"}}}' "$CAND_HASH" ;;
esac
F
cat >"$bin/cosign" <<'F'
#!/usr/bin/env bash
echo "cosign $*" >>"$LOG"
exit "${COSIGN_RC:-0}"
F
cat >"$bin/podman" <<'F'
#!/usr/bin/env bash
echo "podman $*" >>"$LOG"
case "$1" in
    create) echo cid ;;
    export) tar -C "$FIX" -c . ;;
    rm) ;;
esac
F
chmod +x "$bin"/*
export LOG="$root/log" CAND_HASH="$H40"
echo key >"$root/cosign.pub"
gawk_tsv="$here/binaries/scx/schedulers.tsv"
fb() { : >"$LOG"; : >"$root/gho"; env "$@" FIX="$fix" PATH="$bin:$PATH" COSIGN_KEY_FILE="$root/cosign.pub" GITHUB_OUTPUT="$root/gho" bash "$here/.github/scripts/binaries-fallback.sh" "$IMG" last-good "$gawk_tsv" "$here/build_files/install-binaries.sh" >"$root/run" 2>&1; rc=$?; }

mkfix "$fix"; fb X=1
want="sha256:$(printf 'manifest of docker://%s:last-good' "$IMG" | sha256sum | sed 's/ .*//')"
check "fallback: a signed candidate with the full layout passes; outputs its digest, tree hash, created date and tag" bash -c "[ $rc = 0 ] && grep -qx 'digest=$want' '$root/gho' && grep -qx 'hash=$H40' '$root/gho' && grep -qx 'created=2026-11-10T04:00:00Z' '$root/gho' && grep -qx 'tag=last-good' '$root/gho'"
check "fallback: the signature is verified against the repo key by DIGEST, before the image is pulled" bash -c "grep -q 'cosign verify --key $root/cosign.pub $IMG@$want' '$LOG' && [ \$(grep -n '^cosign' '$LOG' | head -1 | cut -d: -f1) -lt \$(grep -n '^podman create' '$LOG' | head -1 | cut -d: -f1) ]"
fb COSIGN_RC=1
check "fallback: a signature that does not verify is REFUSED (exit 1), nothing is pulled" bash -c "[ $rc = 1 ] && grep -q 'does not verify' '$root/run' && ! grep -q '^podman' '$LOG' && ! grep -q '^digest=' '$root/gho'"
fb NO_TAG=1
check "fallback: no last-good tag yet: refused" bash -c "[ $rc = 1 ] && grep -q 'does not exist' '$root/run'"
mkfix "$fix"; rm "$fix/scx/bin/scx_p2dq"; fb X=1
check "fallback: a candidate without a scheduler of this tree's manifest fails the layout contract and is named" bash -c "[ $rc = 1 ] && grep -q 'lacks scx/bin/scx_p2dq' '$root/run' && ! grep -q '^digest=' '$root/gho'"
mkfix "$fix"; rm -r "$fix/extest"; fb X=1
check "fallback: an older image without the extest component is refused (never ship without it)" bash -c "[ $rc = 1 ] && grep -q 'lacks extest/lib/libextest.so' '$root/run'"
mkfix "$fix"; rm "$fix/scx/LICENSES/scx-LICENSE" "$fix/LICENSES/scx-LICENSE"; fb X=1
check "fallback: a candidate the real installer would refuse (no GPL text) is refused" bash -c "[ $rc = 1 ]"
mkfix "$fix"; printf 'scx_rusty\tbin/scx_rusty\tonly three fields\n' >"$fix/scx/schedulers.tsv"; fb X=1
check "fallback: a manifest the installer cannot read is refused" bash -c "[ $rc = 1 ]"
mkfix "$fix"; fb CAND_HASH=zzz
check "fallback: a candidate without a readable tree hash label still passes, with hash=unknown (it is only recorded)" bash -c "[ $rc = 0 ] && grep -qx 'hash=unknown' '$root/gho'"

# ---- the decision: the result job of binaries.yml, run with each combination
python3 -I - "$here" "$root" <<'PY'
import sys, yaml
root, out = sys.argv[1], sys.argv[2]
w = yaml.safe_load(open(f"{root}/.github/workflows/binaries.yml"))
step = [s for s in w["jobs"]["result"]["steps"] if s.get("id") == "pick"][0]
open(f"{out}/pick.sh", "w").write(step["run"])
PY
pick() { : >"$root/gho"; : >"$root/sum"; env CHECK=success USABLE=false REUSE=skipped REUSE_DIGEST= BUILD=success PUBLISHED=true SIGN=success SIGN_DIGEST=sha256:$(printf 's%.0s' {1..1} | tr s 5)$(printf '5%.0s' {1..63}) FALLBACK=skipped FB_DIGEST=sha256:$(printf 'f%.0s' {1..64}) FB_HASH=$H40 FB_CREATED=2026-11-10T04:00:00Z FB_TAG=last-good EVENT=schedule "$@" GITHUB_OUTPUT="$root/gho" GITHUB_STEP_SUMMARY="$root/sum" bash "$root/pick.sh" >"$root/run" 2>&1; rc=$?; }
fbd=sha256:$(printf 'f%.0s' {1..64})
pick BUILD=failure SIGN=skipped FALLBACK=success
check "decision: scheduled, build failed, a compatible last good image: FALLBACK (exit 0, the fallback digest, action=fallback, fallback=true, tree and date handed on)" bash -c "[ $rc = 0 ] && grep -qx 'digest=$fbd' '$root/gho' && grep -qx 'action=fallback' '$root/gho' && grep -qx 'fallback=true' '$root/gho' && grep -qx 'fallback_hash=$H40' '$root/gho' && grep -qx 'fallback_created=2026-11-10T04:00:00Z' '$root/gho'"
check "decision: the summary says FALLBACK: using binaries image <digest> (tag, built <date>) because the binaries build failed, and the warning annotation is printed" bash -c "grep -q 'FALLBACK: using binaries image $fbd (last-good, tree $H40, built 2026-11-10T04:00:00Z) because the binaries build failed' '$root/sum' && grep -q '::warning::FALLBACK: using binaries image' '$root/run'"
pick BUILD=failure SIGN=skipped FALLBACK=skipped EVENT=push
check "decision: a build failure on any other event (push, pull request, promotion) fails closed: no fallback job ran" bash -c "[ $rc = 1 ] && grep -q 'The binaries build failed' '$root/run' && ! grep -q 'fallback=true' '$root/gho'"
pick BUILD=failure SIGN=skipped FALLBACK=skipped EVENT=schedule
check "decision: a scheduled build failure whose fallback job was skipped (not main, or no allow_fallback) fails" bash -c "[ $rc = 1 ] && grep -q 'The binaries build failed' '$root/run'"
pick BUILD=success PUBLISHED=true SIGN=failure FALLBACK=success
check "decision: the new image could not be SIGNED: fails, even with a fallback available (only a failed build may fall back)" bash -c "[ $rc = 1 ] && grep -q 'Signing the binaries image failed' '$root/run' && ! grep -q 'fallback=true' '$root/gho'"
pick BUILD=failure SIGN=skipped FALLBACK=failure
check "decision: the fallback was refused (signature or layout): the run fails, nothing is built" bash -c "[ $rc = 1 ] && grep -q 'last good image was refused' '$root/run'"
pick CHECK=failure BUILD=skipped FALLBACK=skipped
check "decision: a failed lookup fails closed" bash -c "[ $rc = 1 ] && grep -q 'The lookup of the binaries image failed' '$root/run'"
pick BUILD=failure SIGN=skipped FALLBACK=success EVENT=workflow_dispatch
check "decision: a dispatch rehearsal reports the fallback but publishes nothing (empty digest, action=validated, no fallback=true)" bash -c "[ $rc = 0 ] && grep -qx 'digest=' '$root/gho' && grep -qx 'action=validated' '$root/gho' && ! grep -qx 'fallback=true' '$root/gho' && grep -q 'FALLBACK (dry run)' '$root/sum'"
pick USABLE=true REUSE=success REUSE_DIGEST=sha256:$(printf '1%.0s' {1..64}) BUILD=skipped SIGN=skipped
check "decision: the reuse path is unchanged (action=reused, fallback=false)" bash -c "[ $rc = 0 ] && grep -qx 'action=reused' '$root/gho'"
pick
check "decision: a built and signed image is unchanged (action=built, fallback=false)" bash -c "[ $rc = 0 ] && grep -qx 'action=built' '$root/gho' && grep -qx 'fallback=false' '$root/gho'"

# ---- the wiring
check "binaries.yml: the fallback job runs only after a failed BUILD, for the scheduled run on main (allow_fallback) or a dispatch dry run; the digest is verified by binaries-fallback.sh; names stay stable" python3 -I - "$here" <<'PY'
import sys, yaml
root = sys.argv[1]
w = yaml.safe_load(open(f"{root}/.github/workflows/binaries.yml"))
on = w.get(True) or w.get("on")
assert on["workflow_call"]["inputs"]["allow_fallback"]["default"] is False
assert set(on["workflow_dispatch"]["inputs"]) == {"simulate_build_failure", "fallback_dry_run"}
j = w["jobs"]["fallback"]
c = " ".join(j["if"].split())
for needle in ("needs.build.result == 'failure'", "needs.check.result == 'success'", "inputs.allow_fallback == true", "github.event_name == 'schedule'", "github.ref == 'refs/heads/main'", "github.event_name == 'workflow_dispatch' && inputs.fallback_dry_run == true"):
    assert needle in c, needle
assert "sign" not in j["needs"], "a failed signing must not reach the fallback"
assert "binaries-fallback.sh" in str(j["steps"]) and "last-good" in str(j["steps"])
assert w["jobs"]["check"]["name"] == "Look for the binaries image" and w["jobs"]["build"]["name"] == "Build the binaries image" and w["jobs"]["sign"]["name"] == "Sign the binaries image" and w["jobs"]["result"]["name"] == "Binaries image digest"
assert "fallback" in w["jobs"]["result"]["needs"]
t = w["jobs"]["track"]
assert t.get("continue-on-error") is True, "a failure of the tag move or the issue must not block an image build"
s = str(t["steps"])
assert "refs/heads/main" in s and "last-good" in s and "ci-failure-binaries" in s
assert "action == 'reused'" in s and "action == 'built'" in s and "action == 'fallback'" not in s, "last-good moves only after a signed build or reuse"
PY
check "build.yml: allow_fallback is true only for the schedule event; the calling job may write issues; the fallback is recorded for the image build and in the summary" python3 -I - "$here" <<'PY'
import sys, yaml
root = sys.argv[1]
w = yaml.safe_load(open(f"{root}/.github/workflows/build.yml"))
j = w["jobs"]["binaries"]
assert j["with"]["allow_fallback"] == "${{ github.event_name == 'schedule' }}"
assert j["permissions"]["issues"] == "write"
t = open(f"{root}/.github/workflows/build.yml").read()
for needle in ("FALLBACK: using binaries image", "BINARIES_FALLBACK_TREE=", "org.octarineos.binaries-fallback", "LATEST_FALLBACK="):
    assert needle in t, needle
b = yaml.safe_load(open(f"{root}/.github/workflows/build-beta.yml"))
assert "with" not in b["jobs"]["binaries"], "the beta build never falls back"
assert b["jobs"]["binaries"]["permissions"]["issues"] == "write"
PY
check "Justfile and Containerfile: a fallback build gets the label org.octarineos.binaries-fallback=true plus the tree, and the build arguments reach install-binaries.sh" bash -c "grep -q 'org.octarineos.binaries-fallback=true' '$here/Justfile' && grep -q 'org.octarineos.binaries-tree=' '$here/Justfile' && grep -qx 'ARG BINARIES_FALLBACK_TREE=\"\"' '$here/Containerfile' && grep -n 'ARG BINARIES_FALLBACK_TREE' '$here/Containerfile' | cut -d: -f1 | { read -r a; b=\$(grep -n '/ctx/build.sh' '$here/Containerfile' | cut -d: -f1); [ \$a -lt \$b ]; }"

# ---- plan-skip: an image built with the fallback binaries is never kept
out1=$(env EVENT=schedule REF=refs/heads/main BASE_NOW=sha256:a LATEST_BASE=sha256:a REPO_SAME=true LATEST_CREATED="$(date -u +%Y-%m-%dT%H:%M:%SZ)" SIGNED=true LATEST_FALLBACK= bash "$here/.github/scripts/plan-skip.sh")
out2=$(env EVENT=schedule REF=refs/heads/main BASE_NOW=sha256:a LATEST_BASE=sha256:a REPO_SAME=true LATEST_CREATED="$(date -u +%Y-%m-%dT%H:%M:%SZ)" SIGNED=true LATEST_FALLBACK=true bash "$here/.github/scripts/plan-skip.sh")
check "plan-skip: unchanged inputs and no fallback label: skipped; the same with the fallback label: build (the next daily run replaces a fallback image)" bash -c "[[ '$out1' == skipped* && '$out2' == build:*fallback* ]]"

# ---- the installer records a fallback in SOURCE, BUILDINFO and a FALLBACK file; a normal install has none
mkfix "$root/img"; mkdir -p "$root/img/scx" ; dest="$root/dest"
rm -rf "$dest"; BINARIES_ROOT="$root/img" DESTDIR="$dest" bash "$here/build_files/install-binaries.sh" >"$root/run" 2>&1; rc=$?
check "installer: a normal build writes no FALLBACK notice" bash -c "[ $rc = 0 ] && [ ! -e '$dest/usr/share/licenses/octarine-os-binaries/FALLBACK' ] && ! grep -rq FALLBACK '$dest/usr/share/licenses/octarine-os-binaries'"
rm -rf "$dest"; BINARIES_FALLBACK_TREE=$H40 BINARIES_FALLBACK_CREATED=2026-11-10T04:00:00Z BINARIES_ROOT="$root/img" DESTDIR="$dest" bash "$here/build_files/install-binaries.sh" >"$root/run" 2>&1; rc=$?
check "installer: a fallback build says in SOURCE and BUILDINFO of both components and in FALLBACK that the binaries are NOT from this commit's tree, and names the tree and date" bash -c "d='$dest/usr/share/licenses/octarine-os-binaries'; [ $rc = 0 ] && for c in scx extest; do grep -q 'NOT built from the binaries/ tree of this image' \$d/\$c/SOURCE && grep -q 'tree $H40' \$d/\$c/BUILDINFO || exit 1; done && grep -q '2026-11-10T04:00:00Z' \$d/FALLBACK"

# ---- the issue: one, labeled ci-failure-binaries, a comment per later failure, closed when the binaries are fine again
cat >"$bin/gh" <<'F'
#!/usr/bin/env bash
echo "gh $*" >>"$LOG"
case "$1 $2" in
    "issue list") if [ -n "${OPEN_ISSUE:-}" ]; then echo "$OPEN_ISSUE"; fi ;;
    *) exit 0 ;;
esac
F
chmod +x "$bin/gh"
iss() { : >"$LOG"; env GITHUB_REPOSITORY=redcodeworks/octarine-os SHA=$H40 RUN_URL=https://example.invalid/run/1 LABEL=ci-failure-binaries LABEL_DESC=desc ISSUE_TITLE=title ISSUE_BODY=body FAIL_COMMENT="failed again" RECOVER_COMMENT="fine again" "$@" PATH="$bin:$PATH" bash "$here/.github/scripts/ci-issue.sh" "$MODE" >"$root/run" 2>&1; rc=$?; }
MODE=fail iss X=1
check "issue: a fallback opens ONE issue with the label ci-failure-binaries (and creates the label)" bash -c "[ $rc = 0 ] && grep -q 'gh label create ci-failure-binaries' '$LOG' && grep -q 'gh issue create .*--label ci-failure-binaries' '$LOG' && ! grep -q 'issue comment' '$LOG'"
MODE=fail iss OPEN_ISSUE=7
check "issue: a later fallback comments on the open issue instead of opening another" bash -c "[ $rc = 0 ] && grep -q 'gh issue comment 7' '$LOG' && grep -q 'failed again' '$LOG' && ! grep -q 'issue create' '$LOG'"
MODE=recover iss OPEN_ISSUE=7
check "issue: when the binaries are fine again the issue gets a recovered comment and is closed" bash -c "[ $rc = 0 ] && grep -q 'gh issue comment 7' '$LOG' && grep -q 'recovered: fine again' '$LOG' && grep -q 'gh issue close 7' '$LOG'"
MODE=recover iss X=1
check "issue: nothing open, nothing to close" bash -c "[ $rc = 0 ] && ! grep -q 'issue close' '$LOG'"

echo
echo "passed: $pass, failed: $failn"
[ "$failn" = 0 ]
