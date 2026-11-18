#!/usr/bin/env bash
# Tests for the Secure Boot check of the kernel (.github/scripts/secureboot_check.py with a fake sbverify and a key download from a file:// URL) and its wiring in the image workflows. Run: tests/image/secureboot-check.sh. Needs: bash, openssl, python3 with PyYAML.
set -uo pipefail
here=$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)
root=$(mktemp -d); trap 'rm -rf -- "$root"' EXIT
pass=0; failn=0; rc=0
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
# the key: a generated DER certificate served through a file:// URL
openssl req -x509 -newkey rsa:2048 -nodes -subj "/O=Test/CN=ublue kernel" -days 2 -outform DER -out "$root/key.der" -keyout "$root/k" 2>/dev/null
echo junk >"$root/junk.der"
echo kernel >"$root/vmlinuz"
py=$(command -v python3)
export RETRY_DELAY=0
sb() { : >"$LOG"; env UBLUE_KEY_URL="file://$root/key.der" "$@" KERNEL_FILE="$root/vmlinuz" PATH="$bin:$PATH" "$py" -I "$here/.github/scripts/secureboot_check.py" img:test >"$root/run" 2>&1; rc=$?; }
sb X=1
check "a kernel that verifies against the downloaded Universal Blue key passes (exit 0), names the key fingerprint, lists the signatures, never checks the Fedora one" bash -c "[ $rc = 0 ] && grep -q 'verifies against the Universal Blue' '$root/run' && grep -q 'Fingerprint=' '$root/run' && grep -q 'ublue kernel' '$root/run' && grep -q 'sbverify --list' '$LOG' && grep -q 'sbverify --cert .*kernel-sign.crt' '$LOG' && [ \$(grep -c 'sbverify --cert' '$LOG') = 1 ]"
sb SB_FAIL=1
check "a kernel that does not verify FAILS the build (exit 1) with 'Secureboot Signature Failed' and the signatures listed" bash -c "[ $rc = 1 ] && grep -q 'Secureboot Signature Failed' '$root/run' && grep -q 'kernel-signer' '$root/run'"
sb UBLUE_KEY_URL="file://$root/missing.der"
check "a failed key download fails clearly (exit 1) and never runs sbverify --cert" bash -c "[ $rc = 1 ] && grep -q 'could not download' '$root/run' && ! grep -q 'sbverify --cert' '$LOG'"
sb UBLUE_KEY_URL="file://$root/junk.der"
check "a download that is not a DER certificate fails (exit 1)" bash -c "[ $rc = 1 ] && grep -q 'not a DER certificate' '$root/run' && ! grep -q 'sbverify --cert' '$LOG'"
echo; echo "passed: $pass, failed: $failn"; [ "$failn" = 0 ]
