#!/usr/bin/env bash
# One issue per run for the Fedora-base gap analysis: make sure the label exists, open this run's issue, then close the older open ones with a
# comment that points to the new one (the label lists the history).
#
#   gap-issue.sh <title> <body file>      env: GH_TOKEN (issues: write), GITHUB_REPOSITORY
set -euo pipefail
title=${1:?title}
body=${2:?body file}
repo=${GITHUB_REPOSITORY:?GITHUB_REPOSITORY}
label=gap-fedora-base
gh label create "${label}" -R "${repo}" --force --color 5319e7 --description "Monthly gap analysis for a move to the official Fedora base" > /dev/null
# an issue body is limited to 65536 characters: the compact report stays far below, this is only the guard
head -c 60000 "${body}" > "${body}.cut" && mv "${body}.cut" "${body}"
old=$(gh issue list -R "${repo}" --label "${label}" --state open --limit 100 --json number --jq '.[].number')
url=$(gh issue create -R "${repo}" --title "${title}" --label "${label}" --body-file "${body}")
echo "Issue: ${url}"
for n in ${old}; do
    gh issue comment "${n}" -R "${repo}" --body "Superseded by ${url}" > /dev/null
    gh issue close "${n}" -R "${repo}" > /dev/null
done
exit 0
