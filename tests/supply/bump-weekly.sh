#!/usr/bin/env bash
# Tests the orchestration of the weekly bump (bump-weekly.sh): one independent branch, commit and pull request per pin, an unchanged rerun, a moved upstream
# (new PR, older one closed), a stale PR, a failing pin, the dry run and the refusal to start from another checkout. Real git (a bare origin and a clone in a temp
# dir); gh, bump-run.sh and bump-checks.sh are stubs (the decisions per pin are bump-run.sh's own business). Needs: bash, git, jq. Run: tests/supply/bump-weekly.sh
set -uo pipefail
here=$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)
root=$(mktemp -d)
trap 'rm -rf -- "${root:?}"' EXIT
pass=0; failn=0; rc=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { failn=$((failn + 1)); echo "FAIL $1"; sed 's/^/     /' "$root/run" 2> /dev/null; echo "     rc=$rc"; }
check() { local d=$1; shift; if "$@" > "$root/out" 2>&1; then ok "$d"; else bad "$d"; fi; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GITHUB_REPOSITORY=o/r

# the stubs: gh keeps the open PRs in $DB/prs.json and logs creates and closes
bin="$root/bin"; mkdir -p "$bin"
cat > "$bin/gh" << 'F'
#!/usr/bin/env bash
case "$1 $2" in
    "pr list") cat "$DB/prs.json" ;;
    "pr create")
        while [[ $# -gt 0 ]]; do case "$1" in --head) head=$2; shift ;; --title) title=$2; shift ;; esac; shift; done
        n=$(( $(jq length "$DB/prs.json") + $(wc -l < "$DB/created" 2> /dev/null || echo 0) + 100 ))
        echo "$head|$title" >> "$DB/created"
        jq --argjson n "$n" --arg h "$head" '. + [{number:$n,headRefName:$h}]' "$DB/prs.json" > "$DB/p" && mv "$DB/p" "$DB/prs.json"
        echo "https://example.test/pull/$n" ;;
    "pr close") echo "$3" >> "$DB/closed"; jq --argjson n "$3" 'map(select(.number != $n))' "$DB/prs.json" > "$DB/p" && mv "$DB/p" "$DB/prs.json" ;;
esac
F
chmod +x "$bin/gh"

setup() { # a fresh origin (testing with pins.txt and the stub scripts) and a clone on testing
    rm -rf "$root/origin.git" "$root/clone"; export DB="$root/db"; rm -rf "$DB"; mkdir -p "$DB"; echo '[]' > "$DB/prs.json"
    git init -q --bare -b testing "$root/origin.git"; git clone -q "$root/origin.git" "$root/clone" 2> /dev/null
    cd "$root/clone" || exit 1
    git checkout -q -b testing 2> /dev/null; mkdir -p .github/scripts
    cp "$here/.github/scripts/bump-weekly.sh" .github/scripts/
    # the stub writer: moves its pin in pins.txt to UPSTREAM_<PIN> when that differs (UPSTREAM_<PIN>=fail: a failing check), one commit with the table row
    cat > .github/scripts/bump-run.sh << 'F'
#!/usr/bin/env bash
pin=$1; var="UPSTREAM_${pin^^}"; new=${!var}
[[ "${new}" != fail ]] || { echo "::error::${pin}: cannot read upstream"; exit 1; }
cur=$(sed -n "s/^${pin}=//p" pins.txt)
[[ "${new}" != "${cur}" ]] || { echo "${pin}: nothing to bump"; exit 0; }
sed -i "s/^${pin}=.*/${pin}=${new}/" pins.txt
git commit -q -a -m "Bump ${pin} to ${new}

${pin} | ${cur} | ${new} | upstream | 3"
F
    printf '#!/usr/bin/env bash\necho "$@" >> "$DB/checks"\n' > .github/scripts/bump-checks.sh
    chmod +x .github/scripts/*.sh; printf 'chunkah=1\nbrew=1\nbins=1\n' > pins.txt
    git add -A && git commit -q -m init && git push -q origin testing
}
run() { (cd "$root/clone" && PATH="$bin:$PATH" BUMP_CHECKS_WAIT=0 env BUMP_PINS="${BUMP_PINS:-chunkah brew bins}" "$@" bash .github/scripts/bump-weekly.sh) > "$root/run" 2>&1; rc=$?; }
branches() { git -C "$root/origin.git" for-each-ref --format='%(refname:short)' 'refs/heads/bump/*' | sort | tr '\n' ' '; }

setup; run UPSTREAM_CHUNKAH=2 UPSTREAM_BREW=1 UPSTREAM_BINS=2
check "two pins moved: two independent branches and PRs, none for the pin that did not move" bash -c "[ $rc = 0 ] && [ \"\$(wc -l < '$DB/created')\" = 2 ] && grep -q '^bump/chunkah-' '$DB/created' && grep -q '^bump/bins-' '$DB/created' && ! grep -q brew '$DB/created' && [ \"\$(wc -l < '$DB/checks')\" = 2 ]"
chk() { # each branch: exactly one commit over testing and only its own pin line changed
    for b in $(branches); do
        [ "$(git -C "$root/origin.git" rev-list --count "testing..$b")" = 1 ] || return 1
        [ "$(git -C "$root/origin.git" diff --numstat "testing" "$b" | wc -l)" = 1 ] || return 1
        git -C "$root/origin.git" diff "testing" "$b" | grep -c '^[+-][a-z]' | grep -qx 2 || return 1
    done
}
check "each branch is cut from testing: one commit, one changed pin line (no chain)" chk
check "titles name the pin and the versions and stay within 140 characters" bash -c "grep -q '^bump/chunkah-[0-9]*|Bump chunkah: 1 to 2\$' '$DB/created' && ! awk -F'|' 'length(\$2) > 140' '$DB/created' | grep -q ."
run UPSTREAM_CHUNKAH=2 UPSTREAM_BREW=1 UPSTREAM_BINS=2
check "a rerun with the same values opens nothing and closes nothing" bash -c "[ $rc = 0 ] && [ \"\$(wc -l < '$DB/created')\" = 2 ] && [ ! -e '$DB/closed' ]"
run UPSTREAM_CHUNKAH=3 UPSTREAM_BREW=1 UPSTREAM_BINS=2
check "upstream moved again for one pin: a new PR for it, the older one closed, the other pin's PR untouched" bash -c "[ $rc = 0 ] && [ \"\$(wc -l < '$DB/created')\" = 3 ] && [ \"\$(wc -l < '$DB/closed')\" = 1 ] && [ \"\$(jq '[.[]|select(.headRefName|startswith(\"bump/chunkah-\"))]|length' '$DB/prs.json')\" = 1 ] && [ \"\$(jq '[.[]|select(.headRefName|startswith(\"bump/bins-\"))]|length' '$DB/prs.json')\" = 1 ]"
# testing takes the bins bump (merged): the open bins PR is stale
cd "$root/clone" && git checkout -q testing && sed -i 's/^bins=.*/bins=2/' pins.txt && git commit -q -a -m "merged bins" && git push -q origin testing
rm -f "$DB/closed"; run UPSTREAM_CHUNKAH=3 UPSTREAM_BREW=1 UPSTREAM_BINS=2
check "a pin that testing already has: its open PR is closed as stale, nothing new is opened" bash -c "[ $rc = 0 ] && [ \"\$(wc -l < '$DB/closed')\" = 1 ] && [ \"\$(wc -l < '$DB/created')\" = 3 ] && [ \"\$(jq '[.[]|select(.headRefName|startswith(\"bump/bins-\"))]|length' '$DB/prs.json')\" = 0 ]"
setup; run UPSTREAM_CHUNKAH=fail UPSTREAM_BREW=2 UPSTREAM_BINS=2
check "a failing pin turns the run red, the other pins still get their PRs" bash -c "[ $rc != 0 ] && [ \"\$(wc -l < '$DB/created')\" = 2 ] && ! grep -q chunkah '$DB/created'"
setup; run DRY_RUN=1 UPSTREAM_CHUNKAH=2 UPSTREAM_BREW=2 UPSTREAM_BINS=1
check "dry run: lists one PR per pin, pushes and creates nothing" bash -c "[ $rc = 0 ] && [ \"\$(grep -c 'would open' '$root/run')\" = 2 ] && [ ! -e '$DB/created' ] && [ -z \"\$(git -C '$root/origin.git' for-each-ref refs/heads/bump)\" ]"
setup; cd "$root/clone" && git commit -q --allow-empty -m local; run UPSTREAM_CHUNKAH=2
check "a real run from a checkout that is not origin/testing is refused" bash -c "[ $rc != 0 ] && grep -q 'must start from origin/testing' '$root/run' && [ ! -e '$DB/created' ]"

echo; echo "passed: $pass, failed: $failn"
[ "$failn" = 0 ]
