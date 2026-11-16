#!/usr/bin/env bash
# The one invariant of the "promote the default and dx images together" design that no build shows before main: only publish-latest.yml writes the bare
# `latest` tag of octarine-os and octarine-os-dx, and the tag list generator leaves it out on request. The workflow shapes are not asserted (the first run on main shows them).
# Run: tests/publish-latest-workflow.sh
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fail=0
check() { local d=$1; shift; if "$@" > "$(mktemp)" 2>&1; then echo "ok   $d"; else echo "FAIL $d"; "$@" 2>&1 | sed 's/^/     /' | tail -5; fail=1; fi; }

check "just generate-build-tags: with bare=false the bare latest is not in the list, the dated ones and the same-day aliases are; testing and the default call keep their bare tag" bash -c "
    cd '$here'
    nolatest=\$(just generate-build-tags x latest false 2>/dev/null | tail -n1)
    withlatest=\$(just generate-build-tags x latest 2>/dev/null | tail -n1)
    testing=\$(just generate-build-tags x testing false 2>/dev/null | tail -n1)
    tok() { tr ' ' '\\n' <<< \"\$1\"; }
    ! tok \"\$nolatest\" | grep -qx latest && tok \"\$nolatest\" | grep -qE '^latest-[0-9]{8}\$' && tok \"\$nolatest\" | grep -qE '^[0-9]{8}\$' &&
    tok \"\$withlatest\" | grep -qx latest && tok \"\$testing\" | grep -qx testing"
exit "$fail"
