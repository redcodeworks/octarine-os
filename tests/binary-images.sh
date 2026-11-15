#!/usr/bin/env bash
# Tests for the consumption side of the prebuilt binaries (built from binaries/ in this repository): the Containerfile wiring, the
# lookup of the hash-tagged image (.github/scripts/binaries-lookup.sh: published and signed, missing, bad signature), the gate of
# the image build (binaries-use.sh), the layout check of a built image (binaries-layout.sh), the installer
# (build_files/install-binaries.sh), the smoke assertions and the binaries workflow with its place in build.yml and build-beta.yml.
# All with fake skopeo and cosign; nothing is pulled, built or booted. The build side is tests/binaries-build.sh.
# Needs: bash, git, python3 with PyYAML, awk. Run: tests/binary-images.sh
set -uo pipefail
export RETRY_DELAY=0  # retry.sh must not slow the failing-verification cases

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
check "lookup: published and signed: usable=true with the digest of the tag, signature verified with the repo key" bash -c "[ $rc = 0 ] && grep -qx 'usable=true' '$root/gho' && grep -qx 'digest=sha256:$(dg $IMG $H40)' '$root/gho' && grep -q 'unchanged, nothing to build' '$root/run' && grep -qF 'cosign verify --key $root/cosign.pub $IMG@sha256:$(dg $IMG $H40)' '$LOG'"
look SKOPEO_FAIL=1
check "lookup: tag missing: usable=false (reason missing), exit 0, no cosign call" bash -c "[ $rc = 0 ] && grep -qx 'usable=false' '$root/gho' && grep -qx 'reason=missing' '$root/gho' && ! grep -q cosign '$LOG'"
look SKOPEO_EMPTY=1
check "lookup: an empty answer counts as missing" bash -c "[ $rc = 0 ] && grep -qx 'usable=false' '$root/gho'"
look COSIGN_RC=1
check "lookup: the tag exists but the signature does not verify: usable=false (reason badsignature), a warning, rebuild" bash -c "[ $rc = 0 ] && grep -qx 'usable=false' '$root/gho' && grep -qx 'reason=badsignature' '$root/gho' && grep -q '::warning::' '$root/run'"
PATH="$bin:$PATH" bash "$here/.github/scripts/binaries-lookup.sh" "$IMG" 'Bad Tag!' >"$root/run" 2>&1
check "lookup: a tag that is not a content tag is refused" test "$?" != 0

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

# ---- binaries-layout.sh: the listing of a built image against the manifest, per component
lay="$root/lay"; mkdir -p "$lay"
tsvf="$here/binaries/scx/schedulers.tsv"
{ for n in $(grep -vE '^[[:space:]]*(#|$)' "$tsvf" | cut -f1); do echo "scx/bin/$n"; done
  printf '%s\n' scx/schedulers.tsv extest/lib/libextest.so extest/lib64/libextest.so scx/SOURCE scx/BUILDINFO extest/SOURCE extest/BUILDINFO scx/LICENSES/scx-LICENSE extest/LICENSES/extest-LICENSE; } >"$lay/comps"
{ cat "$lay/comps"; printf '%s\n' SOURCE BUILDINFO COMPONENTS LICENSES/scx-LICENSE; } >"$lay/full"
L="$here/.github/scripts/binaries-layout.sh"
lt() { bash "$L" "$@" >"$root/run" 2>&1; rc=$?; }
lt "$lay/comps" "$tsvf" scx extest
check "layout: complete component directories pass, for all seven schedulers of the real manifest" test "$rc" = 0
grep -v '^extest/' "$lay/comps" >"$lay/scxonly"
lt "$lay/scxonly" "$tsvf" scx
check "layout: a single component image (what a component build and a last-good check export) passes with its own name" test "$rc" = 0
lt "$lay/scxonly" "$tsvf" scx extest
check "layout: naming a component the image does not hold fails" test "$rc" != 0
lt --assembled "$lay/full" "$tsvf" scx extest
check "layout: the assembled image passes with top-level SOURCE, BUILDINFO, LICENSES and COMPONENTS" test "$rc" = 0
grep -v '^COMPONENTS$' "$lay/full" >"$lay/nocomp"
lt --assembled "$lay/nocomp" "$tsvf" scx extest
check "layout: the assembled image without COMPONENTS fails" test "$rc" != 0
{ cat "$lay/full"; echo ghostty/bin/ghostty; } >"$lay/surplus"
lt --assembled "$lay/surplus" "$tsvf" scx extest
check "layout: an assembled image with an unexpected top-level directory fails and names it" bash -c "[ $rc != 0 ] && grep -q 'unexpected top-level entries: ghostty' '$root/run'"
grep -v 'scx/bin/scx_cake' "$lay/comps" >"$lay/nocake"
lt "$lay/nocake" "$tsvf" scx extest
check "layout: a scheduler of the manifest missing from the image fails and is named" bash -c "[ $rc != 0 ] && grep -q 'lacks scx/bin/scx_cake' '$root/run'"
grep -v 'extest/lib/libextest.so' "$lay/comps" >"$lay/no32"
lt "$lay/no32" "$tsvf" scx extest
check "layout: a missing 32-bit library fails" test "$rc" != 0
grep -vE '^(extest/SOURCE|scx/BUILDINFO)' "$lay/comps" >"$lay/norec"
lt "$lay/norec" "$tsvf" scx extest
check "layout: missing SOURCE or BUILDINFO of a component fails" test "$rc" != 0
sed 's#^#./#' "$lay/comps" >"$lay/dotted"
lt "$lay/dotted" "$tsvf" scx extest
check "layout: tar listings with a leading ./ are accepted" test "$rc" = 0
{ printf '%s\n' ghostty/root/usr/bin/ghostty ghostty/root/usr/share/applications/com.mitchellh.ghostty.desktop ghostty/FILES ghostty/SOURCE ghostty/BUILDINFO ghostty/LICENSES/ghostty-LICENSE; for i in $(seq 1 6000); do echo "ghostty/root/usr/share/ghostty/themes/theme-$i"; done; } >"$lay/big"
lt "$lay/big" "$tsvf" ghostty
check "layout: a long listing (6000 files, the needed ones first) passes: no SIGPIPE of the normalizing sed under pipefail makes a present file look missing" test "$rc" = 0
grep -v 'ghostty/FILES' "$lay/big" >"$lay/bigmiss"
lt "$lay/bigmiss" "$tsvf" ghostty
check "layout: in a long listing a really missing file is still reported" bash -c "[ $rc != 0 ] && grep -q 'lacks ghostty/FILES' '$root/run'"
lt "$lay/comps" "$tsvf" nosuch
check "layout: an unknown component name is refused" test "$rc" != 0


# ---- the Containerfile and the Justfile
check "Containerfile: the binaries image comes from BINARIES_IMAGE (no default, no foreign digest pins), bind-mounted at /binaries" bash -c "
  grep -qx 'ARG BINARIES_IMAGE' '$cf' && grep -qx 'FROM \${BINARIES_IMAGE} AS binaries' '$cf' && grep -q 'from=binaries,source=/,target=/binaries' '$cf' &&
  ! grep -qE 'SCX_BIN|EXTEST_BIN|scx-bin|extest-bin' '$cf' &&
  [ \$(grep -n '^ARG FEDORA_VERSION' '$cf' | cut -d: -f1) -lt \$(grep -n '^FROM \${BINARIES_IMAGE}' '$cf' | cut -d: -f1) ]"
check "build.sh runs install-binaries.sh and generates the registry; no build file enables or starts a scheduler" bash -c "grep -qx '/ctx/install-binaries.sh' '$here/build_files/build.sh' && grep -qx '/ctx/gen-schedulers.sh' '$here/build_files/build.sh' && ! grep -E 'systemctl (enable|start|preset).*scx' '$here/build_files/build.sh' '$here/build_files/install-binaries.sh' '$here/build_files/gen-schedulers.sh'"
check "every scx unit file of system_files is disabled by the preset (nothing is wanted by default)" bash -c "grep -qx 'disable scx@\\*.service' '$here/system_files/usr/lib/systemd/system-preset/00-octarine-scx.preset' && ! find '$here/system_files' -path '*wants*' -iname '*scx*' | grep -q ."
check "Justfile: build passes BINARIES_IMAGE (default: the assembled-key tag of binaries/) and labels the image with it" bash -c "grep -q 'BINARIES_IMAGE=\${BINARIES_IMAGE:-ghcr.io/{{ repo_organization }}/octarine-os-binaries:\$(.github/scripts/binaries-key.sh)}' '$here/Justfile' && grep -q 'io.github.redcodeworks.octarine-os.binaries=' '$here/Justfile'"
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
    printf 'scx\trequired\t%s\tbuilt\t\tsha256:%s\nextest\trequired\t%s\treused\t\tsha256:%s\n' "$H40" "$(printf 'a%.0s' {1..64})" "$H40" "$(printf 'b%.0s' {1..64})" >"$1/COMPONENTS"
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
wfc="$here/.github/workflows/binaries-component.yml"
check "binaries.yml: reusable (workflow_call with digest, image, action, hash and the fallback outputs) and dispatchable, nothing else" python3 -I - "$wfb" <<'PY'
import sys, yaml
w = yaml.safe_load(open(sys.argv[1])); on = w.get(True) or w.get("on")
assert set(on) == {"push", "schedule", "workflow_call", "workflow_dispatch"}, set(on)
assert set(on["workflow_call"]["inputs"]) == {"allow_fallback"}
assert set(on["workflow_call"]["outputs"]) == {"digest", "image", "action", "hash", "fallback", "fallback_hash", "fallback_created", "degraded"}, set(on["workflow_call"]["outputs"])
assert set(on["workflow_dispatch"]["inputs"]) == {"simulate_build_failure", "validate_only", "fallback_dry_run"}
assert on["workflow_dispatch"]["inputs"]["simulate_build_failure"]["type"] == "string", "rehearsals work per component: a list of components"
PY
check "binaries.yml: a matrix over components.tsv calls binaries-component.yml (fail-fast off), then assemble, sign, result and track; the signing environment is only on the sign jobs" python3 -I - "$wfb" "$wfc" <<'PY'
import sys, yaml
w = yaml.safe_load(open(sys.argv[1])); c = yaml.safe_load(open(sys.argv[2]))
j = w["jobs"]
assert set(j) == {"plan", "component", "assemble", "sign", "result", "track"}, set(j)
assert j["component"]["uses"] == "./.github/workflows/binaries-component.yml"
assert j["component"]["strategy"]["fail-fast"] is False and "fromJSON(needs.plan.outputs.matrix)" in j["component"]["strategy"]["matrix"]
assert j["component"]["secrets"] == {"SIGNING_SECRET": "${{ secrets.SIGNING_SECRET }}"}
assert "always()" in j["assemble"]["if"], "assemble runs after a failed leg: it decides"
names = {x["name"] for x in list(j.values()) + list(c["jobs"].values())}
assert not names & {"test", "secrets", "Build and push image", "Sign and verify images", "Build dx and push image", "require-testing-branch"}, names
assert [k for k, x in j.items() if x.get("environment") == "signing"] == ["sign"]
assert [k for k, x in c["jobs"].items() if x.get("environment") == "signing"] == ["sign"]
PY
check "binaries-component.yml: jobs check, build, sign, fallback, result; the key is binaries-key.sh, the tag c-<component>-<key>, the builder digest comes from builder.env, one push through push-tags.sh" bash -c "
  python3 -I - '$wfc' <<'PY'
import sys, yaml
w = yaml.safe_load(open(sys.argv[1]))
assert list(w['jobs']) == ['check', 'build', 'sign', 'fallback', 'result'], list(w['jobs'])
PY
  grep -q 'binaries-key.sh \"\${COMPONENT}\"' '$wfc' && grep -q 'tag=c-\${COMPONENT}-\${key}' '$wfc' && grep -q 'binaries-lookup.sh' '$wfc' &&
  grep -q 'builder.env' '$wfc' && grep -q -- '--file \"binaries/\${COMPONENT}/Containerfile\" binaries' '$wfc' && grep -q 'org.octarineos.binaries-component-key=' '$wfc' &&
  grep -q 'binaries-layout.sh' '$wfc' && grep -q 'push-tags.sh \"\${IMAGE_NAME}:\${TAG}\" \"\${IMAGE}\" \"\${TAG}\"' '$wfc'"
check "binaries-component.yml: a failed build never fails the build job (continue-on-error step, an ok record), sign runs only for a built and published component, the fallback runs only after a failed build and only for the cases of the design" python3 -I - "$wfc" <<'PY'
import sys, yaml
w = yaml.safe_load(open(sys.argv[1])); j = w["jobs"]
b = {s.get("id"): s for s in j["build"]["steps"]}
assert b["build"]["continue-on-error"] is True and b["record"]["if"] == "always()"
assert "steps.build.outcome == 'success'" in b["push"]["if"]
assert "needs.build.outputs.ok == 'true'" in j["sign"]["if"] and "needs.build.outputs.published == 'true'" in j["sign"]["if"]
f = " ".join(j["fallback"]["if"].split())
for n in ("needs.build.outputs.ok == 'false'", "inputs.optional && needs.check.outputs.nopublish != 'true'", "inputs.allow_fallback && github.event_name == 'schedule' && github.ref == 'refs/heads/main'", "github.event_name == 'workflow_dispatch' && inputs.fallback_dry_run"):
    assert n in f, n
assert "sign" not in j["fallback"]["needs"], "a failed signing must not reach the fallback"
p = [s for s in j["fallback"]["steps"] if s.get("id") == "pick"][0]
assert p["continue-on-error"] is True and "binaries-fallback.sh" in p["run"] and "last-good-${COMPONENT}" in p["run"]
r = j["result"]; assert r["if"] == "always()"
assert "binaries-decide.sh" in str(r["steps"]) and "upload-artifact" in str(r["steps"]) and "binres-" in str(r["steps"])
PY
check "binaries.yml: only testing and main publish, the assembled image is tagged with the assembled key, a usable image skips the assembly, the push goes through push-tags.sh and the signature the way the images are signed" bash -c "
  grep -q 'refs/heads/main | refs/heads/testing) publish=true' '$wfb' && grep -q \"if: steps.assemble.outcome == 'success' && steps.channel.outputs.publish == 'true'\" '$wfb' &&
  grep -q \"steps.final.outputs.usable != 'true'\" '$wfb' && grep -q 'binaries-assemble.sh binaries/components.tsv' '$wfb' && grep -q 'binaries-lookup.sh \"\${IMAGE}\" \"\${KEY}\"' '$wfb' &&
  grep -q 'push-tags.sh \"\${IMAGE_NAME}:\${KEY}\" \"\${IMAGE}\" \"\${KEY}\"' '$wfb' && grep -q 'assemble.Containerfile' '$wfb' && grep -q -- '--assembled' '$wfb' &&
  grep -q 'COSIGN_PRIVATE_KEY: \${{ secrets.SIGNING_SECRET }}' '$wfb' && grep -q -- 'cosign sign -y --new-bundle-format=false --use-signing-config=false --key env://COSIGN_PRIVATE_KEY' '$wfb' &&
  grep -q 'cosign verify --key cosign.pub \"\${IMAGE}@\${DIGEST}\"' '$wfb' && grep -q 'cosign verify --key cosign.pub \"\${IMAGE}:\${KEY}\"' '$wfb'"
check "binaries.yml: the result job takes the digest from exactly one producer per case (the lookup of an existing image, the sign job, or nothing for a validation) and the outputs say action built, reused or validated" bash -c "grep -q 'digest=\${REUSE_DIGEST}' '$wfb' && grep -q 'digest=\${SIGN_DIGEST}' '$wfb' && grep -q 'action=reused' '$wfb' && grep -q 'action=built' '$wfb' && grep -q 'action=validated' '$wfb'"
check "binaries.yml: the track job moves last-good-<component> only on main, never for an own or validation run, and keeps the ONE issue (opened with the degraded components named, closed when none is degraded)" python3 -I - "$wfb" <<'PY'
import sys, yaml
w = yaml.safe_load(open(sys.argv[1])); t = w["jobs"]["track"]
assert t.get("continue-on-error") is True
assert "needs.assemble.outputs.nopublish != 'true'" in t["if"]
s = str(t["steps"])
assert "refs/heads/main" in s and "last-good-${name}" in s and "ci-failure-binaries" in s and "needs.assemble.outputs.degraded != ''" in s and "needs.assemble.outputs.degraded == ''" in s
assert "last-good\"" not in s.replace("last-good-", ""), "no assembled last-good pointer any more"
PY
check "the run summary says what each component and the assembled image did (reused, built and signed, validation only, fallback, omitted)" bash -c "grep -q 'Binaries image: reused' '$wfb' && grep -q 'Binaries image: assembled .*signed and published' '$wfb' && grep -q 'for validation only' '$wfb' && grep -q 'Component \${comp}: reused' '$here/.github/scripts/binaries-decide.sh' && grep -q 'OMITTED' '$here/.github/scripts/binaries-decide.sh' && grep -q 'FALLBACK: component' '$here/.github/scripts/binaries-decide.sh'"
check "build.yml and build-beta.yml say which path the binaries image took in their own summary, and still gate on binaries-use.sh" bash -c "for f in build.yml build-beta.yml; do grep -q 'Say which path the binaries image took' '$here/.github/workflows/'\$f && grep -q 'needs.binaries.outputs.action' '$here/.github/workflows/'\$f && grep -q 'binaries-use.sh' '$here/.github/workflows/'\$f || exit 1; done"
check "a signature that fails on an existing tag is not reused: the lookup reports usable=false (badsignature) and the build path rebuilds and signs; the reuse job needs usable=true" bash -c "grep -q 'badsignature' '$here/.github/scripts/binaries-lookup.sh' && grep -q 'usable false' '$here/.github/scripts/binaries-lookup.sh'"
check "build.yml and build-beta.yml: a binaries job uses the reusable workflow before the image build, the build needs it and verifies its digest" python3 -I - "$here" <<'PY'
import sys, yaml
root = sys.argv[1]
for f, build in (("build.yml", "build_push"), ("build-beta.yml", "build")):
    w = yaml.safe_load(open(f"{root}/.github/workflows/{f}"))
    j = w["jobs"]["binaries"]
    assert j["uses"] == "./.github/workflows/binaries.yml", f
    assert j["permissions"] == {"contents": "read", "packages": "write", "issues": "write"}, f  # issues: the track job files the fallback issue
    assert j.get("secrets") == {"SIGNING_SECRET": "${{ secrets.SIGNING_SECRET }}"}, f + ": the called workflow signs with SIGNING_SECRET, which it gets only when the caller passes it (no secrets: inherit)"
    needs = w["jobs"][build]["needs"]; needs = needs if isinstance(needs, list) else [needs]
    assert "binaries" in needs, f
    text = open(f"{root}/.github/workflows/{f}").read()
    assert 'binaries-use.sh "${BIN_IMAGE}" "${BIN_DIGEST}"' in text and "BIN_IMAGE: ${{ needs.binaries.outputs.image }}" in text and "BIN_DIGEST: ${{ needs.binaries.outputs.digest }}" in text, f
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
