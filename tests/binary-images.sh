#!/usr/bin/env bash
# Tests for the prebuilt binary images (scx-bin, extest-bin from the fedora-toolbox repository): the pins in the
# Containerfile, the CI pin check (.github/scripts/check-binary-pins.sh), the installer (build_files/install-binaries.sh),
# the smoke assertions and the weekly bump workflow with its decision script (.github/scripts/bump-pin.sh), all with fake
# skopeo and cosign. Nothing is pulled, built or booted. Needs: bash, python3 with PyYAML, awk. Run: tests/binary-images.sh
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

# ---- the pins in the real Containerfile
for p in SCX_BIN EXTEST_BIN; do
    tag=$(sed -n "s/^ARG ${p}_TAG=//p" "$cf")
    dig=$(sed -n "s/^ARG ${p}_DIGEST=//p" "$cf")
    check "Containerfile: ${p}_TAG is a testing or latest tag with date and sha7 (or bare)" bash -c "printf '%s' '$tag' | grep -qE '^(latest|testing)(-[0-9]{8})?(-[0-9a-f]{7})?\$'"
    check "Containerfile: ${p}_DIGEST is sha256: plus 64 hex characters" bash -c "printf '%s' '$dig' | grep -qE '^sha256:[0-9a-f]{64}\$'"
done
check "Containerfile: both images are pulled by digest, as stages scxbin and extestbin, after the base ARGs" bash -c "
  grep -qx 'FROM ghcr.io/redcodeworks/scx-bin@\${SCX_BIN_DIGEST} AS scxbin' '$cf' &&
  grep -qx 'FROM ghcr.io/redcodeworks/extest-bin@\${EXTEST_BIN_DIGEST} AS extestbin' '$cf' &&
  [ \$(grep -n '^ARG FEDORA_VERSION' '$cf' | cut -d: -f1) -lt \$(grep -n '^FROM ghcr.io/redcodeworks/scx-bin' '$cf' | cut -d: -f1) ]"
check "Containerfile: the build step bind-mounts both images at /binaries/<name>" bash -c "grep -q 'from=scxbin,source=/,target=/binaries/scx-bin' '$cf' && grep -q 'from=extestbin,source=/,target=/binaries/extest-bin' '$cf'"
check "build.sh runs install-binaries.sh; nothing in them enables or starts a scheduler" bash -c "grep -qx '/ctx/install-binaries.sh' '$here/build_files/build.sh' && ! grep -qiE 'systemctl .*scx|scx.*(\.service|\.preset)' '$here/build_files/build.sh' '$here/build_files/install-binaries.sh'"
check "no scx unit or preset ships in system_files" bash -c "! find '$here/system_files' -iname '*scx*' | grep -q ."

# ---- stubs
bin="$root/bin"; mkdir -p "$bin"
cat >"$bin/skopeo" <<'F'
#!/usr/bin/env bash
echo "skopeo $*" >>"$LOG"
case "$1" in
    inspect)
        [ "${SKOPEO_FAIL:-0}" = 1 ] && { echo "unauthorized or unreachable" >&2; exit 1; }
        [ "${SKOPEO_EMPTY:-0}" = 1 ] && exit 0
        printf 'manifest of %s' "${@: -1}" ;;
    list-tags) echo "${TAGS_JSON:-{\"Tags\":[]}}" ;;
esac
F
cat >"$bin/cosign" <<'F'
#!/usr/bin/env bash
echo "cosign $*" >>"$LOG"
exit "${COSIGN_RC:-0}"
F
chmod +x "$bin"/*
export LOG="$root/log"
dg() { printf 'manifest of docker://ghcr.io/redcodeworks/%s:%s' "$1" "$2" | sha256sum | sed 's/ .*//'; }

# ---- check-binary-pins.sh
work="$root/pins"; mkdir -p "$work/keys"; echo key >"$work/keys/redcodeworks-toolbox-cosign.pub"
cp "$cf" "$work/Containerfile"
pins() { : >"$LOG"; (cd "$work" && PATH="$bin:$PATH" GITHUB_ENV="$root/env" bash "$here/.github/scripts/check-binary-pins.sh" "$@") >"$root/run" 2>&1; rc=$?; }
: >"$root/env"
pins
check "pin check, format only: passes on the real pins, no cosign call" bash -c "[ $rc = 0 ] && ! grep -q cosign '$LOG' && grep -q 'scx-bin pinned: ' '$root/run'"
pins --verify
check "pin check --verify: cosign verifies each pinned digest with the toolbox key" bash -c "[ $rc = 0 ] && [ \$(grep -c '^cosign verify --key keys/redcodeworks-toolbox-cosign.pub ghcr.io/redcodeworks/' '$LOG') = 2 ] && grep -q 'scx-bin@sha256:' '$LOG' && grep -q 'extest-bin@sha256:' '$LOG' && grep -q '(signature valid)' '$root/run'"
check "pin check exports the two references for the log and labels" bash -c "grep -q '^SCX_BIN_REF=ghcr.io/redcodeworks/scx-bin@sha256:' '$root/env' && grep -q '^EXTEST_BIN_REF=ghcr.io/redcodeworks/extest-bin@sha256:' '$root/env'"
COSIGN_RC=1 pins --verify
check "pin check --verify: a bad signature fails the build and names the reference" bash -c "[ $rc != 0 ] && grep -q 'cosign verification failed for ghcr.io/redcodeworks/scx-bin@sha256:' '$root/run'"
sed -i 's/^ARG SCX_BIN_DIGEST=sha256:\(.\{60\}\).*/ARG SCX_BIN_DIGEST=sha256:\1/' "$work/Containerfile"
pins
check "pin check: a digest that is not 64 hex characters fails" bash -c "[ $rc != 0 ] && grep -q 'SCX_BIN_DIGEST missing or not sha256' '$root/run'"
cp "$cf" "$work/Containerfile"; sed -i 's/^ARG EXTEST_BIN_TAG=.*/ARG EXTEST_BIN_TAG=v1.2/' "$work/Containerfile"
pins
check "pin check: a tag of the wrong shape fails" bash -c "[ $rc != 0 ] && grep -q 'EXTEST_BIN_TAG missing or not' '$root/run'"
cp "$cf" "$work/Containerfile"; sed -i '/^ARG SCX_BIN_TAG=/d' "$work/Containerfile"
pins
check "pin check: a missing tag line fails" test "$rc" != 0
for w in build.yml build-beta.yml; do
    check "$w: runs the pin check with --verify" grep -q '\.github/scripts/check-binary-pins.sh --verify' "$here/.github/workflows/$w"
done

# ---- install-binaries.sh against a fake pair of images
mk_images() { # dir
    rm -rf "$1"; mkdir -p "$1/scx-bin/bin" "$1/scx-bin/LICENSES" "$1/extest-bin/lib" "$1/extest-bin/lib64" "$1/extest-bin/LICENSES"
    for n in scx_rusty scx_cake; do printf '#!/bin/sh\necho %s 1.1.4\n' "$n" >"$1/scx-bin/bin/$n"; done
    # the third field (minimum kernel) is empty on purpose
    printf 'scx_rusty\tbin/scx_rusty\t\tHybrid scheduler\nscx_cake\tbin/scx_cake\t\tGaming scheduler\n' >"$1/scx-bin/schedulers.tsv"
    printf '                    GNU GENERAL PUBLIC LICENSE\n' >"$1/scx-bin/LICENSES/scx-LICENSE"
    printf 'MIT License\n' >"$1/extest-bin/LICENSES/extest-LICENSE"
    echo 32 >"$1/extest-bin/lib/libextest.so"; echo 64 >"$1/extest-bin/lib64/libextest.so"
    for i in scx-bin extest-bin; do echo src >"$1/$i/SOURCE"; echo build >"$1/$i/BUILDINFO"; done
}
imgs="$root/imgs"; dest="$root/dest"
inst() { rm -rf "$dest"; (BINARIES_ROOT="$imgs" DESTDIR="$dest" bash "$here/build_files/install-binaries.sh") >"$root/run" 2>&1; rc=$?; }
mk_images "$imgs"; inst
check "install: schedulers in /usr/bin, executable" bash -c "[ $rc = 0 ] && test -x '$dest/usr/bin/scx_rusty' && test -x '$dest/usr/bin/scx_cake'"
check "install: manifest at /usr/share/octarine-os/schedulers.tsv, unchanged" cmp "$imgs/scx-bin/schedulers.tsv" "$dest/usr/share/octarine-os/schedulers.tsv"
check "install: extest libraries under /usr/lib/extest/lib and lib64, executable, not swapped" bash -c "[ \"\$(cat '$dest/usr/lib/extest/lib/libextest.so')\" = 32 ] && [ \"\$(cat '$dest/usr/lib/extest/lib64/libextest.so')\" = 64 ] && test -x '$dest/usr/lib/extest/lib/libextest.so'"
check "install: licenses, source and build info under /usr/share/licenses/octarine-os-binaries/<image>" bash -c "d='$dest/usr/share/licenses/octarine-os-binaries'; test -s \$d/scx-bin/scx-LICENSE && test -s \$d/scx-bin/SOURCE && test -s \$d/scx-bin/BUILDINFO && test -s \$d/extest-bin/extest-LICENSE && test -s \$d/extest-bin/SOURCE && test -s \$d/extest-bin/BUILDINFO"
check "install: nothing under systemd paths" bash -c "! find '$dest' -path '*systemd*' | grep -q ."
mk_images "$imgs"; rm "$imgs/scx-bin/bin/scx_cake"; inst
check "install: a scheduler listed but missing fails" bash -c "[ $rc != 0 ] && grep -q 'scx_cake is listed in schedulers.tsv but missing' '$root/run'"
mk_images "$imgs"; echo '#!/bin/sh' >"$imgs/scx-bin/bin/scx_extra"; inst
check "install: a binary that is not in the manifest fails" bash -c "[ $rc != 0 ] && grep -q 'scx_extra is not listed' '$root/run'"
mk_images "$imgs"; printf 'scx_rusty\tbin/scx_rusty\tHybrid scheduler\n' >"$imgs/scx-bin/schedulers.tsv"; inst
check "install: a manifest line with three fields (the empty one collapsed) fails" bash -c "[ $rc != 0 ] && grep -q 'must be name, bin/name' '$root/run'"
mk_images "$imgs"; rm "$imgs/scx-bin/LICENSES/scx-LICENSE"; inst
check "install: no GPL text fails" bash -c "[ $rc != 0 ] && grep -q 'no GPL text' '$root/run'"
mk_images "$imgs"; rm "$imgs/extest-bin/LICENSES/extest-LICENSE"; inst
check "install: no MIT text fails" bash -c "[ $rc != 0 ] && grep -q 'no MIT text' '$root/run'"
mk_images "$imgs"; rm "$imgs/extest-bin/lib/libextest.so"; inst
check "install: a missing 32-bit library fails" test "$rc" != 0

# ---- the smoke assertions are in build.yml and build-beta.yml, identical
check "smoke: ldd, --version and ELF class assertions in both workflows, same text" python3 -I - "$here" <<'PY'
import re, sys
root = sys.argv[1]
blocks = []
for w in ("build.yml", "build-beta.yml"):
    s = open(f"{root}/.github/workflows/{w}").read()
    a = s.index("# prebuilt binaries (scx-bin, extest-bin)")
    b = s.index("\n", s.index("source and build records ship for both binary images"))
    blocks.append(s[a:b])
assert blocks[0] == blocks[1], "the smoke assertions drifted between build.yml and build-beta.yml"
t = blocks[0]
for needle in ("--version", "ldd /usr/bin/", "not found", "ELF 32-bit", "ELF 64-bit", "/usr/lib/extest/lib/libextest.so",
               "/usr/lib/extest/lib64/libextest.so", "GNU GENERAL PUBLIC LICENSE", "MIT License", "schedulers.tsv"):
    assert needle in t, needle
assert "'" not in t, "a single quote would end the podman run bash -c string"
PY

# ---- bump-pin.sh: the decision table
bw="$root/bump"; rm -rf "$bw"; mkdir -p "$bw/keys" "$bw/variants/dx"
echo key >"$bw/keys/redcodeworks-toolbox-cosign.pub"
reset_bump() { cp "$cf" "$bw/Containerfile"; cp "$here/variants/dx/Containerfile" "$bw/variants/dx/Containerfile"; : >"$LOG"; : >"$root/gho"; }
bump() { local img=$1; shift; (cd "$bw" && env "$@" PATH="$bin:$PATH" GITHUB_OUTPUT="$root/gho" bash "$here/.github/scripts/bump-pin.sh" "$img") >"$root/run" 2>&1; rc=$?; }
pin_digest() { sed -n "s/^ARG $2_DIGEST=//p" "$bw/$1"; }
ARGLINES='^ARG (SCX_BIN|EXTEST_BIN|DEV_PACKAGES)_(TAG|DIGEST)='

reset_bump
cur=$(pin_digest Containerfile SCX_BIN)
sed -i "s/^ARG SCX_BIN_DIGEST=.*/ARG SCX_BIN_DIGEST=sha256:$(dg scx-bin latest)/" "$bw/Containerfile"
cp "$bw/Containerfile" "$root/before"
bump scx-bin
check "decision equal: exit 0, 'nothing to bump', file untouched, cosign still verified latest" bash -c "[ $rc = 0 ] && grep -q 'nothing to bump' '$root/run' && cmp -s '$root/before' '$bw/Containerfile' && grep -q 'cosign verify --key keys/redcodeworks-toolbox-cosign.pub ghcr.io/redcodeworks/scx-bin@sha256:$(dg scx-bin latest)' '$LOG' && grep -qx 'result=equal' '$root/gho'"

reset_bump
bump scx-bin TAGS_JSON='{"Tags":["latest","testing","latest-20261109-1111111","latest-20261117-2222222"]}'
new="sha256:$(dg scx-bin latest)"
check "decision different, no dated tag matches: pin moves to latest, exit 10, only the pin lines change" bash -c "[ $rc = 10 ] && grep -qx 'ARG SCX_BIN_DIGEST=$new' '$bw/Containerfile' && grep -qx 'ARG SCX_BIN_TAG=latest' '$bw/Containerfile' && diff <(grep -vE '$ARGLINES' '$cf') <(grep -vE '$ARGLINES' '$bw/Containerfile') && grep -qx 'result=different' '$root/gho' && grep -qx 'previous=$cur' '$root/gho'"
check "decision different: the other image's pin is untouched" bash -c "diff <(grep -E '^ARG EXTEST_BIN_' '$cf') <(grep -E '^ARG EXTEST_BIN_' '$bw/Containerfile')"
# a dated tag with the same digest: the stub hashes the reference, so only the :latest reference hashes to the digest of latest
# unless the tag is asked for under that name; use a stub variant that answers the dated tag like latest
reset_bump
mv "$bin/skopeo" "$bin/skopeo.real"
cat >"$bin/skopeo" <<'F'
#!/usr/bin/env bash
echo "skopeo $*" >>"$LOG"
case "$1" in
    inspect) ref="${@: -1}"; printf 'manifest of %s' "${ref/:latest-20261117-2222222/:latest}" ;;
    list-tags) echo '{"Tags":["latest","latest-20261109-1111111","latest-20261117-2222222","testing-20261117-3333333"]}' ;;
esac
F
chmod +x "$bin/skopeo"
bump extest-bin
check "decision different, a dated tag has the same digest: the tag line records it" bash -c "[ $rc = 10 ] && grep -qx 'ARG EXTEST_BIN_TAG=latest-20261117-2222222' '$bw/Containerfile' && grep -qx 'ARG EXTEST_BIN_DIGEST=sha256:$(dg extest-bin latest)' '$bw/Containerfile'"
rm "$bin/skopeo"; mv "$bin/skopeo.real" "$bin/skopeo"; 

reset_bump
bump dev-packages
check "dev-packages goes through the same code (variants/dx/Containerfile, DEV_PACKAGES pin)" bash -c "[ $rc = 10 ] && grep -qx 'ARG DEV_PACKAGES_DIGEST=sha256:$(dg dev-packages latest)' '$bw/variants/dx/Containerfile' && cmp -s '$cf' '$bw/Containerfile'"

reset_bump; cp "$bw/Containerfile" "$root/before"
bump scx-bin SKOPEO_FAIL=1
check "decision unreachable registry: exit 1, file untouched, no cosign call, result=unreachable" bash -c "[ $rc = 1 ] && cmp -s '$root/before' '$bw/Containerfile' && ! grep -q cosign '$LOG' && grep -qx 'result=unreachable' '$root/gho' && grep -q 'cannot resolve' '$root/run'"
bump scx-bin SKOPEO_EMPTY=1
check "decision empty answer (latest missing): exit 1, file untouched" bash -c "[ $rc = 1 ] && cmp -s '$root/before' '$bw/Containerfile'"

reset_bump; cp "$bw/Containerfile" "$root/before"
bump scx-bin COSIGN_RC=1
check "decision bad signature: exit 2, file untouched, result=badsignature" bash -c "[ $rc = 2 ] && cmp -s '$root/before' '$bw/Containerfile' && grep -qx 'result=badsignature' '$root/gho' && grep -q 'cosign verification failed' '$root/run'"
# equal digest does not excuse a bad signature
sed -i "s/^ARG SCX_BIN_DIGEST=.*/ARG SCX_BIN_DIGEST=sha256:$(dg scx-bin latest)/" "$bw/Containerfile"
bump scx-bin COSIGN_RC=1
check "decision bad signature with an equal digest still fails" test "$rc" = 2

reset_bump; sed -i 's/^ARG SCX_BIN_DIGEST=.*/ARG SCX_BIN_DIGEST=sha256:short/' "$bw/Containerfile"
bump scx-bin
check "a malformed pin in the file: exit 3, no registry call" bash -c "[ $rc = 3 ] && ! grep -q skopeo '$LOG'"
bump nothing
check "an unknown image name: exit 3" test "$rc" = 3

# ---- the weekly workflow
wf="$here/.github/workflows/bump-pins.yml"
check "bump-pins.yml: Tuesday 07:00 UTC schedule plus workflow_dispatch, nothing else" python3 -I - "$wf" <<'PY'
import sys, yaml
w = yaml.safe_load(open(sys.argv[1]))
on = w.get(True) or w.get("on")
assert set(on) == {"schedule", "workflow_dispatch"}, set(on)
assert on["schedule"] == [{"cron": "0 7 * * 2"}], on["schedule"]
PY
check "bump-pins.yml: a job per image (scx-bin, extest-bin, dev-packages), no fail-fast, runs on testing, permissions contents and pull-requests write" python3 -I - "$wf" <<'PY'
import sys, yaml
w = yaml.safe_load(open(sys.argv[1]))
j = w["jobs"]["bump"]
assert j["strategy"]["matrix"]["image"] == ["scx-bin", "extest-bin", "dev-packages"], j["strategy"]
assert j["strategy"]["fail-fast"] is False
assert w["permissions"] == {"contents": "write", "pull-requests": "write"}, w["permissions"]
co = [s for s in j["steps"] if s.get("uses", "").startswith("actions/checkout@")][0]
assert co["with"]["ref"] == "testing" and co["with"]["fetch-depth"] == 0
import re
assert re.search(r"@[0-9a-f]{40}$", co["uses"]), co["uses"]
PY
check "bump-pins.yml: BUMP_TOKEN is used when set, the default token otherwise; no step prints a token" python3 -I - "$wf" <<'PY'
import re, sys
s = open(sys.argv[1]).read()
assert s.count("secrets.BUMP_TOKEN || github.token") == 2, s.count("secrets.BUMP_TOKEN || github.token")
for line in s.splitlines():
    code = line.strip()
    if code.startswith("#"):
        continue
    assert not re.search(r"\b(echo|printf)\b.*(\$\{?(GH_TOKEN|BUMP_TOKEN)|secrets\.BUMP_TOKEN|github\.token)", code), line
    assert "set -x" not in code, line
assert "HAVE_BUMP_TOKEN" in s and "did not start" in s, "the fallback notice is missing"
PY
check "bump-pins.yml: one branch per image bump/<image>-digest into testing, updated by merge not force-push, created or edited PR" bash -c "
  grep -q 'branch=\"bump/\${IMAGE}-digest\"' '$wf' && grep -q -- '--base testing' '$wf' && grep -q 'gh pr create' '$wf' && grep -q 'gh pr edit' '$wf' &&
  grep -q 'git merge --no-edit -X theirs origin/testing' '$wf' && ! grep -qE 'git push.*(--force|-f |--force-with-lease)' '$wf' && ! grep -qi 'co-authored-by' '$wf'"
check "bump-pins.yml: the job runs bump-pin.sh and fails on every exit code but 0 and 10" bash -c "grep -q 'bump-pin.sh \"\${IMAGE}\"' '$wf' && grep -q '0 | 10) ;;' '$wf'"
check "bump-pins.yml: every script it uses exists and parses" bash -c "for f in .github/scripts/bump-pin.sh .github/scripts/check-binary-pins.sh build_files/install-binaries.sh; do bash -n '$here'/\$f || exit 1; done"

echo
echo "passed: $pass, failed: $failn"
[ "$failn" = 0 ]
