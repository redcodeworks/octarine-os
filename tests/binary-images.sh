#!/usr/bin/env bash
# Tests for the consumption side of the prebuilt binaries (built from binaries/ in this repository): the Containerfile wiring, the
# lookup of the hash-tagged image (.github/scripts/binaries-lookup.sh: published and signed, missing, bad signature), the gate of
# the image build (binaries-use.sh), the layout check of a built image (binaries-layout.sh), the installer
# (build_files/install-binaries.sh), the smoke assertions and the binaries workflow with its place in build.yml and build-beta.yml.
# All with fake skopeo and cosign; nothing is pulled, built or booted. The build side is tests/binaries-build.sh.
# Needs: bash, git, python3 with PyYAML, awk. Run: tests/binary-images.sh
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
root=$(mktemp -d)
trap 'rm -rf -- "$root"' EXIT
pass=0
failn=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { failn=$((failn + 1)); echo "FAIL $1"; [ -f "$root/out" ] && sed 's/^/     /' "$root/out"; [ -f "$root/run" ] && sed 's/^/     run: /' "$root/run"; }
check() { local d=$1; shift; if "$@" >"$root/out" 2>&1; then ok "$d"; else bad "$d"; fi; }
cf="$here/Containerfile"

# ---- stubs
bin="$root/bin"; mkdir -p "$bin"
cat >"$bin/skopeo" <<'F'
#!/usr/bin/env bash
echo "skopeo $*" >>"$LOG"
case "$1" in
    inspect)
        [ "${SKOPEO_FAIL:-0}" = 1 ] && { echo "manifest unknown" >&2; exit 1; }
        [ "${SKOPEO_EMPTY:-0}" = 1 ] && exit 0
        printf 'manifest of %s' "${@: -1}" ;;
esac
F
cat >"$bin/cosign" <<'F'
#!/usr/bin/env bash
echo "cosign $*" >>"$LOG"
exit "${COSIGN_RC:-0}"
F
chmod +x "$bin"/*
export LOG="$root/log"
IMG=ghcr.io/redcodeworks/octarine-os-binaries
H40=$(printf 'a%.0s' {1..40})
dg() { printf 'manifest of docker://%s:%s' "$1" "$2" | sha256sum | sed 's/ .*//'; }
echo key >"$root/cosign.pub"

# ---- binaries-lookup.sh: the hash tag exists and is signed, or not
look() { : >"$LOG"; : >"$root/gho"; env "$@" PATH="$bin:$PATH" COSIGN_KEY_FILE="$root/cosign.pub" GITHUB_OUTPUT="$root/gho" bash "$here/.github/scripts/binaries-lookup.sh" "$IMG" "$H40" >"$root/run" 2>&1; rc=$?; }
look X=1
check "lookup: published and signed: usable=true with the digest of the tag, signature verified with the repo key" bash -c "[ $rc = 0 ] && grep -qx 'usable=true' '$root/gho' && grep -qx 'digest=sha256:$(dg $IMG $H40)' '$root/gho' && grep -q 'binaries unchanged, nothing to build' '$root/run' && grep -qF 'cosign verify --key $root/cosign.pub $IMG@sha256:$(dg $IMG $H40)' '$LOG'"
look SKOPEO_FAIL=1
check "lookup: tag missing: usable=false (reason missing), exit 0, no cosign call" bash -c "[ $rc = 0 ] && grep -qx 'usable=false' '$root/gho' && grep -qx 'reason=missing' '$root/gho' && ! grep -q cosign '$LOG'"
look SKOPEO_EMPTY=1
check "lookup: an empty answer counts as missing" bash -c "[ $rc = 0 ] && grep -qx 'usable=false' '$root/gho'"
look COSIGN_RC=1
check "lookup: the tag exists but the signature does not verify: usable=false (reason badsignature), a warning, rebuild" bash -c "[ $rc = 0 ] && grep -qx 'usable=false' '$root/gho' && grep -qx 'reason=badsignature' '$root/gho' && grep -q '::warning::' '$root/run'"
PATH="$bin:$PATH" bash "$here/.github/scripts/binaries-lookup.sh" "$IMG" notahash >"$root/run" 2>&1
check "lookup: a tag that is not a 40-hex tree hash is refused" test "$?" != 0

# ---- binaries-use.sh: the gate of the image build
use() { : >"$LOG"; : >"$root/genv"; env "$@" PATH="$bin:$PATH" COSIGN_KEY_FILE="$root/cosign.pub" GITHUB_ENV="$root/genv" bash "$here/.github/scripts/binaries-use.sh" "$IMG" "$DIGEST_ARG" >"$root/run" 2>&1; rc=$?; }
D=sha256:$(printf 'b%.0s' {1..64})
DIGEST_ARG=$D use X=1
check "use: a verified digest is logged and exported as BINARIES_IMAGE=<image>@<digest>" bash -c "[ $rc = 0 ] && grep -qx 'BINARIES_IMAGE=$IMG@$D' '$root/genv' && grep -q 'Binaries image used: $IMG@$D (signature valid)' '$root/run'"
DIGEST_ARG=$D use COSIGN_RC=1
check "use: a digest that does not verify fails the build and exports nothing" bash -c "[ $rc != 0 ] && [ ! -s '$root/genv' ]"
DIGEST_ARG="" use X=1
check "use: an empty digest (validation-only binaries) fails with the instruction to push through testing" bash -c "[ $rc != 0 ] && grep -q 'push the change to testing first' '$root/run' && ! grep -q cosign '$LOG'"
DIGEST_ARG="sha256:short" use X=1
check "use: a malformed digest fails" test "$rc" != 0

# ---- binaries-layout.sh: the listing of a built image against the manifest
lay="$root/lay"; mkdir -p "$lay"
tsvf="$here/binaries/scx/schedulers.tsv"
{ for n in $(grep -vE '^[[:space:]]*(#|$)' "$tsvf" | cut -f1); do echo "scx/bin/$n"; done
  printf '%s\n' scx/schedulers.tsv extest/lib/libextest.so extest/lib64/libextest.so scx/SOURCE scx/BUILDINFO extest/SOURCE extest/BUILDINFO SOURCE BUILDINFO LICENSES/scx-LICENSE scx/LICENSES/scx-LICENSE extest/LICENSES/extest-LICENSE; } >"$lay/full"
bash "$here/.github/scripts/binaries-layout.sh" "$lay/full" "$tsvf" >"$root/run" 2>&1
check "layout: a complete listing passes, for all seven schedulers of the real manifest" bash -c "[ $? = 0 ] || exit 1; true"
grep -v 'scx/bin/scx_cake' "$lay/full" >"$lay/nocake"
bash "$here/.github/scripts/binaries-layout.sh" "$lay/nocake" "$tsvf" >"$root/run" 2>&1
check "layout: a scheduler of the manifest missing from the image fails and is named" bash -c "[ $? != 0 ] && grep -q 'lacks scx/bin/scx_cake' '$root/run'"
grep -v 'extest/lib/libextest.so' "$lay/full" >"$lay/no32"
bash "$here/.github/scripts/binaries-layout.sh" "$lay/no32" "$tsvf" >"$root/run" 2>&1
check "layout: a missing 32-bit library fails" test "$?" != 0
grep -vE '^(SOURCE|BUILDINFO|LICENSES/)' "$lay/full" >"$lay/notop"
bash "$here/.github/scripts/binaries-layout.sh" "$lay/notop" "$tsvf" >"$root/run" 2>&1
check "layout: missing top-level SOURCE, BUILDINFO and LICENSES fail" test "$?" != 0
sed 's#^#./#' "$lay/full" >"$lay/dotted"
bash "$here/.github/scripts/binaries-layout.sh" "$lay/dotted" "$tsvf" >"$root/run" 2>&1
check "layout: tar listings with a leading ./ are accepted" test "$?" = 0


# ---- the Containerfile and the Justfile
check "Containerfile: the binaries image comes from BINARIES_IMAGE (no default, no foreign digest pins), bind-mounted at /binaries" bash -c "
  grep -qx 'ARG BINARIES_IMAGE' '$cf' && grep -qx 'FROM \${BINARIES_IMAGE} AS binaries' '$cf' && grep -q 'from=binaries,source=/,target=/binaries' '$cf' &&
  ! grep -qE 'SCX_BIN|EXTEST_BIN|scx-bin|extest-bin' '$cf' &&
  [ \$(grep -n '^ARG FEDORA_VERSION' '$cf' | cut -d: -f1) -lt \$(grep -n '^FROM \${BINARIES_IMAGE}' '$cf' | cut -d: -f1) ]"
check "build.sh runs install-binaries.sh and generates the registry; no build file enables or starts a scheduler" bash -c "grep -qx '/ctx/install-binaries.sh' '$here/build_files/build.sh' && grep -qx '/ctx/gen-schedulers.sh' '$here/build_files/build.sh' && ! grep -E 'systemctl (enable|start|preset).*scx' '$here/build_files/build.sh' '$here/build_files/install-binaries.sh' '$here/build_files/gen-schedulers.sh'"
check "every scx unit file of system_files is disabled by the preset (nothing is wanted by default)" bash -c "grep -qx 'disable scx@\\*.service' '$here/system_files/usr/lib/systemd/system-preset/00-octarine-scx.preset' && ! find '$here/system_files' -path '*wants*' -iname '*scx*' | grep -q ."
check "Justfile: build passes BINARIES_IMAGE (default: the tree-hash tag of binaries/) and labels the image with it" bash -c "grep -q 'BINARIES_IMAGE=\${BINARIES_IMAGE:-ghcr.io/{{ repo_organization }}/octarine-os-binaries:\$(git rev-parse HEAD:binaries)}' '$here/Justfile' && grep -q 'io.github.redcodeworks.octarine-os.binaries=' '$here/Justfile'"
check "the old foreign-image machinery is gone (pin check script, toolbox-key paragraph, foreign tests)" bash -c "! test -e '$here/.github/scripts/check-binary-pins.sh' && ! grep -rq 'check-binary-pins' '$here/.github' '$here/CLAUDE.md' && ! grep -q 'scx-bin' '$here/keys/README.md'"


# ---- install-binaries.sh against a fake binaries image
mk_images() { # dir
    rm -rf "$1"; mkdir -p "$1/scx/bin" "$1/scx/LICENSES" "$1/extest/lib" "$1/extest/lib64" "$1/extest/LICENSES"
    for n in scx_rusty scx_cake; do printf '#!/bin/sh\necho %s 1.1.4\n' "$n" >"$1/scx/bin/$n"; done
    # the third field (minimum kernel) is empty on purpose
    printf 'scx_rusty\tbin/scx_rusty\t\tHybrid scheduler\nscx_cake\tbin/scx_cake\t\tGaming scheduler\n' >"$1/scx/schedulers.tsv"
    printf '                    GNU GENERAL PUBLIC LICENSE\n' >"$1/scx/LICENSES/scx-LICENSE"
    printf 'MIT License\n' >"$1/extest/LICENSES/extest-LICENSE"
    echo 32 >"$1/extest/lib/libextest.so"; echo 64 >"$1/extest/lib64/libextest.so"
    for i in scx extest; do echo src >"$1/$i/SOURCE"; echo build >"$1/$i/BUILDINFO"; done
}
imgs="$root/imgs"; dest="$root/dest"
inst() { rm -rf "$dest"; (BINARIES_ROOT="$imgs" DESTDIR="$dest" bash "$here/build_files/install-binaries.sh") >"$root/run" 2>&1; rc=$?; }
mk_images "$imgs"; inst
check "install: schedulers in /usr/bin, executable" bash -c "[ $rc = 0 ] && test -x '$dest/usr/bin/scx_rusty' && test -x '$dest/usr/bin/scx_cake'"
check "install: manifest at /usr/share/octarine-os/schedulers.tsv, unchanged" cmp "$imgs/scx/schedulers.tsv" "$dest/usr/share/octarine-os/schedulers.tsv"
check "install: extest libraries under /usr/lib/extest/lib and lib64, executable, not swapped" bash -c "[ \"\$(cat '$dest/usr/lib/extest/lib/libextest.so')\" = 32 ] && [ \"\$(cat '$dest/usr/lib/extest/lib64/libextest.so')\" = 64 ] && test -x '$dest/usr/lib/extest/lib/libextest.so'"
check "install: licenses, source and build info under /usr/share/licenses/octarine-os-binaries/<name>" bash -c "d='$dest/usr/share/licenses/octarine-os-binaries'; test -s \$d/scx/scx-LICENSE && test -s \$d/scx/SOURCE && test -s \$d/scx/BUILDINFO && test -s \$d/extest/extest-LICENSE && test -s \$d/extest/SOURCE && test -s \$d/extest/BUILDINFO"
check "install: nothing under systemd paths" bash -c "! find '$dest' -path '*systemd*' | grep -q ."
mk_images "$imgs"; rm "$imgs/scx/bin/scx_cake"; inst
check "install: a scheduler listed but missing fails" bash -c "[ $rc != 0 ] && grep -q 'scx_cake is listed in schedulers.tsv but missing' '$root/run'"
mk_images "$imgs"; echo '#!/bin/sh' >"$imgs/scx/bin/scx_extra"; inst
check "install: a binary that is not in the manifest fails" bash -c "[ $rc != 0 ] && grep -q 'scx_extra is not listed' '$root/run'"
mk_images "$imgs"; printf 'scx_rusty\tbin/scx_rusty\tHybrid scheduler\n' >"$imgs/scx/schedulers.tsv"; inst
check "install: a manifest line with three fields (the empty one collapsed) fails" bash -c "[ $rc != 0 ] && grep -q 'must be name, bin/name' '$root/run'"
mk_images "$imgs"; rm "$imgs/scx/LICENSES/scx-LICENSE"; inst
check "install: no GPL text fails" bash -c "[ $rc != 0 ] && grep -q 'no GPL text' '$root/run'"
mk_images "$imgs"; rm "$imgs/extest/LICENSES/extest-LICENSE"; inst
check "install: no MIT text fails" bash -c "[ $rc != 0 ] && grep -q 'no MIT text' '$root/run'"
mk_images "$imgs"; rm "$imgs/extest/lib/libextest.so"; inst
check "install: a missing 32-bit library fails" test "$rc" != 0

# ---- the smoke assertions are in build.yml and build-beta.yml, identical
check "smoke: ldd, --version and ELF class assertions in both workflows, same text" python3 -I - "$here" <<'PY'
import re, sys
root = sys.argv[1]
blocks = []
for w in ("build.yml", "build-beta.yml"):
    s = open(f"{root}/.github/workflows/{w}").read()
    a = s.index("# prebuilt binaries (binaries/: scx, extest)")
    b = s.index("\n", s.index("source and build records ship for both binary images"))
    blocks.append(s[a:b])
assert blocks[0] == blocks[1], "the smoke assertions drifted between build.yml and build-beta.yml"
t = blocks[0]
for needle in ("--version", "ldd /usr/bin/", "not found", "ELF 32-bit", "ELF 64-bit", "/usr/lib/extest/lib/libextest.so",
               "/usr/lib/extest/lib64/libextest.so", "GNU GENERAL PUBLIC LICENSE", "MIT License", "schedulers.tsv"):
    assert needle in t, needle
assert "'" not in t, "a single quote would end the podman run bash -c string"
PY


# ---- the binaries workflow and its place in the image builds
wfb="$here/.github/workflows/binaries.yml"
check "binaries.yml: reusable (workflow_call with digest and image outputs) and dispatchable, nothing else" python3 -I - "$wfb" <<'PY'
import sys, yaml
w = yaml.safe_load(open(sys.argv[1])); on = w.get(True) or w.get("on")
assert set(on) == {"workflow_call", "workflow_dispatch"}, set(on)
assert set(on["workflow_call"]["outputs"]) == {"digest", "image", "action", "hash"}
PY
check "binaries.yml: no job carries a required check name; the signing job is the only one with the signing environment" python3 -I - "$wfb" <<'PY'
import sys, yaml
w = yaml.safe_load(open(sys.argv[1]))
names = {j["name"] for j in w["jobs"].values()}
assert not names & {"test", "secrets", "Build and push image", "Sign and verify images", "Build dx and push image", "require-testing-branch"}, names
assert [k for k, j in w["jobs"].items() if j.get("environment") == "signing"] == ["sign"]
PY
check "binaries.yml: only testing and main publish, any other ref builds for validation and never pushes or signs" bash -c "
  grep -q 'refs/heads/main | refs/heads/testing) publish=true' '$wfb' && grep -q \"if: steps.channel.outputs.publish == 'true'\" '$wfb' &&
  grep -q \"needs.build.outputs.published == 'true'\" '$wfb'"
check "binaries.yml: the tag is the tree hash of binaries/, a usable image skips the build, the build uses the pinned Containerfile and push-tags.sh" bash -c "
  grep -q 'git rev-parse HEAD:binaries' '$wfb' && grep -q \"needs.check.outputs.usable != 'true'\" '$wfb' && grep -q 'binaries-lookup.sh' '$wfb' &&
  grep -q -- '--file binaries/Containerfile binaries' '$wfb' && grep -q 'binaries-layout.sh' '$wfb' && grep -q 'push-tags.sh \"\${IMAGE_NAME}:\${HASH}\" \"\${IMAGE}\" \"\${HASH}\"' '$wfb'"
check "binaries.yml: signed the way the images are (same key and secret, old bundle format), then verified by digest and by tag" bash -c "
  grep -q 'COSIGN_PRIVATE_KEY: \${{ secrets.SIGNING_SECRET }}' '$wfb' && grep -q -- 'cosign sign -y --new-bundle-format=false --use-signing-config=false --key env://COSIGN_PRIVATE_KEY' '$wfb' &&
  grep -q 'cosign verify --key cosign.pub \"\${IMAGE}@\${DIGEST}\"' '$wfb' && grep -q 'cosign verify --key cosign.pub \"\${IMAGE}:\${HASH}\"' '$wfb'"
check "binaries.yml: the result job takes the digest from exactly one producer per case: the reuse job, the sign job, or nothing for a validation build" bash -c "grep -q 'digest=\${REUSE_DIGEST}' '$wfb' && grep -q 'digest=\${SIGN_DIGEST}' '$wfb' && grep -q 'digest=\" >> ' '$wfb' && ! grep -q 'CHECK_DIGEST' '$wfb' && ! grep -q 'BUILD_DIGEST' '$wfb'"
check "binaries.yml: a job named Reuse the binaries image runs only when the lookup found a signed image, the build runs only otherwise, and the build and sign jobs are skipped on reuse" python3 -I - "$wfb" <<'PY'
import sys, yaml
w = yaml.safe_load(open(sys.argv[1]))
j = w["jobs"]
assert j["reuse"]["name"] == "Reuse the binaries image"
assert j["reuse"]["if"] == "needs.check.outputs.usable == 'true'" and j["reuse"]["needs"] == "check"
assert j["build"]["if"] == "needs.check.outputs.usable != 'true'"
assert set(j["result"]["needs"]) == {"check", "reuse", "build", "sign"}
assert "reuse" not in j["build"]["needs"] and "reuse" not in j["sign"]["needs"]
PY
check "binaries.yml: the workflow outputs are digest, image, action (built, reused or validated) and hash" python3 -I - "$wfb" <<'PY'
import sys, yaml
w = yaml.safe_load(open(sys.argv[1])); on = w.get(True) or w.get("on")
assert set(on["workflow_call"]["outputs"]) == {"digest", "image", "action", "hash"}, set(on["workflow_call"]["outputs"])
t = open(sys.argv[1]).read()
for v in ("action=reused", "action=built", "action=validated"):
    assert v in t, v
PY
check "binaries.yml: each deciding job writes its line to the run summary (reused, built in Nm and signed, validation only)" bash -c "grep -q 'Binaries image: reused .*signature verified, no build' '$wfb' && grep -q 'Binaries image: built .* in \${minutes}m, signed and published' '$wfb' && grep -q 'for validation only' '$wfb' && [ \$(grep -c GITHUB_STEP_SUMMARY '$wfb') -ge 3 ]"
check "build.yml and build-beta.yml say which path the binaries image took in their own summary, and still gate on binaries-use.sh" bash -c "for f in build.yml build-beta.yml; do grep -q 'Say which path the binaries image took' '$here/.github/workflows/'\$f && grep -q 'needs.binaries.outputs.action' '$here/.github/workflows/'\$f && grep -q 'binaries-use.sh' '$here/.github/workflows/'\$f || exit 1; done"
check "a signature that fails on an existing tag is not reused: the lookup reports usable=false (badsignature) and the build path rebuilds and signs; the reuse job needs usable=true" bash -c "grep -q 'badsignature' '$here/.github/scripts/binaries-lookup.sh' && grep -q 'usable false' '$here/.github/scripts/binaries-lookup.sh'"
check "build.yml and build-beta.yml: a binaries job uses the reusable workflow before the image build, the build needs it and verifies its digest" python3 -I - "$here" <<'PY'
import sys, yaml
root = sys.argv[1]
for f, build in (("build.yml", "build_push"), ("build-beta.yml", "build")):
    w = yaml.safe_load(open(f"{root}/.github/workflows/{f}"))
    j = w["jobs"]["binaries"]
    assert j["uses"] == "./.github/workflows/binaries.yml", f
    assert j["permissions"] == {"contents": "read", "packages": "write"}, f
    assert j.get("secrets") == "inherit", f + ": the called workflow signs with SIGNING_SECRET, which it only gets through secrets: inherit"
    needs = w["jobs"][build]["needs"]; needs = needs if isinstance(needs, list) else [needs]
    assert "binaries" in needs, f
    text = open(f"{root}/.github/workflows/{f}").read()
    assert 'binaries-use.sh "${{ needs.binaries.outputs.image }}" "${{ needs.binaries.outputs.digest }}"' in text, f
    assert "check-binary-pins" not in text, f
    if f == "build.yml":
        assert j["if"] == "needs.plan.outputs.build == 'true'", "binaries only when an image is built (not for a promotion or a docs-only push)"
PY
check "build.yml: the required aggregate checks keep their names and the binaries job is not among their needs" python3 -I - "$here" <<'PY'
import sys, yaml
w = yaml.safe_load(open(sys.argv[1] + "/.github/workflows/build.yml"))
assert w["jobs"]["build_result"]["name"] == "Build and push image"
assert w["jobs"]["sign"]["name"] == "Sign and verify images"
assert "binaries" not in w["jobs"]["build_result"]["needs"] and "binaries" not in w["jobs"]["sign"]["needs"]
assert "pull_request" not in (w.get(True) or w.get("on"))
PY

echo
echo "passed: $pass, failed: $failn"
[ "$failn" = 0 ]
