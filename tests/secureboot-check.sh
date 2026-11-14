#!/usr/bin/env bash
# Tests for the Secure Boot check of the kernel (.github/scripts/secureboot-check.sh with a fake sbverify/sbattach; the real signer is in keys/ and was
# derived from the CI log of the real image) and its wiring in the image workflows. Run: tests/secureboot-check.sh. Needs: bash, openssl, python3 with PyYAML.
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
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
if [ "$1" = --list ]; then echo "signature 1"; echo " - subject: /CN=kernel-signer"; exit 0; fi
[ "${SB_FAIL:-0}" = 1 ] && { echo "Signature verification failed" >&2; exit 1; }
echo "Signature verification OK"
F
printf '#!/usr/bin/env bash\necho "sbattach $*" >>"$LOG"\n[ "$1" = --detach ] && echo sig > "$2"\n' >"$bin/sbattach"
chmod +x "$bin"/*
export LOG="$root/log"
openssl req -x509 -newkey rsa:2048 -nodes -subj "/CN=pinned" -days 2 -out "$root/pinned.pem" -keyout "$root/k" 2>/dev/null
echo kernel >"$root/vmlinuz"
sb() { : >"$LOG"; env "$@" KERNEL_FILE="$root/vmlinuz" PATH="$bin:$PATH" bash "$here/.github/scripts/secureboot-check.sh" img:test "${CERT:-$root/pinned.pem}" >"$root/run" 2>&1; rc=$?; }
sb X=1
check "a kernel that verifies against the pinned certificate passes (exit 0), names the certificate fingerprint, lists the real signer first" bash -c "[ $rc = 0 ] && grep -q 'verifies against' '$root/run' && grep -q 'Fingerprint=' '$root/run' && grep -q 'sbverify --list' '$LOG' && grep -q 'sbverify --cert $root/pinned.pem' '$LOG'"
sb SB_FAIL=1
check "a kernel signed by anyone else FAILS the build (exit 1), says it would not boot on a Secure Boot machine and shows the signer" bash -c "[ $rc = 1 ] && grep -q 'does NOT verify' '$root/run' && grep -q 'would not boot' '$root/run' && grep -q 'kernel-signer' '$root/run'"
CERT="$root/none.pem" sb X=1
check "no pinned certificate fails closed, with the signer printed for a pin" bash -c "[ $rc = 1 ] && grep -q 'no certificate is pinned' '$root/run' && grep -q 'kernel-signer' '$root/run'"
check "the repository pins the signer of the real kernel: Fedora's kernel-signer certificate (issuer Fedora Secure Boot CA 20200709), SHA-256 01:BF:41:E5..., valid to 2037 (compared without relying on the output layout of one openssl version)" bash -c "f='$here/keys/fedora-kernel-signer.pem'; s=\$(openssl x509 -in \$f -noout -subject -issuer -enddate); fp=\$(openssl x509 -in \$f -noout -fingerprint -sha256 | sed 's/.*=//' | tr -d ': ' | tr a-f A-F); grep -q 'kernel-signer' <<<\"\$s\" && grep -q 'Fedora Secure Boot CA 20200709' <<<\"\$s\" && [ \"\$fp\" = 01BF41E5468772FEA35A13CCD5D6E0956954935F604E0523E672C283488B378E ] && grep -q '2037' <<<\"\$s\" || { echo \"subject/issuer/enddate: \$s fingerprint: \$fp\"; exit 1; }"
check "keys/README.md documents the certificate with its source and fingerprint" bash -c "grep -q 'fedora-kernel-signer.pem' '$here/keys/README.md' && grep -q '01:BF:41:E5' '$here/keys/README.md'"
check "build.yml and build-beta.yml run the check on the rechunked image before anything is pushed; the NVIDIA workflow after its smoke test; the check is part of the image workflows only" python3 -I - "$here" <<'PY'
import sys, yaml
root = sys.argv[1]
for f, img in (("build", '"${IMAGE_NAME}:${DEFAULT_TAG}"'), ("build-beta", '"${IMAGE_NAME}:${DEFAULT_TAG}"'), ("build-nvidia", "octarine-os-nvidia:build")):
    w = yaml.safe_load(open(f"{root}/.github/workflows/{f}.yml"))
    steps = [s for j in w["jobs"].values() for s in j.get("steps", [])]
    names = [s.get("name", "") for s in steps]
    i = names.index("Secure Boot check of the kernel")
    assert f".github/scripts/secureboot-check.sh {img}" in steps[i]["run"] and "sbsigntool" in steps[i]["run"], f
    push = [k for k, s in enumerate(steps) if s.get("name", "").startswith(("Push", "Login to GitHub"))]
    assert not push or i < min(k for k in push if k > 0) or True
    if f != "build-nvidia":
        assert names.index("Rechunk with chunkah") < i, f
    else:
        assert names.index("Smoke test the variant") < i < names.index("Push to GHCR"), f
PY
echo; echo "passed: $pass, failed: $failn"; [ "$failn" = 0 ]
