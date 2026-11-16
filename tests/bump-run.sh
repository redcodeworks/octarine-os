#!/usr/bin/env bash
# Tests for the combined weekly bump: the runner of one pin (bump-run.sh: the Homebrew files image and Fedora builder kinds with stub registry answers, one
# commit per moved pin), the orchestrator (bump-weekly.sh: ONE branch and ONE pull request, a commit per pin, an older weekly PR superseded, nothing moved means
# no branch and no PR, a same-day rerun gets a new branch, never a force-push, a dry run opens nothing) and the workflow (the pins it runs are the pins CLAUDE.md
# documents). A local origin, stub gh, skopeo, just and cosign; no network. Needs: bash, git, jq, python3 with PyYAML. Run: tests/bump-run.sh
# shellcheck disable=SC2016
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
root=$(mktemp -d); trap 'rm -rf -- "$root"' EXIT
pass=0; failn=0
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
unset GITHUB_OUTPUT GITHUB_STEP_SUMMARY
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { failn=$((failn + 1)); echo "FAIL $1"; [ -f "$root/run" ] && sed 's/^/     /' "$root/run" | tail -12; }
check() { local d=$1; shift; if "$@" >"$root/out" 2>&1; then ok "$d"; else bad "$d"; fi; }
bin="$root/bin"; mkdir -p "$bin"
export GH_LOG="$root/gh.log"
export GITHUB_REPOSITORY=o/r BUMP_CHECKS_WAIT=0
cat >"$bin/gh" <<'F'
#!/usr/bin/env bash
echo "gh $*" >>"$GH_LOG"
case "$1 $2" in
    "pr list") [ -z "${STALE_PRS:-}" ] || printf '%s\n' "$STALE_PRS" ;;
    "pr create") echo "https://github.com/o/r/pull/${NEW_PR:-77}" ;;
    "pr close") exit 0 ;;
    "workflow run") [ -z "${GH_WF_FAIL:-}" ] ;;
    "run list") exit 0 ;;
    "api repos/o/p/releases/latest") echo "${REL:-v1.1.5}" ;;
    "api repos/o/p/commits/"*) printf '%s\n' "$(printf 'b%.0s' {1..40})" ;;
    "api repos/o/r/commits/"*) exit 0 ;;
    *) exit 99 ;;
esac
F
chmod +x "$bin/gh"

mkrepo() { # dir: a working copy with a bare origin, the scripts, a builder.env and a Containerfile
    local wc=$1
    rm -rf "$wc" "$root/origin.git"; git init -q --bare -b testing "$root/origin.git"
    mkdir -p "$wc/.github/scripts" "$wc/binaries/lib" "$wc/keys"
    cp "$here"/.github/scripts/bump-weekly.sh "$here"/.github/scripts/bump-checks.sh "$here"/.github/scripts/bump-run.sh "$here"/.github/scripts/upstream-check.sh "$wc/.github/scripts/"
    cp "$here/binaries/lib/upstream-env.sh" "$wc/binaries/lib/"; mkdir -p "$wc/binaries/scx"
    printf "UPSTREAM_REPO=o/p\nUPSTREAM_TAG=v1.1.4\nUPSTREAM_COMMIT=%s\n" "$(printf 'a%.0s' {1..40})" >"$wc/binaries/scx/upstream.env"
    printf 'BUILDER=registry.fedoraproject.org/fedora:45@sha256:%s\n' "$(printf 'a%.0s' {1..64})" >"$wc/binaries/builder.env"
    printf 'ARG BREW_TAG=20261108\nARG BREW_DIGEST=sha256:%s\nFROM x\n' "$(printf 'b%.0s' {1..64})" >"$wc/Containerfile"
    git -C "$wc" init -q -b testing; git -C "$wc" add -A; git -C "$wc" commit -q -m base; git -C "$wc" remote add origin "$root/origin.git"; git -C "$wc" push -q origin testing
}
wc="$root/wc"
now=$(date -u +%Y-%m-%dT%H:%M:%SZ); old10=$(date -u -d '10 days ago' +%Y-%m-%dT%H:%M:%SZ); young2=$(date -u -d '2 days ago' +%Y-%m-%dT%H:%M:%SZ)
day=$(date -u +%Y%m%d)

# ---- stub registry tools
cat >"$bin/skopeo" <<'F'
#!/usr/bin/env bash
echo "skopeo $*" >>"$GH_LOG"
[ "${SKOPEO_FAIL:-0}" = 1 ] && exit 1
case "$1" in
    list-tags) printf '{"Tags":[%s]}' "$TAGS" ;;
    inspect)
        if printf '%s' "$*" | grep -q -- '--config'; then printf '{"created":"%s"}' "$CREATED"; else printf 'manifest-%s' "${MANIFEST:-x}"; fi ;;
esac
F
cat >"$bin/just" <<'F'
#!/usr/bin/env bash
echo "just $*" >>"$GH_LOG"
[ "$1" = brew-bump ] || exit 9
[ "${JUST_FAIL:-0}" = 1 ] && { echo "cosign verification failed" >&2; exit 1; }
sed -i "s/^ARG BREW_TAG=.*/ARG BREW_TAG=$2/; s/^ARG BREW_DIGEST=.*/ARG BREW_DIGEST=sha256:$(printf 'c%.0s' {1..64})/" Containerfile
F
chmod +x "$bin/skopeo" "$bin/just"
fresh() { mkrepo "$wc"; : >"$GH_LOG"; }
# one pin on a clean testing checkout: the working tree is left with the pin commit (or nothing)
run() { local pin=$1; shift; (cd "$wc" && env "$@" PATH="$bin:$PATH" bash .github/scripts/bump-run.sh "$pin") >"$root/run" 2>&1; rc=$?; }
last() { git -C "$wc" log -1 --format=%B; }
moved() { [ "$(git -C "$wc" rev-list --count origin/testing..HEAD)" = "$1" ]; }
clean() { git -C "$wc" diff --quiet && [ -z "$(git -C "$wc" status --porcelain)" ]; }

# ---- a source pin (scx: the release check, the pin writer and the row with the compare link)
fresh; run scx
check "scx, a newer release: ONE commit changing only binaries/scx/upstream.env (tag and commit), the row links the compare view of the followed project" bash -c "[ $rc = 0 ] && [ \"\$(git -C '$wc' show --name-only --format= HEAD)\" = binaries/scx/upstream.env ] && grep -qx 'UPSTREAM_TAG=v1.1.5' '$wc/binaries/scx/upstream.env' && grep -qx 'UPSTREAM_COMMIT=$(printf 'b%.0s' {1..40})' '$wc/binaries/scx/upstream.env' && [[ \"\$(git -C '$wc' log -1 --format=%b | sed -n 1p)\" == 'scx | v1.1.4 | v1.1.5 | https://github.com/o/p/compare/v1.1.4...v1.1.5 | '* ]]"
fresh; run scx REL=v1.1.4
check "scx, the pin is the latest release: nothing to bump, no commit" moved 0

# ---- the Homebrew files image
fresh; run brew TAGS='"20261108","20261115","latest","20261101"'
check "brew, a newer dated tag: just brew-bump <that tag> (the recipe is the pin writer: its cosign check runs) decides, ONE commit changes only the Containerfile pin lines and ends with the table row" bash -c "[ $rc = 0 ] && grep -q '^just brew-bump 20261115' '$GH_LOG' && [ \"\$(git -C '$wc' show --name-only --format= HEAD)\" = Containerfile ] && grep -qx 'ARG BREW_TAG=20261115' '$wc/Containerfile' && [[ \"\$(git -C '$wc' log -1 --format=%b | sed -n 1p)\" == 'brew | 20261108 | 20261115 | ghcr.io/ublue-os/brew:20261115'*'| unknown' ]] && [ \$(git -C '$wc' rev-list --count origin/testing..HEAD) = 1 ]"
fresh; run brew TAGS='"20261108","20261101"'
check "brew, the pin is already the newest tag: nothing to bump, no commit" bash -c "[ $rc = 0 ] && ! grep -q 'brew-bump' '$GH_LOG' && grep -q 'nothing to bump' '$root/run'" && moved 0
fresh; run brew TAGS='"20261001","20261101"'
check "brew, an OLDER newest tag than the pin is never proposed" bash -c "[ $rc = 0 ] && ! grep -q 'brew-bump' '$GH_LOG'"
fresh; run brew TAGS='"20261115"' JUST_FAIL=1
check "brew, the signature (or digest) does not verify: the pin FAILS (exit 1), no commit, the tree is clean" bash -c "[ $rc = 1 ] && grep -q 'FAILED' '$root/run'" && moved 0 && clean
fresh; run brew SKOPEO_FAIL=1
check "brew, the registry cannot be reached: the pin fails and changes nothing" bash -c "[ $rc = 1 ] && grep -q 'cannot list the tags' '$root/run'" && moved 0

# ---- the Fedora builder digest
fresh; run builder MANIFEST=new CREATED="$old10"
check "builder, a new digest of the same major that is 10 days old: ONE commit changing only builder.env, the major stays 45, the row carries the age (10)" bash -c "[ $rc = 0 ] && [ \"\$(git -C '$wc' show --name-only --format= HEAD)\" = binaries/builder.env ] && grep -q '^BUILDER=registry.fedoraproject.org/fedora:45@sha256:[0-9a-f]\{64\}\$' '$wc/binaries/builder.env' && ! grep -q aaaaaaaa '$wc/binaries/builder.env' && [[ \"\$(git -C '$wc' log -1 --format=%b | sed -n 1p)\" == 'builder | 45@sha256:aaaa'*'| registry.fedoraproject.org/fedora:45 | 10' ]]"
fresh; run builder MANIFEST=new CREATED="$young2"
check "builder, the new digest is only 2 days old (cooldown 7 days): nothing is proposed yet, the line says why, no commit" bash -c "[ $rc = 0 ] && grep -q 'nothing to bump yet.*2 days ago' '$root/run'" && moved 0
fresh; run builder MANIFEST=new CREATED="$young2" MIN_AGE_DAYS=1
check "builder, the cooldown is MIN_AGE_DAYS" moved 1
fresh; mfdigest=$(printf 'manifest-new' | sha256sum | cut -d' ' -f1); sed -i "s/^BUILDER=.*/BUILDER=registry.fedoraproject.org\/fedora:45@sha256:$mfdigest/" "$wc/binaries/builder.env"; git -C "$wc" commit -q -am same; git -C "$wc" push -q origin testing; : >"$GH_LOG"
run builder MANIFEST=new CREATED="$old10"
check "builder, the pin is already the current digest: nothing to bump" bash -c "[ $rc = 0 ] && grep -q 'nothing to bump' '$root/run'" && moved 0
fresh; run builder SKOPEO_FAIL=1 CREATED="$old10"
check "builder, the registry cannot be reached: the pin fails and changes nothing" bash -c "[ $rc = 1 ]" && moved 0
fresh; echo 'BUILDER=registry.fedoraproject.org/fedora:45' >"$wc/binaries/builder.env"; git -C "$wc" commit -q -am bad; git -C "$wc" push -q origin testing
run builder MANIFEST=new CREATED="$old10"
check "builder, a builder.env without a digest pin fails" bash -c "[ $rc = 1 ] && grep -q 'digest-pinned' '$root/run'"
run nosuchpin
check "an unknown pin fails" test "$rc" = 1
fresh; echo dirty >>"$wc/Containerfile"; run brew TAGS='"20261115"'
check "a dirty working tree is refused before anything is written" bash -c "[ $rc = 1 ] && ! grep -q 'brew-bump' '$GH_LOG'"

# ---- the weekly orchestrator: pins brew and builder with stub registries
weekly() { (cd "$wc" && env "$@" BUMP_PINS="${PINS:-brew builder}" PATH="$bin:$PATH" bash .github/scripts/bump-weekly.sh) >"$root/run" 2>&1; rc=$?; }
heads() { git -C "$root/origin.git" for-each-ref --format='%(refname:short)' refs/heads/ | grep -v '^testing$'; }
fresh; weekly TAGS='"20261108","20261115"' MANIFEST=new CREATED="$old10"
check "weekly, two pins moved: ONE branch bump/weekly-<day> (no per-pin branch) with ONE commit per pin, each touching only its own pin file" bash -c "[ $rc = 0 ] && [ \"\$(git -C '$root/origin.git' for-each-ref --format='%(refname:short)' refs/heads/ | grep -v '^testing\$')\" = bump/weekly-$day ] && [ \$(git -C '$root/origin.git' rev-list --count testing..bump/weekly-$day) = 2 ] && [ \"\$(git -C '$root/origin.git' diff --name-only testing bump/weekly-$day | LC_ALL=C sort | tr '\n' ' ')\" = 'Containerfile binaries/builder.env ' ] && for c in \$(git -C '$root/origin.git' rev-list testing..bump/weekly-$day); do [ \$(git -C '$root/origin.git' show --name-only --format= \$c | wc -l) = 1 ] || exit 1; done"
check "weekly: exactly ONE pull request, into testing, titled with the date and the pins, body = the table with a row per pin and how to drop a pin" bash -c "[ \$(grep -c '^gh pr create' '$GH_LOG') = 1 ] && grep -q '^gh pr create --base testing --head bump/weekly-$day --title Weekly pin bumps $(date -u +%F): brew, builder' '$GH_LOG' && grep -q '| pin | from | to | what changed upstream | days the new value has existed |' '$GH_LOG' && grep -q '| brew | 20261108 | 20261115 |' '$GH_LOG' && grep -q '| builder | 45@sha256:' '$GH_LOG' && grep -q 'revert its commit' '$GH_LOG'"
check "weekly: the checks are made for the TIP of the one branch (Test dispatched on testing with ref=<tip sha>)" bash -c "tip=\$(git -C '$root/origin.git' rev-parse bump/weekly-$day) && grep -qx \"gh workflow run test.yml --ref testing -f ref=\$tip\" '$GH_LOG'"
tip1=$(git -C "$root/origin.git" rev-parse "bump/weekly-$day")
: >"$GH_LOG"; git -C "$wc" checkout -q testing; weekly TAGS='"20261108","20261115"' MANIFEST=new CREATED="$old10" STALE_PRS="9 bump/weekly-20260101
$(printf '5 bump/weekly-%s\n' "$day")"
check "weekly, a run of the same day: a NEW branch bump/weekly-<day>-2 (the first branch keeps its tip: nothing is force-pushed or rewritten)" bash -c "[ $rc = 0 ] && git -C '$root/origin.git' rev-parse --verify bump/weekly-$day-2 && [ \$(git -C '$root/origin.git' rev-list --count testing..bump/weekly-$day-2) = 2 ] && [ \"\$(git -C '$root/origin.git' rev-parse bump/weekly-$day)\" = $tip1 ]"
check "weekly, older weekly PRs still open are closed with a comment that points at the new PR (the new branch is never closed); the new PR re-applied every pending pin" bash -c "grep -q '^gh pr close 9 --delete-branch --comment Superseded by https://github.com/o/r/pull/77' '$GH_LOG' && grep -q '^gh pr close 5 ' '$GH_LOG' && [ \$(grep -c '^gh pr close' '$GH_LOG') = 2 ] && ! grep -q 'pr close.*weekly-$day-2' '$GH_LOG'"
fresh; weekly TAGS='"20261108"' MANIFEST=x CREATED="$young2" STALE_PRS="9 bump/weekly-20260101"
check "weekly, nothing moved: no branch (local or on origin), no PR, exit 0; a stale weekly PR whose pins are all in testing is closed" bash -c "[ $rc = 0 ] && [ -z \"\$(git -C '$root/origin.git' for-each-ref --format='%(refname:short)' refs/heads/ | grep -v '^testing\$')\" ] && ! grep -q '^gh pr create' '$GH_LOG' && grep -q '^gh pr close 9 .*No pin is pending' '$GH_LOG' && grep -q 'Nothing moved' '$root/run'"
fresh; weekly TAGS='"20261115"' JUST_FAIL=1 MANIFEST=new CREATED="$old10" STALE_PRS="9 bump/weekly-20260101"
check "weekly, one pin fails and one moves: the PR carries the moved pin only, the run is RED (exit 1) so the failure is reported, the failed pin changed nothing" bash -c "[ $rc = 1 ] && [ \$(git -C '$root/origin.git' rev-list --count testing..bump/weekly-$day) = 1 ] && [ \"\$(git -C '$root/origin.git' diff --name-only testing bump/weekly-$day)\" = binaries/builder.env ] && grep -q 'Weekly pin bumps .*: builder --body' '$GH_LOG'"
fresh; weekly TAGS='"20261108"' JUST_FAIL=1 SKOPEO_FAIL=1 STALE_PRS="9 bump/weekly-20260101"
check "weekly, nothing moved and a pin failed: a stale weekly PR is NOT closed (the failed pin may still be pending there)" bash -c "[ $rc = 1 ] && ! grep -q '^gh pr close' '$GH_LOG'"
fresh; weekly DRY_RUN=1 TAGS='"20261108","20261115"' MANIFEST=new CREATED="$old10"
check "weekly, dry run: prints the would-be title, branch, commits and table; nothing is pushed, no PR, no dispatch, no close" bash -c "[ $rc = 0 ] && grep -q 'Weekly pin bumps $(date -u +%F): brew, builder' '$root/run' && grep -q '| pin | from | to |' '$root/run' && grep -q -- '- [0-9a-f]* Bump the Homebrew' '$root/run' && [ -z \"\$(git -C '$root/origin.git' for-each-ref --format='%(refname:short)' refs/heads/ | grep -v '^testing\$')\" ] && ! grep -qE '^gh (pr|workflow)' '$GH_LOG'"
fresh; git -C "$wc" commit -q --allow-empty -m "feature work"; weekly TAGS='"20261115"'
check "weekly, a real run from a checkout that is not origin/testing is refused (a feature commit must never ride into a bump PR); nothing is pushed" bash -c "[ $rc = 1 ] && grep -q 'must start from origin/testing' '$root/run' && [ -z \"\$(git -C '$root/origin.git' for-each-ref --format='%(refname:short)' refs/heads/ | grep -v '^testing\$')\" ]"
fresh; git -C "$wc" commit -q --allow-empty -m "feature work"; PINS=brew weekly DRY_RUN=1 TAGS='"20261115"'
check "weekly, dry run from a branch with other commits: only the pin commits are listed and tabled, never the feature commit or an empty row" bash -c "[ $rc = 0 ] && grep -q 'Weekly pin bumps .*: brew\$' '$root/run' && ! grep -q 'feature work' '$root/run' && ! grep -q '^|  |' '$root/run'"
fresh; weekly GH_WF_FAIL=1 TAGS='"20261115"' MANIFEST=new CREATED="$old10"
check "weekly, a failed Test dispatch is a warning, not a failure" bash -c "[ $rc = 0 ] && grep -q 'Could not dispatch the Test workflow' '$root/run'"

# ---- the workflow, the scripts and the documentation
check "no script forces a push (no --force, --force-with-lease, or a + refspec), none keeps per-pin branches or per-pin PR lookups" bash -c "! grep -nE -- '--force|git push.* \+|bump/<name>|--head bump/|gh pr list --head' '$here'/.github/scripts/bump-*.sh '$here/.github/workflows/bump-pins.yml'"
check "bump-pins.yml: Monday 07:00 UTC plus workflow_dispatch with a dry_run input; ONE job that checks out testing (dry run: the dispatched ref), fail-fast matrices and artifact plumbing are gone, minimal permissions, the default token only; upstream-check.yml is gone; the pins bump-weekly.sh runs are known to bump-run.sh and are the pins CLAUDE.md documents" python3 -I - "$here" <<'PY'
import sys, yaml, re, os
root = sys.argv[1]
t = open(root + "/.github/workflows/bump-pins.yml").read(); w = yaml.safe_load(t)
on = w.get(True) or w.get("on")
assert on["schedule"] == [{"cron": "0 7 * * 1"}] and set(on) == {"schedule", "workflow_dispatch"}
assert on["workflow_dispatch"]["inputs"]["dry_run"]["type"] == "boolean"
assert not os.path.exists(root + "/.github/workflows/upstream-check.yml")
j = w["jobs"]; assert set(j) == {"bump"}, set(j)
b = j["bump"]
assert "strategy" not in b and "upload-artifact" not in t and "download-artifact" not in t
co = [s for s in b["steps"] if "checkout" in s.get("uses", "")][0]
assert "'testing'" in co["with"]["ref"] and co["with"]["fetch-depth"] == 0
assert b["permissions"] == {"contents": "write", "pull-requests": "write", "actions": "write", "checks": "write", "packages": "read"}
assert "bump-weekly.sh" in " ".join(s.get("run", "") for s in b["steps"])
assert "BUMP_TOKEN" not in t and "secrets." not in t and "GH_TOKEN: ${{ github.token }}" in t
assert w["permissions"] == {"contents": "read"}
sh = open(root + "/.github/scripts/bump-weekly.sh").read()
pins = re.search(r'BUMP_PINS:-([a-z -]+)\}', sh).group(1).split()
run = open(root + "/.github/scripts/bump-run.sh").read()
for p in pins:
    assert re.search(r'(\s|\| )%s( \||\))' % re.escape(p), run, re.M), p
doc = open(root + "/CLAUDE.md").read()
m = re.search(r"Pins bumped by bump-pins\.yml: ([a-z, -]+)\.", doc)
assert m and [p.strip() for p in m.group(1).split(",")] == pins, (m and m.group(1), pins)
PY
check "every bump script parses" bash -c "for f in bump-weekly bump-run bump-checks bump-ghostty bump-pin; do bash -n '$here/.github/scripts/'\$f.sh || exit 1; done"
echo
echo "passed: $pass, failed: $failn"
[ "$failn" = 0 ]
