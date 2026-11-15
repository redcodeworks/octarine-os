#!/usr/bin/env bash
# Tests for the consolidated weekly bump: the shared pull request helper (.github/scripts/bump-pr.sh), the runner of one pin (bump-run.sh: the new
# Homebrew files image and Fedora builder kinds with stub registry answers), the summary table and the workflow (the pins it lists are the pins CLAUDE.md
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
    "pr list") cat "${PR_LIST:-/dev/null}" ;;
    "pr create") echo "https://github.com/o/r/pull/${NEW_PR:-77}" ;;
    "pr edit") exit 0 ;;
    "pr view") if [[ "$*" == *statusCheckRollup* ]]; then echo "${ROLLUP_N:-}"; else echo "https://github.com/o/r/pull/$3"; fi ;;
    "workflow run") [ -z "${GH_WF_FAIL:-}" ] ;;
    *) exit 99 ;;
esac
F
chmod +x "$bin/gh"

mkrepo() { # dir: a working copy with a bare origin, the scripts, a builder.env and a Containerfile
    local wc=$1
    rm -rf "$wc" "$root/origin.git"; git init -q --bare -b testing "$root/origin.git"
    mkdir -p "$wc/.github/scripts" "$wc/binaries/lib" "$wc/keys"
    cp "$here"/.github/scripts/bump-pr.sh "$here"/.github/scripts/bump-checks.sh "$here"/.github/scripts/bump-run.sh "$wc/.github/scripts/"
    printf 'BUILDER=registry.fedoraproject.org/fedora:45@sha256:%s\n' "$(printf 'a%.0s' {1..64})" >"$wc/binaries/builder.env"
    printf 'ARG BREW_TAG=20261108\nARG BREW_DIGEST=sha256:%s\nFROM x\n' "$(printf 'b%.0s' {1..64})" >"$wc/Containerfile"
    git -C "$wc" init -q -b testing; git -C "$wc" add -A; git -C "$wc" commit -q -m base; git -C "$wc" remote add origin "$root/origin.git"; git -C "$wc" push -q origin testing
}
wc="$root/wc"
# ---- the shared helper
mkrepo "$wc"; : >"$GH_LOG"; printf 'body text\n' >"$root/body.md"; : >"$root/prlist"
pr() { (cd "$wc" && PR_LIST="$root/prlist" PATH="$bin:$PATH" REPO_ROOT="$wc" bash .github/scripts/bump-pr.sh "$@") >"$root/run" 2>&1; rc=$?; }
w1="sed -i s/^BUILDER=.*/BUILDER=new1/ binaries/builder.env"
pr --branch bump/builder --title "Bump the builder to one" --body-file "$root/body.md" --message "m1" --file binaries/builder.env -- $w1
check "helper, new PR: the branch is pushed with ONE commit that changes only the listed pin file, the PR is created into testing with the body and the by-hand note, Test is dispatched on the branch, action=opened" bash -c "[ $rc = 0 ] && [ \"\$(git -C '$root/origin.git' diff --name-only testing bump/builder)\" = binaries/builder.env ] && [ \$(git -C '$root/origin.git' log --format=%s testing..bump/builder | wc -l) = 1 ] && grep -q '^gh pr create --base testing --head bump/builder --title Bump the builder to one' '$GH_LOG' && grep -q 'body text' '$GH_LOG' && grep -qE 'gh workflow run test.yml --ref testing -f ref=[0-9a-f]{40}' '$GH_LOG' && grep -qx 'action=opened' '$root/run'"
printf '{"number":5,"title":"Bump the builder to one"}\n' >"$root/prlist"; : >"$GH_LOG"
pr --branch bump/builder --title "Bump the builder to one" --body-file "$root/body.md" --message "m1" --file binaries/builder.env -- $w1
check "helper, same title already open: nothing happens (no commit, no PR call, no dispatch), action=noop" bash -c "[ $rc = 0 ] && ! grep -qE '^gh (pr (create|edit)|workflow run)' '$GH_LOG' && grep -qx 'action=noop' '$root/run' && grep -qx 'pr_number=5' '$root/run'"
wr="sed -i s/^BUILDER=.*/BUILDER=repair1/ binaries/builder.env"
: >"$root/prlist"; pr --branch bump/repair --title "Bump the builder to repair" --body-file "$root/body.md" --message "mr" --file binaries/builder.env -- $wr
before=$(git -C "$root/origin.git" rev-list --count testing..bump/repair)
printf '{"number":5,"title":"Bump the builder to repair"}\n' >"$root/prlist"; : >"$GH_LOG"
ROLLUP_N=0 pr --branch bump/repair --title "Bump the builder to repair" --body-file "$root/body.md" --message "mr" --file binaries/builder.env -- $wr
check "helper, same title open but the PR has no test check (its commit already had a check suite): one EMPTY commit on the branch (no force-push, pin unchanged) and the checks are dispatched for the new commit" bash -c "[ $rc = 0 ] && [ \$(git -C '$root/origin.git' rev-list --count testing..bump/repair) = $((before + 1)) ] && [ -z \"\$(git -C '$root/origin.git' diff --name-only bump/repair~1 bump/repair)\" ] && grep -qE '^gh workflow run test.yml --ref testing -f ref=[0-9a-f]{40}\$' '$GH_LOG' && ! grep -qE '^gh pr (create|edit)' '$GH_LOG'"
w2="sed -i s/^BUILDER=.*/BUILDER=new2/ binaries/builder.env"
printf '{"number":5,"title":"Bump the builder to one"}\n' >"$root/prlist"; : >"$GH_LOG"
pr --branch bump/builder --title "Bump the builder to two" --body-file "$root/body.md" --message "m2" --file binaries/builder.env -- $w2
check "helper, an older version open: the PR is edited (not duplicated), the branch gets a second commit, never a force-push, the new pin is on the branch" bash -c "[ $rc = 0 ] && grep -q '^gh pr edit 5 --title Bump the builder to two' '$GH_LOG' && ! grep -q 'pr create' '$GH_LOG' && [ \$(git -C '$root/origin.git' log --format=%s testing..bump/builder | wc -l) = 2 ] && git -C '$root/origin.git' show bump/builder:binaries/builder.env | grep -qx BUILDER=new2 && grep -qx 'action=updated' '$root/run'"
: >"$root/prlist"; : >"$GH_LOG"
pr --branch bump/builder --title "Bump the builder to two" --body-file "$root/body.md" --message "m2" --file binaries/builder.env -- $w2
check "helper, the branch exists without a PR: it is brought current, no new commit when it already carries the pin, a PR is opened" bash -c "[ $rc = 0 ] && grep -q '^gh pr create' '$GH_LOG' && [ \$(git -C '$root/origin.git' log --format=%s testing..bump/builder | wc -l) = 2 ]"
pr --branch bump/x --title t --body-file "$root/body.md" --message m --file binaries/builder.env -- sed -i 's/^ARG BREW_TAG=.*/ARG BREW_TAG=1/' Containerfile
check "helper: a writer that changes a file other than the listed pin files is refused and nothing is pushed" bash -c "[ $rc != 0 ] && grep -q 'not one of the pin files' '$root/run' && ! git -C '$root/origin.git' rev-parse --verify bump/x"
: >"$GH_LOG"; GH_WF_FAIL=1 pr --branch bump/y --title ty --body-file "$root/body.md" --message m --file binaries/builder.env -- sed -i 's/^BUILDER=.*/BUILDER=y/' binaries/builder.env
check "helper: a failed Test dispatch is a warning, not a failure" bash -c "[ $rc = 0 ] && grep -q 'Could not dispatch the Test workflow on bump/y' '$root/run'"
pr --branch main --title t --body-file "$root/body.md" --message m --file f -- true
check "helper: only bump/ branches are accepted" test "$rc" = 2

# ---- stub registry tools for the runner
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
run() { local pin=$1; shift; mkdir -p "$root/rows"; rm -f "$root/rows/$pin.tsv"; (cd "$wc" && env "$@" PR_LIST="$root/prlist" PATH="$bin:$PATH" BUMP_ROW_DIR="$root/rows" bash .github/scripts/bump-run.sh "$pin") >"$root/run" 2>&1; rc=$?; row=$(cat "$root/rows/$pin.tsv" 2>/dev/null); }
now=$(date -u +%Y-%m-%dT%H:%M:%SZ); old10=$(date -u -d '10 days ago' +%Y-%m-%dT%H:%M:%SZ); young2=$(date -u -d '2 days ago' +%Y-%m-%dT%H:%M:%SZ)
fresh() { mkrepo "$wc"; : >"$GH_LOG"; : >"$root/prlist"; }

# ---- the Homebrew files image
fresh; run brew TAGS='"20261108","20261115","latest","20261101"'
check "brew, a newer dated tag: just brew-bump <that tag> (the recipe is the pin writer: its cosign check runs) decides, ONE PR on bump/brew changes only the Containerfile pin lines, the row says ok with the PR" bash -c "[ $rc = 0 ] && grep -q '^just brew-bump 20261115' '$GH_LOG' && grep -q '^gh pr create --base testing --head bump/brew' '$GH_LOG' && [ \"\$(git -C '$root/origin.git' diff --name-only testing bump/brew)\" = Containerfile ] && git -C '$root/origin.git' show bump/brew:Containerfile | grep -qx 'ARG BREW_TAG=20261115' && [[ \"$row\" == brew*20261108*20261115*'#77'*ok* ]]"
fresh; run brew TAGS='"20261108","20261101"'
check "brew, the pin is already the newest tag: nothing to bump, no PR, status ok" bash -c "[ $rc = 0 ] && ! grep -q 'pr create' '$GH_LOG' && [[ \"$row\" == *'nothing to bump'*ok* ]]"
fresh; run brew TAGS='"20261001","20261101"'
check "brew, an OLDER newest tag than the pin is never proposed" bash -c "[ $rc = 0 ] && ! grep -q 'brew-bump' '$GH_LOG' && ! grep -q 'pr create' '$GH_LOG'"
fresh; run brew TAGS='"20261115"' JUST_FAIL=1
check "brew, the signature (or digest) does not verify: the pin job FAILS (exit 1), no branch, no PR, the row says failed" bash -c "[ $rc = 1 ] && ! grep -q 'pr create' '$GH_LOG' && ! git -C '$root/origin.git' rev-parse --verify bump/brew && [[ \"$row\" == *failed* ]]"
fresh; run brew SKOPEO_FAIL=1
check "brew, the registry cannot be reached: the pin job fails and changes nothing" bash -c "[ $rc = 1 ] && [[ \"$row\" == *failed*'cannot list the tags'* ]] && ! grep -q 'pr create' '$GH_LOG'"

# ---- the Fedora builder digest
fresh; run builder MANIFEST=new CREATED="$old10"
check "builder, a new digest of the same major that is 10 days old: ONE PR on bump/builder changing only builder.env, the major stays 45, the body says every component rebuilds" bash -c "[ $rc = 0 ] && [ \"\$(git -C '$root/origin.git' diff --name-only testing bump/builder)\" = binaries/builder.env ] && git -C '$root/origin.git' show bump/builder:binaries/builder.env | grep -q '^BUILDER=registry.fedoraproject.org/fedora:45@sha256:[0-9a-f]\{64\}\$' && ! git -C '$root/origin.git' show bump/builder:binaries/builder.env | grep -q aaaaaaaa && grep -q 'EVERY binaries component' '$GH_LOG' && [[ \"$row\" == builder*ok* ]]"
fresh; run builder MANIFEST=new CREATED="$young2"
check "builder, the new digest is only 2 days old (cooldown 7 days): nothing is proposed yet, the row says why, no PR" bash -c "[ $rc = 0 ] && ! grep -q 'pr create' '$GH_LOG' && [[ \"$row\" == *'nothing to bump yet'*ok*'2 days ago'* ]]"
fresh; run builder MANIFEST=new CREATED="$young2" MIN_AGE_DAYS=1
check "builder, the cooldown is MIN_AGE_DAYS" bash -c "[ $rc = 0 ] && grep -q 'pr create' '$GH_LOG'"
fresh; mfdigest=$(printf 'manifest-new' | sha256sum | cut -d' ' -f1); sed -i "s/^BUILDER=.*/BUILDER=registry.fedoraproject.org\/fedora:45@sha256:$mfdigest/" "$wc/binaries/builder.env"; git -C "$wc" commit -q -am same; git -C "$wc" push -q origin testing; : >"$GH_LOG"
run builder MANIFEST=new CREATED="$old10"
check "builder, the pin is already the current digest: nothing to bump, no PR" bash -c "[ $rc = 0 ] && ! grep -q 'pr create' '$GH_LOG' && [[ \"$row\" == *'nothing to bump'*ok* ]]"
fresh; run builder SKOPEO_FAIL=1 CREATED="$old10"
check "builder, the registry cannot be reached: the pin job fails and changes nothing" bash -c "[ $rc = 1 ] && [[ \"$row\" == *failed* ]] && ! grep -q 'pr create' '$GH_LOG'"
fresh; echo 'BUILDER=registry.fedoraproject.org/fedora:45' >"$wc/binaries/builder.env"; git -C "$wc" commit -q -am bad; git -C "$wc" push -q origin testing
run builder MANIFEST=new CREATED="$old10"
check "builder, a builder.env without a digest pin fails" bash -c "[ $rc = 1 ] && [[ \"$row\" == *'digest-pinned'* ]]"
run nosuchpin
check "an unknown pin fails" test "$rc" = 1

# ---- the summary table
rows="$root/rows2"; mkdir -p "$rows"
printf 'scx\tv1\tv2\t#9\tok\t\n' >"$rows/scx.tsv"; printf 'brew\t1\t2\t-\tfailed\tcannot list the tags\n' >"$rows/brew.tsv"
(bash "$here/.github/scripts/bump-summary.sh" "$rows" scx extest brew) >"$root/run" 2>&1; rc=$?
check "summary: one table pin | current | proposed | PR | status, a failed row and a pin without a row (its job did not finish) make the run fail" bash -c "[ $rc = 1 ] && grep -q '^| pin | current | proposed | PR | status |' '$root/run' && grep -q '^| scx | v1 | v2 | #9 | ok |' '$root/run' && grep -q 'failed: cannot list the tags' '$root/run' && grep -q '^| extest .*failed: no result' '$root/run'"
printf 'extest\tx\tnothing to bump\t-\tok\tnote\n' >"$rows/extest.tsv"; printf 'brew\t1\t1\t-\tok\t\n' >"$rows/brew.tsv"
(bash "$here/.github/scripts/bump-summary.sh" "$rows" scx extest brew) >"$root/run" 2>&1; rc=$?
check "summary: all rows ok: exit 0" test "$rc" = 0

# ---- the workflow and the documentation
check "bump-pins.yml: ONE workflow, Monday 07:00 UTC plus workflow_dispatch, jobs sources, digests, external and a summary that runs always; every matrix has fail-fast off, checks out testing, permissions are minimal per job, the default token only; upstream-check.yml is gone; the pins of the matrices are the pins of the summary and of CLAUDE.md" python3 -I - "$here" <<'PY'
import sys, yaml, re, os
root = sys.argv[1]
t = open(root + "/.github/workflows/bump-pins.yml").read(); w = yaml.safe_load(t)
on = w.get(True) or w.get("on")
assert on["schedule"] == [{"cron": "0 7 * * 1"}] and "workflow_dispatch" in on and set(on) == {"schedule", "workflow_dispatch"}
assert not os.path.exists(root + "/.github/workflows/upstream-check.yml")
j = w["jobs"]; assert set(j) == {"sources", "digests", "external", "summary"}, set(j)
pins = []
for k in ("sources", "digests", "external"):
    assert j[k]["strategy"]["fail-fast"] is False
    assert any("ref" in s.get("with", {}) and s["with"]["ref"] == "testing" for s in j[k]["steps"] if "checkout" in s.get("uses", ""))
    assert j[k]["permissions"]["contents"] == "write" and j[k]["permissions"]["pull-requests"] == "write"
    pins += j[k]["strategy"]["matrix"]["pin"]
assert j["summary"]["if"] == "always()" and j["summary"]["permissions"] == {"contents": "read"}
call = [s for s in j["summary"]["steps"] if "bump-summary.sh" in s.get("run", "")][0]["run"]
assert call.split("bump-summary.sh")[1].split()[1:] == pins, (call, pins)
assert "BUMP_TOKEN" not in t and "secrets." not in t and "GH_TOKEN: ${{ github.token }}" in t
assert w["permissions"] == {"contents": "read"}
doc = open(root + "/CLAUDE.md").read()
m = re.search(r"Pins bumped by bump-pins\.yml: ([a-z, -]+)\.", doc)
assert m and [p.strip() for p in m.group(1).split(",")] == pins, (m and m.group(1), pins)
assert "bump/brew" in doc and "bump/builder" in doc
PY
check "every script parses and the runner knows exactly the pins of the workflow" bash -c "for f in bump-pr bump-run bump-summary; do bash -n '$here/.github/scripts/'\$f.sh || exit 1; done"
echo
echo "passed: $pass, failed: $failn"
[ "$failn" = 0 ]
