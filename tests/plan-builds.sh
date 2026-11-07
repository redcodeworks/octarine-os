#!/usr/bin/env bash
# Tests for .github/scripts/plan-builds.sh: which images each trigger builds, and the every-second-week
# cadence of the stable image with fixed dates (week 08 and 09 to catch octal trouble, the New Year
# boundary where ISO week numbers jump). No network. Needs: bash, GNU date, python3.
# Run: tests/plan-builds.sh
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
plan="$here/../.github/scripts/plan-builds.sh"
workflow="$here/../.github/workflows/build.yml"
pass=0
failn=0

ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { failn=$((failn + 1)); echo "FAIL $1"; }

images() { # event schedule date -> space separated image names, or "-" for none
    local out
    out=$("$plan" "$@" 2>/dev/null) || { echo "ERROR"; return; }
    python3 -I -c 'import json,sys; v=[e["image"] for e in json.loads(sys.argv[1])["include"]]; print(" ".join(v) or "-")' "$out"
}
expect() { # description expected event schedule date
    local d=$1 want=$2 got
    shift 2
    got=$(images "$@")
    if [[ "$got" == "$want" ]]; then ok "$d"; else bad "$d (want '$want', got '$got')"; fi
}

daily='05 10 * * *'
weekly='35 10 * * 1'

# Weekly cron: even ISO weeks build stable, odd weeks build nothing
expect "2026-02-16 is week 08 (even, leading zero): stable" "octarine-os-stable" schedule "$weekly" 2026-02-16
expect "2026-02-23 is week 09 (odd, leading zero): skip" "-" schedule "$weekly" 2026-02-23
expect "2026-03-02 is week 10: stable" "octarine-os-stable" schedule "$weekly" 2026-03-02
expect "2026-01-05 is week 02: stable" "octarine-os-stable" schedule "$weekly" 2026-01-05
expect "2026-01-12 is week 03: skip" "-" schedule "$weekly" 2026-01-12
# Year boundary: 2026 has 53 ISO weeks, so 53 and then 01 are both odd (a three week gap, once)
expect "2026-12-21 is week 52: stable" "octarine-os-stable" schedule "$weekly" 2026-12-21
expect "2026-12-28 is week 53 (odd): skip" "-" schedule "$weekly" 2026-12-28
expect "2027-01-04 is week 01 (odd): skip" "-" schedule "$weekly" 2027-01-04
expect "2027-01-11 is week 02: stable" "octarine-os-stable" schedule "$weekly" 2027-01-11
# Days at the boundary belong to the ISO week they count in (%V), not the calendar year
expect "2025-12-29 counts as 2026 week 01 (odd): skip" "-" schedule "$weekly" 2025-12-29
expect "2024-12-30 counts as 2025 week 01 (odd): skip" "-" schedule "$weekly" 2024-12-30
expect "2027-01-01 counts as 2026 week 53 (odd): skip" "-" schedule "$weekly" 2027-01-01
expect "2028-01-03 is week 01 of 2028 (odd): skip" "-" schedule "$weekly" 2028-01-03
expect "2028-01-10 is week 02 of 2028: stable" "octarine-os-stable" schedule "$weekly" 2028-01-10

# Away from New Year, consecutive Mondays alternate for a full year
prev=""
alt_ok=1
for n in $(seq 0 40); do
    d=$(date -u -d "2026-03-02 + $((n * 7)) days" +%F)
    cur=$(images schedule "$weekly" "$d")
    [[ -n "$prev" && "$prev" == "$cur" ]] && alt_ok=0
    prev=$cur
done
if (( alt_ok )); then ok "Mondays from 2026-03-02 alternate for 41 weeks"; else bad "Mondays alternated wrongly"; fi

# Daily cron: only the main image, whatever the week
expect "daily cron, even week: octarine-os only" "octarine-os" schedule "$daily" 2026-02-16
expect "daily cron, odd week: octarine-os only" "octarine-os" schedule "$daily" 2026-02-23

# Other triggers always build both
for ev in push pull_request workflow_dispatch; do
    expect "$ev builds both, odd week" "octarine-os octarine-os-stable" "$ev" "" 2026-02-23
    expect "$ev builds both, even week" "octarine-os octarine-os-stable" "$ev" "" 2026-02-16
done

# Unknown schedule is an error, not a silent no-op
expect "unknown schedule fails" "ERROR" schedule "0 0 * * *" 2026-02-16

# Matrix entries carry the right base tag and channel tag
out=$("$plan" workflow_dispatch "" 2026-02-16)
if python3 -I -c 'import json,sys; e={x["image"]:x for x in json.loads(sys.argv[1])["include"]}; a=e["octarine-os"]; b=e["octarine-os-stable"]; sys.exit(not (a["base_tag"]=="45" and a["main_tag"]=="latest" and b["base_tag"]=="latest" and b["main_tag"]=="stable"))' "$out"; then
    ok "octarine-os builds on 45 and tags latest; octarine-os-stable builds on STABLE_BASE_TAG (latest) and tags stable"
else
    bad "matrix entries wrong: $out"
fi

# STABLE_BASE_TAG in the env file is the single place that sets the stable image's base
tmp=$(mktemp); sed 's/^STABLE_BASE_TAG=.*/STABLE_BASE_TAG=45-test/' "$here/../image-template.env" >"$tmp"
out=$(ENV_FILE="$tmp" "$plan" workflow_dispatch "" 2026-02-16); rm -f "$tmp"
if grep -q '"base_tag":"45-test"' <<<"$out"; then ok "STABLE_BASE_TAG changes the stable base tag"; else bad "STABLE_BASE_TAG ignored: $out"; fi

# The cron strings in the script must be the ones in build.yml
for c in "$daily" "$weekly"; do
    if grep -qF -- "- cron: '$c'" "$workflow"; then ok "build.yml schedules '$c'"; else bad "build.yml does not schedule '$c'"; fi
done

echo
echo "$pass passed, $failn failed"
(( failn == 0 ))
