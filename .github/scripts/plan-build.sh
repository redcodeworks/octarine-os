#!/usr/bin/env bash
# Decide whether a workflow run needs the heavy image build and print `true` or `false`.
#
#   plan-build.sh <event> [<before> [<after> [<ref>]]]
#
# <event>           github.event_name
# <before>/<after>  the commit range to diff: github.event.before and github.sha for pushes (after
#                   defaults to HEAD)
# <ref>             github.ref (optional)
#
# Rules:
#   schedule, workflow_dispatch   always build
#   push                          build unless every changed file in <before>..<after> is docs-only
#                                 (see is_docs); an empty, all-zero or unknown <before> (new branch,
#                                 force push) or an empty diff builds. A push to refs/heads/testing is never skipped
#                                 here: the diff of ONE push cannot tell whether an image exists for the tip (a batch of
#                                 merges cancels the builds of the earlier pushes), so the workflow's reuse step decides
#                                 (plan-vanilla-reuse.sh: reuse only an image with equal default-image inputs, else build)
# The workflow keeps the required check names by always running an aggregate job; it never uses a
# workflow-level `paths:` filter, because required checks of a skipped workflow stay pending forever.
set -euo pipefail

# is_docs (the docs-only list) lives in docs-only.sh, the one place for it.
# shellcheck source=docs-only.sh
source "$(dirname "${BASH_SOURCE[0]}")/docs-only.sh"

event="${1:?event}"
before="${2-}"
after="${3:-HEAD}"
ref="${4-}"

case "${event}" in
    push) ;;
    schedule | workflow_dispatch) echo true; exit 0 ;;
    *) echo "unknown event '${event}'" >&2; exit 1 ;;
esac

if [[ -z "${before}" || "${before}" =~ ^0+$ ]] \
    || ! git cat-file -e "${before}^{commit}" 2>/dev/null \
    || ! git cat-file -e "${after}^{commit}" 2>/dev/null; then
    echo "no usable base commit ('${before}'): building" >&2
    echo true
    exit 0
fi

mapfile -t changed < <(git diff --name-only "${before}" "${after}")
if ((${#changed[@]} == 0)); then
    echo "empty diff: building" >&2
    echo true
    exit 0
fi
for f in "${changed[@]}"; do
    if ! is_docs "${f}"; then
        echo "non-docs file changed (${f}): building" >&2
        echo true
        exit 0
    fi
done
if [[ "${ref}" == refs/heads/testing ]]; then
    echo "only docs changed (${#changed[@]} files) on testing: the reuse check decides whether an image already covers the tip" >&2
    echo true
    exit 0
fi
echo "only docs changed (${#changed[@]} files): skipping the heavy build" >&2
echo false
