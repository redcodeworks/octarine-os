#!/usr/bin/env bash
# Move the bare `latest` tag of ONE image: the default image (octarine-os) or a variant built on it (dx or gx). Every image publishes its OWN
# `latest`, after its own signed build or its own promotion, independently of the others (2026-11-16, Kevin). Builds and promotions on main publish
# dated tags only (`latest-<sha7>`, `latest-<date>-<sha7>`, `<date>-<sha7>`, and the same-day aliases); this script is the one step that makes an
# image visible to `bootc upgrade`. A signature belongs to a digest, so a retag needs no new signature.
#
# Environment
#   OWNER            repository owner (the images are ghcr.io/<owner>/octarine-os, octarine-os-dx, octarine-os-gx)
#   IMAGE            default | dx | gx: the image whose `latest` moves (nothing else moves)
#   DIGEST           the digest to publish (called from the build run of that image); empty = resolve it from TAG
#   TAG              dispatch only: a dated tag of THAT image (latest-<sha7>, latest-<date>-<sha7>, <date>-<sha7>). Empty is allowed for the default
#                    image only: the newest commit of main (first parent) that has a published latest-<sha7>; a variant needs its tag
#   MAIN_REF         the ref that holds main's history (default origin/main), MAX_WALK (default 60)
#   DRY_RUN          true = plan and report only; WRITE must be true for any write (the workflow sets it only on main)
#   ALLOW_BACKWARDS  true = a ROLLBACK (rollback-latest.yml): the ordering guard is skipped, so an older verified image may be put under `latest`;
#                    everything else (signatures, the base rule, the main-commit rule) is unchanged
#   REASON           free text for the summary; GITHUB_STEP_SUMMARY, GITHUB_OUTPUT (moved=true|false) are used when set
# Tools: skopeo, cosign (cosign.pub in the current directory), jq, git (history of main), the helpers registry-digest.sh, registry-read.sh,
# registry-settled.sh, cosign-check.sh, retry.sh.
#
# What it refuses (exit 1) and what it holds back (exit 0 with a notice):
#   * a tag that is not a dated tag of the image (testing-*, latest itself, anything else);
#   * an image without a valid signature (cosign.pub); the default image whose label org.opencontainers.image.revision is not a commit of main;
#     a variant whose label org.opencontainers.image.base.digest is not a SIGNED default image built from main (it may be the default image's
#     `latest` or not: the images publish independently, the variant only has to stand on a default image that is itself publishable);
#   * HELD, not failed: a candidate OLDER than what that image's `latest` is now (a re-run of an old green run must not move `latest` backwards):
#     the commit of the candidate is an ancestor of the commit under `latest`, or it is the same commit built earlier (label created).
#   * an unreadable registry is a FAILURE (a read error is never "no latest yet" and never "unsigned"): nothing moves, a re-run decides again.
# Idempotent: a `latest` that already has the digest is left alone; nothing new = a green no-op.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
owner="${OWNER:?OWNER}"; owner="${owner,,}"
which="${IMAGE:?IMAGE (default, dx or gx)}"
case "${which}" in
    default) name=octarine-os ;;
    dx) name=octarine-os-dx ;;
    gx) name=octarine-os-gx ;;
    *) echo "::error::IMAGE must be default, dx or gx"; exit 2 ;;
esac
img="ghcr.io/${owner}/${name}"
bimg="ghcr.io/${owner}/octarine-os"
main_ref="${MAIN_REF:-origin/main}"
max_walk="${MAX_WALK:-60}"
dry="${DRY_RUN:-false}"
write="${WRITE:-false}"
reason="${REASON:-}"
back="${ALLOW_BACKWARDS:-false}"
l_rev="org.opencontainers.image.revision"
l_created="org.opencontainers.image.created"
l_base="org.opencontainers.image.base.digest"
digest_re='^sha256:[0-9a-f]{64}$'
tag_re='^(latest-[0-9a-f]{7}|latest-[0-9]{8}-[0-9a-f]{7}|[0-9]{8}-[0-9a-f]{7})$'
fail() { echo "::error::$*"; exit 1; }
summary() { echo "$*"; [[ -z "${GITHUB_STEP_SUMMARY:-}" ]] || echo "$*" >> "${GITHUB_STEP_SUMMARY}" 2> /dev/null || true; }
out() { [[ -z "${GITHUB_OUTPUT:-}" ]] || echo "$1" >> "${GITHUB_OUTPUT}"; }
# Registry reads: "absent" and "unreadable" are different answers (registry-read.sh). tag_digest prints the digest; exit 3 = the tag does not exist, 4 = the registry
# could not be read (retried). An unreadable `latest` is NEVER taken for "no latest": it fails the run, a re-run decides again.
tag_digest() { IMAGE="$1" "${here}/registry-digest.sh" "$2" 2> /dev/null; }
read_error() { echo "::error::could not read the registry ($1): a read error, not a missing image or tag; nothing was moved" >&2; exit 1; }
label() { local cfg; cfg=$("${here}/registry-read.sh" config "$1@$2") || read_error "labels of $1@$2"; jq -r --arg k "$3" '.config.Labels[$k] // empty' <<<"${cfg}"; }
# signed <ref>: 0 verified, 5 explicitly not verified, 4 could not be checked (retried)
signed() { "${here}/cosign-check.sh" --key cosign.pub "$1" 2> /dev/null; }
must_be_signed() { local rc=0; signed "$1" || rc=$?; [[ "${rc}" == 0 ]] && return 0; [[ "${rc}" == 4 ]] && read_error "signature of $1"; fail "$1 has no valid signature (cosign.pub)"; }
is_commit() { [[ -n "$1" ]] && git cat-file -e "$1^{commit}" 2> /dev/null; }

out "moved=false"

# ---- 1. the candidate
C="${DIGEST:-}"
ctag=""
if [[ -z "${C}" ]]; then
    ctag="${TAG:-}"
    if [[ -n "${ctag}" ]]; then
        [[ "${ctag}" =~ ${tag_re} ]] || fail "'${ctag}' is not a dated tag of ${img} (latest-<sha7>, latest-<date>-<sha7> or <date>-<sha7>); testing-* and latest are refused"
        rc=0; C=$(tag_digest "${img}" "${ctag}") || rc=$?
        [[ "${rc}" == 0 ]] || { [[ "${rc}" == 3 ]] && fail "${img}:${ctag} does not exist"; read_error "${img}:${ctag}"; }
    elif [[ "${which}" == default ]]; then
        for c in $(git rev-list --first-parent --max-count="${max_walk}" "${main_ref}"); do
            t="latest-$(git rev-parse --short=7 "${c}")"
            rc=0; d=$(tag_digest "${img}" "${t}") || rc=$?
            if [[ "${rc}" == 0 ]]; then C="${d}"; ctag="${t}"; break; fi
            [[ "${rc}" == 3 ]] || read_error "${img}:${t}"
        done
        [[ -n "${C}" ]] || fail "no published latest-<sha7> within the newest ${max_walk} commits of ${main_ref}"
    else
        fail "${img}: a dated tag is required (TAG), there is no main commit to look it up by"
    fi
fi
[[ "${C}" =~ ${digest_re} ]] || fail "'${C}' is not a sha256 digest"

# ---- 2. verification: the candidate is signed; the default image was built from main; a variant stands on such a default image
must_be_signed "${img}@${C}"
if [[ "${which}" == default ]]; then
    rev=$(label "${img}" "${C}" "${l_rev}")
    root_desc="${img}@${C}"
else
    B=$(label "${img}" "${C}" "${l_base}")
    [[ "${B}" =~ ${digest_re} ]] || fail "${img}@${C} has no usable base digest label ('${B}')"
    must_be_signed "${bimg}@${B}"
    rev=$(label "${bimg}" "${B}" "${l_rev}")
    root_desc="${bimg}@${B} (the base of ${img}@${C})"
fi
is_commit "${rev}" || fail "${root_desc}: its revision label '${rev}' is not a commit of this repository"
git merge-base --is-ancestor "${rev}" "${main_ref}" || fail "${root_desc} was built from ${rev}, which is not on ${main_ref}: only images built from main are published as latest"

# ---- 3. ordering guard: never move latest backwards
# older <candidate digest> <current digest> -> 0 when the candidate is older than the current one
older() {
    local cand=$1 cur=$2 cr ur cc uc
    # `|| exit 1`: older() runs in a condition, where set -e does not stop the script; an unreadable label must fail the run, never skip the ordering guard
    cr=$(label "${img}" "${cand}" "${l_rev}") || exit 1; ur=$(label "${img}" "${cur}" "${l_rev}") || exit 1
    cc=$(label "${img}" "${cand}" "${l_created}") || exit 1; uc=$(label "${img}" "${cur}" "${l_created}") || exit 1
    if ! is_commit "${ur}"; then echo "::warning::the image under ${img}:latest has no usable revision label (${ur:-none}): the ordering guard cannot compare" >&2; return 1; fi
    if [[ "${cr}" == "${ur}" ]]; then [[ -n "${cc}" && -n "${uc}" && "${cc}" < "${uc}" ]]; return; fi
    git merge-base --is-ancestor "${cr}" "${ur}"
}
# the digest under latest now: absent (3) means none yet; a read error fails the run (it must not look like "nothing is published", which would move latest unguarded)
rc=0; L=$(tag_digest "${img}" latest) || rc=$?
[[ "${rc}" == 0 || "${rc}" == 3 ]] || read_error "${img}:latest"
[[ "${rc}" == 0 ]] || L=""
if [[ "${back}" == true ]]; then
    echo "ROLLBACK: the ordering guard is skipped; an older verified image may be put under latest"
elif [[ -n "${L}" && "${L}" != "${C}" ]] && older "${C}" "${L}"; then
    summary "latest held: ${img}:latest (${L}) is newer than the candidate ${C}; nothing was moved${reason:+ (reason: ${reason})}"
    exit 0
fi

# ---- 4. plan
if [[ "${L}" == "${C}" ]]; then
    summary "latest unchanged: ${img}:latest is already ${C}; nothing new was built"
    exit 0
fi
plan="${img}: latest ${L:-none} -> ${C} (${ctag:-from the build run}, main commit ${rev:0:7})"
if [[ "${dry}" == true || "${write}" != true ]]; then
    summary "DRY RUN (${dry}, write allowed: ${write}): would move latest:"
    summary "  ${plan}"
    exit 0
fi

# ---- 5. move; the copy is read back and verified
"${here}/retry.sh" skopeo copy --all --preserve-digests "docker://${img}@${C}" "docker://${img}:latest"
# the read-back polls (a registry may show the previous manifest or fail a read for a moment right after a copy): registry-settled.sh, the same one push-tags.sh uses
"${here}/registry-settled.sh" "${img}" latest "${C}" || fail "${img}:latest does not show ${C} after the copy"
must_be_signed "${img}:latest"
pre=""; [[ "${back}" != true ]] || pre="ROLLBACK, "
summary "${pre}latest moved: ${plan}${reason:+; reason: ${reason}}"
out "moved=true"
