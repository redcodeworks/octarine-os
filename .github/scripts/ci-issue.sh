#!/usr/bin/env bash
# One issue per ongoing failure of the dx / `latest` publishing on main, without duplicates (deduplicated on the LABEL, not on the title).
#
#   ci-issue.sh fail      a run failed: open the issue, or add a comment to the one that is already open
#   ci-issue.sh recover   `latest` moved: comment "recovered" on the open issue and close it (nothing to do when none is open)
#
# Why it exists: a run that was started by a dispatch with the default GITHUB_TOKEN probably sends no failure e-mail to anybody
# (undocumented), and a daily failure that holds `latest` back must reach the repository owner. The issue does (owner and watchers).
#
# Environment: GH_TOKEN (permission issues: write), GITHUB_REPOSITORY, SHA (the commit of the run), CHANNEL (default latest), RUN_URL
# (default: this run), NEEDS_JSON (toJSON(needs), optional: names the failed jobs), LABEL (default ci-failure-dx), DOCS_URL
# (the CLAUDE.md section), NOW (default: today's date, for tests). Tools: gh, jq.
set -euo pipefail
mode="${1:?fail or recover}"
repo="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY}"
sha="${SHA:?SHA}"
channel="${CHANNEL:-latest}"
label="${LABEL:-ci-failure-dx}"
run_url="${RUN_URL:-${GITHUB_SERVER_URL:-https://github.com}/${repo}/actions/runs/${GITHUB_RUN_ID:-0}}"
docs="${DOCS_URL:-https://github.com/${repo}/blob/main/CLAUDE.md#promoting-the-default-and-dx-images-together}"
now="${NOW:-$(date -u +%Y-%m-%d)}"
short="${sha:0:7}"

failed=""
if [[ -n "${NEEDS_JSON:-}" ]]; then
    failed=$(jq -r 'to_entries | map(select(.value.result == "failure") | .key) | join(", ")' <<< "${NEEDS_JSON}" 2> /dev/null || true)
fi

open_issue() {
    gh issue list -R "${repo}" --label "${label}" --state open --limit 1 --json number --jq '.[0].number // empty'
}

case "${mode}" in
    fail)
        gh label create "${label}" -R "${repo}" --color B60205 --description "dx or latest was not published (one open issue at a time)" 2> /dev/null || true
        num=$(open_issue)
        if [[ -z "${num}" ]]; then
            body="The dx image of channel ${channel} (or the publication of \`latest\`) failed on main, so \`latest\` of both images stays on the previous pair.

- Run: ${run_url}
- Commit: ${sha}
- Failed job(s): ${failed:-see the run}

What you can do: re-run the failed dx run (a green re-run publishes), or, for a security fix that cannot wait, dispatch \`Publish latest\` with scope=vanilla-only (\`gh workflow run publish-latest.yml --ref main -f scope=vanilla-only -f reason=\"...\"\`). See ${docs}.

Later failures are added to this issue as comments; it closes itself when \`latest\` moves again."
            gh issue create -R "${repo}" --title "dx/latest not published: ${channel} ${short}" --label "${label}" --body "${body}"
            echo "opened an issue for ${run_url}"
        else
            gh issue comment "${num}" -R "${repo}" --body "Failed again (${now}): ${run_url} (commit ${sha}, failed job(s): ${failed:-see the run})."
            echo "commented on #${num} for ${run_url}"
        fi
        ;;
    recover)
        num=$(open_issue)
        if [[ -z "${num}" ]]; then echo "no open ${label} issue: nothing to close"; exit 0; fi
        gh issue comment "${num}" -R "${repo}" --body "recovered: ${run_url} moved \`latest\` (commit ${sha}, ${now})."
        gh issue close "${num}" -R "${repo}"
        echo "closed #${num}"
        ;;
    *) echo "usage: ci-issue.sh fail|recover" >&2; exit 2 ;;
esac
