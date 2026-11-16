#!/usr/bin/env bash
# Tests the two readers that keep "could not read" apart from "is not there" (registry-read.sh, cosign-check.sh) with fake skopeo and cosign, and the wiring of the
# rule in the workflows. The behavior of the callers is tested next to them (plan-promote, plan-dx, publish-latest, base-pin, binary-images). Run: tests/transient-reads.sh
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
root=$(mktemp -d)
trap 'rm -rf -- "${root:?}"' EXIT
pass=0; failn=0; rc=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { failn=$((failn + 1)); echo "FAIL $1"; sed 's/^/     /' "$root/run" 2> /dev/null; echo "     rc=$rc"; }
check() { local d=$1; shift; if "$@" > "$root/out" 2>&1; then ok "$d"; else bad "$d"; fi; }
bin="$root/bin"; mkdir -p "$bin"
cat > "$bin/skopeo" <<'F'
#!/usr/bin/env bash
n=$(cat "$COUNT" 2> /dev/null || echo 0); n=$((n + 1)); echo "$n" > "$COUNT"
case "${MODE:-ok}" in
    ok) echo '{"manifest":1}' ;;
    absent) echo "Error: reading manifest x in ghcr.io/o/i: manifest unknown" >&2; exit 1 ;;
    absent404) echo "fetching: 404 Not Found" >&2; exit 1 ;;
    flaky) [[ "$n" -gt 2 ]] && echo '{"manifest":1}' || { echo "dial tcp: i/o timeout" >&2; exit 1; } ;;
    down) echo "Get https://ghcr.io: 503 Service Unavailable" >&2; exit 1 ;;
    empty) exit 0 ;;
esac
F
cat > "$bin/cosign" <<'F'
#!/usr/bin/env bash
n=$(cat "$COUNT" 2> /dev/null || echo 0); n=$((n + 1)); echo "$n" > "$COUNT"
case "${MODE:-ok}" in
    ok) exit 0 ;;
    nosig) echo "Error: no signatures found" >&2; exit 1 ;;
    badsig) echo "Error: no matching signatures: invalid signature when validating ASN.1 encoded signature" >&2; exit 1 ;;
    flaky) [[ "$n" -gt 1 ]] && exit 0 || { echo "Error: GET https://ghcr.io/v2/: TLS handshake timeout" >&2; exit 1; } ;;
    down) echo "Error: context deadline exceeded" >&2; exit 1 ;;
esac
F
chmod +x "$bin"/*
export RETRY_DELAY=0 COUNT="$root/count"
rr() { rm -f "$COUNT"; env "$@" PATH="$bin:$PATH" bash "$here/.github/scripts/registry-read.sh" raw ghcr.io/o/i:t > "$root/run" 2>&1 < /dev/null; rc=$?; }
cc() { rm -f "$COUNT"; env "$@" PATH="$bin:$PATH" bash "$here/.github/scripts/cosign-check.sh" --key k ghcr.io/o/i@sha256:x > "$root/run" 2>&1 < /dev/null; rc=$?; }
tries() { cat "$COUNT"; }
rr MODE=ok
check "registry-read: a readable tag: exit 0, the manifest on stdout, one call" bash -c "[ $rc = 0 ] && grep -q manifest '$root/run' && [ \$(cat '$COUNT') = 1 ]"
rr MODE=absent
check "registry-read: 'manifest unknown' is ABSENT: exit 3 at once, no retry" bash -c "[ $rc = 3 ] && [ \$(cat '$COUNT') = 1 ]"
rr MODE=absent404
check "registry-read: a 404 is absent too (exit 3)" test "$rc" = 3
rr MODE=flaky
check "registry-read: two timeouts then success: exit 0 after three calls (the read is retried)" bash -c "[ $rc = 0 ] && [ \$(cat '$COUNT') = 3 ]"
rr MODE=down
check "registry-read: a registry that stays down is a READ ERROR (exit 4, never 3), after three tries, with the message" bash -c "[ $rc = 4 ] && [ \$(cat '$COUNT') = 3 ] && grep -q 'a read error, NOT a missing image' '$root/run'"
rr MODE=empty
check "registry-read: an empty answer is not an answer (read error, exit 4)" test "$rc" = 4
cc MODE=ok
check "cosign-check: verified: exit 0, one call" bash -c "[ $rc = 0 ] && [ \$(cat '$COUNT') = 1 ]"
cc MODE=nosig
check "cosign-check: 'no signatures found' is NOT VERIFIED: exit 5 at once, no retry" bash -c "[ $rc = 5 ] && [ \$(cat '$COUNT') = 1 ]"
cc MODE=badsig
check "cosign-check: 'no matching signatures' is NOT VERIFIED (exit 5)" test "$rc" = 5
cc MODE=flaky
check "cosign-check: a timeout then success: exit 0 (retried)" bash -c "[ $rc = 0 ] && [ \$(cat '$COUNT') = 2 ]"
cc MODE=down
check "cosign-check: a check that cannot complete is a READ ERROR (exit 4, never 5) after three tries" bash -c "[ $rc = 4 ] && [ \$(cat '$COUNT') = 3 ] && grep -q 'a read error, NOT a bad signature' '$root/run'"
mkdir -p "$root/s/.github/scripts" "$root/bin2"
cp "$here"/.github/scripts/registry-settled.sh "$here"/.github/scripts/registry-digest.sh "$here"/.github/scripts/registry-read.sh "$root/s/.github/scripts/"
A=$(printf 'a%.0s' {1..64})
cat > "$root/bin2/skopeo" <<F
#!/usr/bin/env bash
case "\$1" in
    manifest-digest) echo sha256:$A ;;
    inspect) [ -z "\${DOWN:-}" ] || { echo "dial tcp: timeout" >&2; exit 1; }; echo x ;;
esac
F
chmod +x "$root/bin2/skopeo"
settled() { env "$@" PATH="$root/bin2:$PATH" READBACK_WAIT=0 READBACK_TRIES=2 bash "$root/s/.github/scripts/registry-settled.sh" ghcr.io/o/i t "sha256:$A" > "$root/run" 2>&1; rc=$?; }
settled X=1
check "registry-settled: a tag that shows the digest passes" test "$rc" = 0
settled DOWN=1
check "registry-settled: a registry that stays unreadable fails, saying 'unreadable' (never a pass)" bash -c "[ $rc = 1 ] && grep -q 'is unreadable' '$root/run'"
echo; echo "passed: $pass, failed: $failn"
[ "$failn" = 0 ]
