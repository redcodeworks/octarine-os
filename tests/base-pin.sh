#!/usr/bin/env bash
# Tests for the floating base with safeguards (.github/scripts/base-pin.sh): the tag is resolved to a digest once, its signature is verified with the pinned
# Universal Blue key, a failure stops the build; and the wiring (Containerfile FROM, Justfile label, the two workflows). Fake skopeo and cosign.
# Run: tests/base-pin.sh. Needs: bash, jq, python3 with PyYAML.
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
keys_doc=$here/docs/signing-keys.md   # the one place that names the keys document
root=$(mktemp -d); trap 'rm -rf -- "$root"' EXIT
pass=0; failn=0; rc=0
# the CI runner exports these (root-owned files the test user cannot write): the script must only write where each case points them
unset GITHUB_OUTPUT GITHUB_ENV GITHUB_STEP_SUMMARY
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { failn=$((failn + 1)); echo "FAIL $1"; sed 's/^/     /' "$root/run" 2>/dev/null; }
check() { local d=$1; shift; if "$@" >"$root/out" 2>&1; then ok "$d"; else bad "$d"; fi; }
bin="$root/bin"; mkdir -p "$bin"
cat >"$bin/skopeo" <<'F'
#!/usr/bin/env bash
echo "skopeo $*" >>"$LOG"
[ "${READ_ERROR:-0}" = 1 ] && { echo "dial tcp: i/o timeout" >&2; exit 1; }
[ "${NO_TAG:-0}" = 1 ] && { echo "Error: manifest unknown" >&2; exit 1; }
printf '%s' "${MANIFEST}"
F
cat >"$bin/cosign" <<'F'
#!/usr/bin/env bash
echo "cosign $*" >>"$LOG"
ref="${@: -1}"
# SIGNED lists the digests that carry a valid signature
case " ${SIGNED:-} " in *" ${ref#*@} "*) exit 0 ;; esac
[ "${COSIGN_ERR:-}" = timeout ] && { echo "Error: GET https://ghcr.io: TLS handshake timeout" >&2; exit 1; }
[ "${COSIGN_ERR:-}" = nosig ] && { echo "Error: no signatures found" >&2; exit 1; }
echo "Error: no matching signatures: failed to verify signature" >&2
exit 1
F
chmod +x "$bin"/*
export RETRY_DELAY=0 LOG="$root/log" BASE_IMAGE=ghcr.io/ublue-os/silverblue-main FEDORA_VERSION=45
echo key >"$root/key.pub"
CHILD="sha256:$(printf 'c%.0s' {1..64})"
LIST="{\"manifests\":[{\"digest\":\"sha256:$(printf 'e%.0s' {1..64})\",\"platform\":{\"os\":\"linux\",\"architecture\":\"arm64\"}},{\"digest\":\"$CHILD\",\"platform\":{\"os\":\"linux\",\"architecture\":\"amd64\"}}]}"
SINGLE='{"schemaVersion":2,"layers":[]}'
pin_of() { printf 'sha256:'; printf '%s' "$1" | sha256sum | sed 's/ .*//'; }
bp() { : >"$LOG"; : >"$root/genv"; : >"$root/sum"; env "$@" KEY="$root/key.pub" PATH="$bin:$PATH" GITHUB_ENV="$root/genv" GITHUB_STEP_SUMMARY="$root/sum" bash "$here/.github/scripts/base-pin.sh" >"$root/run" 2>&1; rc=$?; }
P=$(pin_of "$SINGLE"); bp MANIFEST="$SINGLE" SIGNED="$P"
check "a signed single manifest: the tag is resolved to its digest once, verified with the key, BASE_PIN printed, exported and named in the summary" bash -c "[ $rc = 0 ] && grep -qx 'BASE_PIN=$P' '$root/run' && grep -qx 'BASE_PIN=$P' '$root/genv' && grep -q 'resolved ONCE to \`$P\`' '$root/sum' && grep -q 'cosign verify --key $root/key.pub ghcr.io/ublue-os/silverblue-main@$P' '$LOG' && [ \$(grep -c '^skopeo' '$LOG') = 1 ]"
PL=$(pin_of "$LIST"); bp MANIFEST="$LIST" SIGNED="$PL"
check "a manifest list whose own digest is signed passes" bash -c "[ $rc = 0 ] && grep -qx 'BASE_PIN=$PL' '$root/run'"
bp MANIFEST="$LIST" SIGNED="$CHILD"
check "a manifest list whose linux/amd64 child is signed (the list digest is not) passes: the pin still names the list" bash -c "[ $rc = 0 ] && grep -qx 'BASE_PIN=$PL' '$root/run' && grep -q 'linux/amd64 manifest $CHILD' '$root/sum'"
bp MANIFEST="$SINGLE" SIGNED=""
check "an unsigned or differently signed base FAILS the build (exit 1), names the key, a possible key rotation, nothing exported" bash -c "[ $rc = 1 ] && grep -q 'is not signed by $root/key.pub' '$root/run' && grep -q 'rotated its signing key' '$root/run' && [ ! -s '$root/genv' ]"
bp MANIFEST="$LIST" SIGNED="sha256:$(printf 'e%.0s' {1..64})"
check "a signature on the arm64 child does not count: fails" bash -c "[ $rc = 1 ]"
bp NO_TAG=1 MANIFEST=x SIGNED=x
check "a tag that cannot be resolved fails before any verification" bash -c "[ $rc = 1 ] && grep -q 'cannot resolve' '$root/run' && ! grep -q '^cosign' '$LOG'"
bp READ_ERROR=1 MANIFEST=x SIGNED=x
check "a registry that cannot be read is a read error (re-run), not a missing tag, and nothing is verified" bash -c "[ $rc = 1 ] && grep -q 'registry read error' '$root/run' && ! grep -q 'cannot resolve' '$root/run' && ! grep -q '^cosign' '$LOG'"
bp COSIGN_ERR=timeout MANIFEST="$LIST" SIGNED=""
check "a cosign check that cannot be completed says TRANSIENT (a read error, not a wrong key) and fails" bash -c "[ $rc = 1 ] && grep -q 'could not be checked after the retries' '$root/run' && ! grep -q 'rotated its signing key' '$root/run'"
bp COSIGN_ERR=nosig MANIFEST="$LIST" SIGNED=""
check "no signature visible yet says so (a later re-run usually passes), not 'wrong key'" bash -c "[ $rc = 1 ] && grep -q 'no signature is visible' '$root/run' && ! grep -q 'rotated its signing key' '$root/run'"
bp FEDORA_VERSION=latest MANIFEST="$SINGLE" SIGNED="$P"
check "a FEDORA_VERSION that is not a number is refused" bash -c "[ $rc = 1 ]"
bp FEDORA_VERSION=rawhide MANIFEST="$SINGLE" SIGNED="$P"
check "other words stay refused (rawhide is not a Universal Blue tag)" bash -c "[ $rc = 1 ]"
check "keys/ublue-os-main-cosign.pub is the default key of the script and is in the repository with its source documented" bash -c "grep -q 'keys/ublue-os-main-cosign.pub' '$here/.github/scripts/base-pin.sh' && test -s '$here/keys/ublue-os-main-cosign.pub' && grep -q 'ublue-os/main' '$keys_doc'"
check "Containerfile builds FROM the pinned digest when BASE_PIN is set and on the tag otherwise (the ARG before the first FROM is guarded by tests/containerfile-from-args.sh)" bash -c "grep -qE '^FROM .*BASE_PIN:\\+@.*BASE_PIN' '$here/Containerfile' && grep -q 'BASE_PIN=\\\${BASE_PIN}' '$here/Justfile'"
check "build.yml resolves and verifies the base once (base-pin.sh) before the build, pull it BY DIGEST, and no later step resolves the floating tag again" python3 -I - "$here" <<'PY'
import sys, yaml
root = sys.argv[1]
for f in ("build.yml",):
    t = open(f"{root}/.github/workflows/{f}").read()
    w = yaml.safe_load(t)
    steps = [s for j in w["jobs"].values() for s in j.get("steps", [])]
    names = [s.get("name", "") for s in steps]
    i = next(n for n, s in enumerate(steps) if ".github/scripts/base-pin.sh" in s.get("run", "") and "podman pull" in s.get("run", ""))
    b = next(n for n, s in enumerate(steps) if "just build" in s.get("run", "") or "Build Image" in s.get("name", ""))
    run = steps[i]["run"]
    assert i < b, f   # the base is resolved and verified before the build
    assert 'podman pull "${BASE_IMAGE}@${BASE_PIN}"' in run, f   # and pulled BY DIGEST
    assert 'skopeo inspect --raw "docker://${base}"' not in run, f   # the floating tag is not resolved again later
PY
echo; echo "passed: $pass, failed: $failn"; [ "$failn" = 0 ]
