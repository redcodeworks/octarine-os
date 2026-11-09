#!/usr/bin/env bash
# Decide whether a SCHEDULED run may skip the image build, and print one line: `skip: ...` or `build: <reason>`.
# The decision is a pure function of its environment, so it can be tried locally (see tests/plan-skip.sh):
#
#   EVENT             github.event_name; anything but `schedule` always builds
#   REF               github.ref; the skip only applies on refs/heads/main (the default branch)
#   BASE_NOW          digest of the base image's manifest list now (sha256 of `skopeo inspect --raw`)
#   LATEST_BASE       the same digest recorded in the published `latest` (label ...base-index-digest)
#   REPO_SAME         `true` when the repository content (git tree) of main HEAD equals the commit `latest` was
#                     built from (label org.opencontainers.image.revision), else `false`
#   LATEST_CREATED    org.opencontainers.image.created of `latest` (ISO 8601)
#   NOW_EPOCH         seconds since the epoch, default: now
#   MAX_AGE_DAYS      `latest` older than this always rebuilds. 7 days because the build installs RPMs from live
#                     Fedora and RPM Fusion repositories, so package updates arrive without a base image change
#   SIGNED            `true` when `latest` has a valid signature
#
# Anything missing or unreadable means build (fail safe): an image from before the labels existed has no
# LATEST_BASE or REPO_SAME and therefore gets one normal build that records them.
set -uo pipefail

build() { echo "build: $*"; exit 0; }

[[ "${EVENT:-}" == schedule ]] || build "not a scheduled run (${EVENT:-unset})"
[[ "${REF:-}" == refs/heads/main ]] || build "not main (${REF:-unset})"
[[ -n "${BASE_NOW:-}" && -n "${LATEST_BASE:-}" ]] || build "base digest unknown (now '${BASE_NOW:-}', in latest '${LATEST_BASE:-}')"
[[ "${BASE_NOW}" == "${LATEST_BASE}" ]] || build "base image changed"
[[ "${REPO_SAME:-}" == true ]] || build "repository content differs from, or is unknown for, the commit latest was built from"
[[ -n "${LATEST_CREATED:-}" ]] || build "age of latest unknown"
created=$(date -u -d "${LATEST_CREATED}" +%s 2>/dev/null) || build "cannot read created date '${LATEST_CREATED}'"
now="${NOW_EPOCH:-$(date -u +%s)}"
max="${MAX_AGE_DAYS:-7}"
[[ "${max}" =~ ^[0-9]+$ ]] || build "MAX_AGE_DAYS is not a number"
(( now - created < max * 86400 )) || build "latest is $(( (now - created) / 86400 )) days old (limit ${max})"
[[ "${SIGNED:-}" == true ]] || build "latest is not verified as signed"
echo "skipped: base, repo and age unchanged"
