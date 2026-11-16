#!/usr/bin/env bash
# Tests for the weekly upstream check of binaries/ (.github/scripts/upstream-check.sh): the decision table with a stub gh (equal, newer,
# ahead, unreachable, commit pin, fork). The pin writer and the commit are tested in tests/bump-run.sh. No network. Needs: bash, jq.
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
unset GITHUB_STEP_SUMMARY GITHUB_OUTPUT   # the runner sets it to a file the test user cannot write
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
export GITHUB_REPOSITORY=o/r BUMP_CHECKS_WAIT=0
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

echo
echo "${pass} passed, ${failn} failed"
(( failn == 0 ))
