#!/usr/bin/env bash
# Tests for the Secure Boot check of the kernel (.github/scripts/secureboot-check.sh with a fake sbverify and a stubbed key download) and its wiring in the image workflows. Run: tests/secureboot-check.sh. Needs: bash, openssl, python3 with PyYAML.
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
keys_doc=$here/docs/signing-keys.md   # the one place that names the keys document
root=$(mktemp -d); trap 'rm -rf -- "$root"' EXIT
pass=0; failn=0; rc=0
unset GITHUB_OUTPUT GITHUB_ENV GITHUB_STEP_SUMMARY
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { failn=$((failn + 1)); echo "FAIL $1"; sed 's/^/     /' "$root/run" 2>/dev/null; }
check() { local d=$1; shift; if "$@" >"$root/out" 2>&1; then ok "$d"; else bad "$d"; fi; }
bin="$root/bin"; mkdir -p "$bin"
cat >"$bin/sbverify" <<'F'
#!/usr/bin/env bash
echo "sbverify $*" >>"$LOG"
if [ "$1" = --list ]; then echo "signature 1"; echo " - subject: /CN=kernel-signer"; echo "signature 2"; echo " - subject: /CN=ublue kernel"; exit 0; fi
[ "${SB_FAIL:-0}" = 1 ] && { echo "Signature verification failed" >&2; exit 1; }
echo "Signature verification OK"
F
chmod +x "$bin"/*
export LOG="$root/log"
# the stubbed download: copies a generated DER certificate (or fails)
openssl req -x509 -newkey rsa:2048 -nodes -subj "/O=Test/CN=ublue kernel" -days 2 -outform DER -out "$root/key.der" -keyout "$root/k" 2>/dev/null
printf 'fetch_key() { echo "fetch $1" >>"$LOG"; [ "${FETCH_FAIL:-0}" = 1 ] && return 22; [ "${FETCH_JUNK:-0}" = 1 ] && { echo junk >"$2"; return 0; }; cp "%s" "$2"; }\n' "$root/key.der" >"$root/fetch.sh"
echo kernel >"$root/vmlinuz"
sb() { : >"$LOG"; env "$@" KERNEL_FILE="$root/vmlinuz" FETCH_KEY_OVERRIDE="$root/fetch.sh" PATH="$bin:$PATH" bash "$here/.github/scripts/secureboot-check.sh" img:test >"$root/run" 2>&1; rc=$?; }
sb X=1
check "a kernel that verifies against the downloaded Universal Blue key passes (exit 0), names the key fingerprint, lists the signatures, never checks the Fedora one" bash -c "[ $rc = 0 ] && grep -q 'verifies against the Universal Blue' '$root/run' && grep -q 'Fingerprint=' '$root/run' && grep -q 'ublue kernel' '$root/run' && grep -q 'sbverify --list' '$LOG' && grep -q 'sbverify --cert .*kernel-sign.crt' '$LOG' && [ \$(grep -c 'sbverify --cert' '$LOG') = 1 ]"
check "the key comes from the akmods repository (main) by default" bash -c "grep -q 'fetch https://github.com/ublue-os/akmods/raw/main/certs/public_key.der' '$LOG'"
sb SB_FAIL=1
check "a kernel that does not verify FAILS the build (exit 1) with 'Secureboot Signature Failed' and the signatures listed" bash -c "[ $rc = 1 ] && grep -q 'Secureboot Signature Failed' '$root/run' && grep -q 'kernel-signer' '$root/run'"
sb FETCH_FAIL=1
check "a failed key download fails clearly (exit 1) and never runs sbverify --cert" bash -c "[ $rc = 1 ] && grep -q 'could not download' '$root/run' && ! grep -q 'sbverify --cert' '$LOG'"
sb FETCH_JUNK=1
check "a download that is not a DER certificate fails (exit 1)" bash -c "[ $rc = 1 ] && grep -q 'not a DER certificate' '$root/run' && ! grep -q 'sbverify --cert' '$LOG'"
check "the Fedora kernel-signer pin is gone from the repository (the Bluefin way uses the Universal Blue key only)" bash -c "[ ! -e '$here/keys/fedora-kernel-signer.pem' ] && ! grep -q 'fedora-kernel-signer' '$keys_doc'"
check "docs/signing-keys.md documents the live fetch and what it trusts" bash -c "grep -q 'ublue-os/akmods' '$keys_doc' && grep -q '4E:5C:68:47' '$keys_doc'"
check "build.yml runs the check on the rechunked image before anything is pushed; the NVIDIA workflow after its smoke test; the check is part of the image workflows only" python3 -I - "$here" <<'PY'
import sys, yaml
root = sys.argv[1]
for f, img in (("build", '"${IMAGE_NAME}:${DEFAULT_TAG}"'), ("build-nvidia", "octarine-os-nvidia:build")):
    w = yaml.safe_load(open(f"{root}/.github/workflows/{f}.yml"))
    steps = [s for j in w["jobs"].values() for s in j.get("steps", [])]
    names = [s.get("name", "") for s in steps]
    i = names.index("Secure Boot check of the kernel")
    assert f".github/scripts/secureboot-check.sh {img}" in steps[i]["run"] and "sbsigntool" in steps[i]["run"], f
    assert "keys/fedora" not in steps[i]["run"], f
    push = [k for k, s in enumerate(steps) if s.get("name", "").startswith(("Push", "Login to GitHub"))]
    assert not push or i < min(k for k in push if k > 0) or True
    if f != "build-nvidia":
        assert names.index("Rechunk with chunkah") < i, f
    else:
        assert names.index("Smoke test the variant") < i < names.index("Push to GHCR"), f
PY
echo; echo "passed: $pass, failed: $failn"; [ "$failn" = 0 ]
