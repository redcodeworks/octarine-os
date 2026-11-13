#!/usr/bin/env bash
# Tests for the weekly upstream check of binaries/ (.github/scripts/upstream-check.sh, bump-upstream.sh, upstream-check.yml): the
# decision table with a stub gh (equal, newer, ahead, unreachable, commit pin, fork), the bump pull request (new, already open,
# updated by a new commit, never a force-push, the Test dispatch and its soft failure) with a local origin and a stub gh, and the
# workflow (triggers, permissions, default token only). No network. Needs: bash, git, jq, python3 with PyYAML.
# Run: tests/upstream-check.sh
# shellcheck disable=SC2001,SC2013,SC2015,SC2016,SC2034
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
src="${here}/.."
pass=0
failn=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { failn=$((failn + 1)); echo "FAIL $1"; }
tmp=$(mktemp -d)
trap 'rm -rf "${tmp}"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
sha() { local s='' i; for i in {1..40}; do s+=$1; done; echo "${s}"; }

# --- the weekly upstream check with a stub gh (replies from files named after the API path)
mkdir -p "${tmp}/bin" "${tmp}/gh"
cat > "${tmp}/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "gh $*" >> "${GH_LOG}"
[[ "$1" == api ]] || exit 99
path=${2//\//_}
if [[ -f "${GH_DIR}/${path}" ]]; then cat "${GH_DIR}/${path}"; [[ ! -f "${GH_DIR}/${path}.fail" ]]; else exit 1; fi
STUB
chmod +x "${tmp}/bin/gh"
export GH_LOG="${tmp}/gh.log" GH_DIR="${tmp}/gh"
crepo="${tmp}/crepo"
mkdir -p "${crepo}/binaries/lib" "${crepo}/.github/scripts" "${crepo}/img"
cp "${src}/binaries/lib/upstream-env.sh" "${crepo}/binaries/lib/"
cp "${src}/.github/scripts/upstream-check.sh" "${crepo}/.github/scripts/"
chk() { REPO_ROOT="${crepo}" PATH="${tmp}/bin:${PATH}" "${crepo}/.github/scripts/upstream-check.sh" img; }
reply() { rm -f "${GH_DIR}"/*; : > "${GH_LOG}"; while [[ $# -gt 0 ]]; do printf '%s\n' "$2" > "${GH_DIR}/$1"; shift 2; done; }
printf 'UPSTREAM_REPO=o/p\nUPSTREAM_TAG=v1.1.4\nUPSTREAM_COMMIT=%s\n' "$(sha a)" > "${crepo}/img/upstream.env"
reply repos_o_p_releases_latest v1.1.4
[[ "$(chk)" == current* ]] && ok "check: the pinned tag is the latest release: current" || bad "check equal: $(chk)"
reply repos_o_p_releases_latest v1.1.5 repos_o_p_commits_v1.1.5 "$(sha b)"
[[ "$(chk)" == "bump v1.1.5 $(sha b)" ]] && ok "check: a newer release: bump with the tag and its commit" || bad "check newer: $(chk)"
reply repos_o_p_releases_latest v1.10.0 repos_o_p_commits_v1.10.0 "$(sha c)"
[[ "$(chk)" == "bump v1.10.0 $(sha c)" ]] && ok "check: versions compare numerically (v1.10.0 is newer than v1.1.4)" || bad "check version sort: $(chk)"
reply repos_o_p_releases_latest v1.0.9
[[ "$(chk)" == current* ]] && ok "check: a pin ahead of the latest release is current" || bad "check ahead: $(chk)"
reply
[[ "$(chk)" == unreachable* ]] && ok "check: upstream unreachable fails soft with a notice" || bad "check unreachable: $(chk)"
reply repos_o_p_releases_latest v1.1.5
[[ "$(chk)" == unreachable* ]] && ok "check: a tag that cannot be resolved to a commit fails soft" || bad "check unresolvable: $(chk)"
# commit pin
printf 'UPSTREAM_REPO=o/p\nUPSTREAM_TAG=\nUPSTREAM_COMMIT=%s\n' "$(sha a)" > "${crepo}/img/upstream.env"
reply repos_o_p_releases_latest 1.0.3 repos_o_p_commits_1.0.3 "$(sha d)" "repos_o_p_compare_$(sha a)...$(sha d)" behind
[[ "$(chk)" == report* ]] && ok "check: a commit pin with only an older release reports and opens nothing" || bad "check commit pin behind: $(chk)"
reply repos_o_p_releases_latest 1.1.0 repos_o_p_commits_1.1.0 "$(sha e)" "repos_o_p_compare_$(sha a)...$(sha e)" diverged
[[ "$(chk)" == "bump 1.1.0 $(sha e)" ]] && ok "check: a tag that is not an ancestor of the pinned commit (diverged): bump" || bad "check commit pin diverged: $(chk)"
reply repos_o_p_releases_latest 1.1.0 repos_o_p_commits_1.1.0 "$(sha e)" "repos_o_p_compare_$(sha a)...$(sha e)" ahead
[[ "$(chk)" == "bump 1.1.0 $(sha e)" ]] && ok "check: a commit pin with a release ahead of it: bump" || bad "check commit pin ahead: $(chk)"
reply repos_o_p_tags "1.2.0" repos_o_p_commits_1.2.0 "$(sha f)" "repos_o_p_compare_$(sha a)...$(sha f)" ahead
[[ "$(chk)" == "bump 1.2.0 $(sha f)" ]] && ok "check: no release object, newest tag ahead of the commit: bump" || bad "check tag only: $(chk)"
reply repos_o_p_tags ""
[[ "$(chk)" == report* ]] && ok "check: no release and no tag: report only" || bad "check no tags: $(chk)"
reply repos_o_p_releases_latest 1.0.3 repos_o_p_commits_1.0.3 "$(sha a)" "repos_o_p_compare_$(sha a)...$(sha a)" identical
[[ "$(chk)" == current* ]] && ok "check: the pinned commit is the latest release: current" || bad "check identical: $(chk)"
# a fork: UPSTREAM_REPO is our fork, UPSTREAM_WATCH the real project
printf 'UPSTREAM_REPO=f/ork\nUPSTREAM_WATCH=o/p\nUPSTREAM_TAG=\nUPSTREAM_COMMIT=%s\n' "$(sha a)" > "${crepo}/img/upstream.env"
reply repos_o_p_releases_latest 1.0.3 repos_o_p_commits_1.0.3 "$(sha d)" "repos_o_p_compare_$(sha a)...$(sha d)" behind
[[ "$(chk)" == report* ]] && ok "check (fork): the latest release is behind the pin: report, nothing to open" || bad "check fork behind: $(chk)"
reply repos_o_p_releases_latest 1.1.0 repos_o_p_commits_1.1.0 "$(sha e)" "repos_o_p_compare_$(sha a)...$(sha e)" ahead repos_f_ork main "repos_f_ork_compare_$(sha e)...main" ahead
[[ "$(chk)" == "bump 1.1.0 $(sha e)" ]] && ok "check (fork): a new release that the fork already has: bump (pin = commit, tag = label)" || bad "check fork has it: $(chk)"
reply repos_o_p_releases_latest 1.1.0 repos_o_p_commits_1.1.0 "$(sha e)" "repos_o_p_compare_$(sha a)...$(sha e)" ahead repos_f_ork main "repos_f_ork_compare_$(sha e)...main" diverged
[[ "$(chk)" == forkbehind\ 1.1.0\ "$(sha e)"* ]] && ok "check (fork): a new release the fork does not have yet: forkbehind, no bump" || bad "check fork behind upstream: $(chk)"
reply repos_o_p_releases_latest 1.1.0 repos_o_p_commits_1.1.0 "$(sha e)" "repos_o_p_compare_$(sha a)...$(sha e)" ahead repos_f_ork main
[[ "$(chk)" == forkbehind* ]] && ok "check (fork): a fork compare that fails counts as the fork being behind" || bad "check fork compare fails: $(chk)"
reply repos_o_p_releases_latest 1.1.0 repos_o_p_commits_1.1.0 "$(sha e)" "repos_o_p_compare_$(sha a)...$(sha e)" ahead
[[ "$(chk)" == unreachable* ]] && ok "check (fork): the fork itself cannot be read: fail soft" || bad "check fork unreadable: $(chk)"
printf 'UPSTREAM_REPO=f/ork\nUPSTREAM_WATCH=o/p\nUPSTREAM_TAG=1.1.0\nUPSTREAM_COMMIT=%s\n' "$(sha e)" > "${crepo}/img/upstream.env"
reply repos_o_p_releases_latest 1.1.0
[[ "$(chk)" == current* ]] && ok "check (fork): the tag label is the latest release: current" || bad "check fork label current: $(chk)"
! grep -q 'repos/f/ork/tags\|repos/f/ork/releases' "${GH_LOG}" && ok "check (fork): releases are asked of the watched project, never of the fork" || bad "check asked the fork for releases"
! grep -qE 'gh (pr|repo|release) |--method|-X ' "${GH_LOG}" && ok "check: only reads (gh api GET)" || bad "check wrote something"


# --- bump-upstream.sh: new PR, already open, older PR updated; a local origin, a stub gh, no force-push
origin="${tmp}/origin.git"
git init -q --bare -b testing "${origin}"
wc="${tmp}/wc"
mkdir -p "${wc}/binaries/lib" "${wc}/.github/scripts" "${wc}/img"
cp "${src}/binaries/lib/upstream-env.sh" "${wc}/binaries/lib/"
cp "${src}/.github/scripts/bump-upstream.sh" "${wc}/.github/scripts/"
printf '# pin\nUPSTREAM_REPO=o/p\nUPSTREAM_TAG=v1.1.4\nUPSTREAM_COMMIT=%s\n' "$(sha a)" > "${wc}/img/upstream.env"
git -C "${wc}" init -q -b testing
git -C "${wc}" add -A && git -C "${wc}" commit -q -m base
git -C "${wc}" remote add origin "${origin}"
git -C "${wc}" push -q origin testing
cat > "${tmp}/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "gh $*" >> "${GH_LOG}"
case "$1 $2" in
    "pr list") cat "${PR_LIST:-/dev/null}" ;;
    "pr create"|"pr edit") exit 0 ;;
    "workflow run") [[ -z "${GH_WF_FAIL:-}" ]] ;;
    *) exit 99 ;;
esac
STUB
bump() { PR_LIST="${tmp}/prlist" PATH="${tmp}/bin:${PATH}" REPO_ROOT="${wc}" "${wc}/.github/scripts/bump-upstream.sh" img "$@" > "${tmp}/bump.log" 2>&1; }
: > "${tmp}/prlist"; : > "${GH_LOG}"
bump v1.1.5 "$(sha b)" && ok "bump: a new PR is opened" || bad "bump new: $(cat "${tmp}/bump.log")"
grep -q '^gh pr create --base testing --head bump/img --title Bump img to v1.1.5' "${GH_LOG}" && ok "bump: PR from bump/<name> into testing, titled with the version" || bad "bump create call: $(cat "${GH_LOG}")"
body=$(cat "${GH_LOG}")
[[ "${body}" == *"releases/tag/v1.1.5"* && "${body}" == *"compare/v1.1.4...v1.1.5"* ]] && ok "bump: body links the release notes and the compare URL" || bad "bump body"
[[ "${body}" == *"gh workflow run test.yml --ref bump/img"* ]] && ok "bump: the body says how to start the checks by hand" || bad "bump body note"
grep -qx 'gh workflow run test.yml --ref bump/img' "${GH_LOG}" && ok "bump: the Test workflow is dispatched on the bump branch after the PR is created" || bad "bump dispatch: $(cat "${GH_LOG}")"
: > "${GH_LOG}"; : > "${tmp}/prlist"; GH_WF_FAIL=1 bump v1.1.5 "$(sha b)"; rc=$?
[[ ${rc} -eq 0 && "$(cat "${tmp}/bump.log")" == *"Could not dispatch the Test workflow on bump/img"* ]] && ok "bump: a failed dispatch is a warning, not a failure" || bad "bump dispatch failure (rc ${rc}): $(cat "${tmp}/bump.log")"
[[ "$(git -C "${origin}" show bump/img:img/upstream.env | grep -c "$(sha b)")" == 1 ]] && ok "bump: the branch carries the new pin" || bad "bump branch content"
[[ "$(git -C "${origin}" diff --name-only testing bump/img)" == "img/upstream.env" ]] && ok "bump: only upstream.env changes" || bad "bump diff: $(git -C "${origin}" diff --name-only testing bump/img)"
printf '{"number":7,"title":"Bump img to v1.1.5"}\n' > "${tmp}/prlist"; : > "${GH_LOG}"
bump v1.1.5 "$(sha b)" && ! grep -qE '^gh (pr (create|edit)|workflow run)' "${GH_LOG}" && ok "bump: a PR for that version is already open: nothing happens, no dispatch" || bad "bump already open"
printf '{"number":7,"title":"Bump img to v1.1.5"}\n' > "${tmp}/prlist"; : > "${GH_LOG}"
bump v1.1.6 "$(sha c)" && grep -q '^gh pr edit 7 --title Bump img to v1.1.6' "${GH_LOG}" && grep -qx 'gh workflow run test.yml --ref bump/img' "${GH_LOG}" && ok "bump: a PR for an older version is updated, not duplicated, and the checks are dispatched again" || bad "bump update: $(cat "${tmp}/bump.log")"
[[ "$(git -C "${origin}" log --format=%s testing..bump/img | wc -l)" -ge 2 && "$(git -C "${origin}" show bump/img:img/upstream.env | grep -c "$(sha c)")" == 1 ]] && ok "bump: the update is a new commit on the same branch (no force-push)" || bad "bump update commit"
! git -C "${origin}" log --format=%B bump/img | grep -qi 'co-authored-by' && ok "bump: no commit trailers" || bad "bump trailer"

# a fork: the PR links the followed project and says the pin is the fork's commit
git -C "${wc}" checkout -q testing
printf 'UPSTREAM_REPO=f/ork\nUPSTREAM_WATCH=o/p\nUPSTREAM_TAG=1.0.3\nUPSTREAM_COMMIT=%s\n' "$(sha a)" > "${wc}/img/upstream.env"
git -C "${wc}" commit -q -a -m "fork pin" && git -C "${wc}" push -q origin testing
: > "${tmp}/prlist"; : > "${GH_LOG}"
bump 1.1.0 "$(sha b)"; body=$(cat "${GH_LOG}" "${tmp}/bump.log")
[[ "${body}" == *"github.com/o/p/releases/tag/1.1.0"* && "${body}" == *"github.com/o/p/compare/1.0.3...1.1.0"* && "${body}" == *"build source is the fork"* && "${body}" == *"f/ork"* ]] && ok "bump (fork): links the followed project and says the pin is the fork's commit, the tag a label" || bad "bump fork body: ${body}"

# --- the workflow
python3 -I - "${src}" <<'PY'
import sys, yaml, pathlib
root = pathlib.Path(sys.argv[1]); wf = root / ".github/workflows"
fail = 0
def r(ok, msg):
    global fail
    print(("ok   " if ok else "FAIL ") + msg); fail += (not ok)
text = (wf / "upstream-check.yml").read_text()
up = yaml.safe_load(text); on = up.get("on", up.get(True))
r(on["schedule"] == [{"cron": "0 7 * * 1"}] and "workflow_dispatch" in on and "push" not in on and "pull_request" not in on, "upstream-check.yml: Monday 07:00 UTC plus manual dispatch only")
r("packages: write" not in text and "podman" not in text and "cosign" not in text and "ghcr.io" not in text, "upstream-check.yml: publishes nothing")
r(up["permissions"] == {"contents": "write", "pull-requests": "write", "actions": "write"}, "upstream-check.yml: contents, pull-requests and actions write only")
r("BUMP_TOKEN" not in text and "secrets." not in text and "GH_TOKEN: ${{ github.token }}" in text, "upstream-check.yml: the default token only, no personal token or secret")
r("binaries/*/upstream.env" in text and "bump-upstream.sh" in text and "upstream-check.sh" in text, "upstream-check.yml: walks every binaries/<name>/upstream.env")
r("gh repo sync" in text and "forkbehind" in text, "upstream-check.yml: a fork behind upstream is a notice and a summary line telling to sync it, not a failure")
r(up["jobs"]["check"]["name"] == "Check upstream releases", "upstream-check.yml: its job name is not a required check name")
sys.exit(1 if fail else 0)
PY
rc=$?
[[ ${rc} -eq 0 ]] || failn=$((failn + 1))

echo
echo "${pass} passed, ${failn} failed"
(( failn == 0 ))
