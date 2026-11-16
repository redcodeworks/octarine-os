#!/usr/bin/env bash
# Move the bare `latest` tag of the default image and the dx image TOGETHER, after both were verified, or (the escape hatch) of the default
# image alone. Nothing else in the pipeline writes `latest` of these two images any more: main builds and promotions publish dated tags
# (`latest-<sha7>`, `latest-<date>-<sha7>`, `<date>-<sha7>`, and the same-day aliases), dx builds on a handed-over digest, and this script
# is the one step that makes a pair visible to `bootc upgrade`. A signature belongs to a digest, so a retag needs no new signature.
#
# Environment
#   OWNER            repository owner (the images are ghcr.io/<owner>/octarine-os and octarine-os-dx)
#   SCOPE            both (default) | vanilla-only
#   VANILLA_DIGEST   the default image to publish (called from the dx run); empty = resolve it from VANILLA_TAG
#   DX_DIGEST        the dx image built or promoted for it; empty = the dx image already under `latest` (dx was skipped)
#   VANILLA_TAG      dispatch only: a dated tag of the default image (latest-<sha7>, latest-<date>-<sha7>, <date>-<sha7>); empty = the newest
#                    commit of main (first parent) that has a published latest-<sha7>
#   MAIN_REF         the ref that holds main's history (default origin/main), MAX_WALK (default 60)
#   DRY_RUN          true = plan and report only; WRITE must be true for any write (the workflow sets it only on main)
#   ALLOW_BACKWARDS  true = a ROLLBACK (rollback-latest.yml): the ordering guard is skipped, so an older verified pair may be put under `latest`;
#                    everything else (signatures, the pairing rule, the main-commit rule, the order dx then default image) is unchanged
#   REASON           free text for the summary; GITHUB_STEP_SUMMARY, GITHUB_OUTPUT (moved=true|false) are used when set
# Tools: skopeo, cosign (cosign.pub in the current directory), jq, git (history of main), the helper registry-digest.sh.
#
# What it refuses (exit 1) and what it holds back (exit 0 with a notice):
#   * a tag that is not a dated tag of the default image (testing-*, beta*, latest itself, anything else);
#   * an image without a valid signature (cosign.pub), a dx image whose label org.opencontainers.image.base.digest is not the default
#     image's digest (the pairing rule), a default image whose label org.opencontainers.image.revision is not a commit of main;
#   * HELD, not failed: a candidate OLDER than what `latest` is now (a re-run of an old green run must not move `latest` backwards):
#     the commit of the candidate is an ancestor of the commit under `latest`, or it is the same commit built earlier (label created).
# Idempotent: a target that already has the digest is left alone; nothing new = a green no-op.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
owner="${OWNER:?OWNER}"; owner="${owner,,}"
scope="${SCOPE:-both}"
[[ "${scope}" == both || "${scope}" == vanilla-only ]] || { echo "::error::SCOPE must be both or vanilla-only"; exit 2; }
vimg="ghcr.io/${owner}/octarine-os"
dimg="ghcr.io/${owner}/octarine-os-dx"
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

# ---- 1. the candidate pair
V="${VANILLA_DIGEST:-}"
E="${DX_DIGEST:-}"
vtag=""
if [[ -z "${V}" ]]; then
    vtag="${VANILLA_TAG:-}"
    if [[ -n "${vtag}" ]]; then
        [[ "${vtag}" =~ ${tag_re} ]] || fail "'${vtag}' is not a dated tag of ${vimg} (latest-<sha7>, latest-<date>-<sha7> or <date>-<sha7>); testing-*, beta* and latest are refused"
        rc=0; V=$(tag_digest "${vimg}" "${vtag}") || rc=$?
        [[ "${rc}" == 0 ]] || { [[ "${rc}" == 3 ]] && fail "${vimg}:${vtag} does not exist"; read_error "${vimg}:${vtag}"; }
    else
        n=0
        for c in $(git rev-list --first-parent --max-count="${max_walk}" "${main_ref}"); do
            t="latest-$(git rev-parse --short=7 "${c}")"
            rc=0; d=$(tag_digest "${vimg}" "${t}") || rc=$?
            if [[ "${rc}" == 0 ]]; then V="${d}"; vtag="${t}"; break; fi
            [[ "${rc}" == 3 ]] || read_error "${vimg}:${t}"
            n=$((n + 1))
        done
        [[ -n "${V}" ]] || fail "no published latest-<sha7> within the newest ${max_walk} commits of ${main_ref}"
    fi
fi
[[ "${V}" =~ ${digest_re} ]] || fail "'${V}' is not a sha256 digest"
[[ -z "${E}" || "${E}" =~ ${digest_re} ]] || fail "'${E}' is not a sha256 digest"

if [[ "${scope}" == both ]]; then
    if [[ -z "${E}" && -n "${VANILLA_DIGEST:-}" ]]; then
        # called from a dx run that built nothing (unchanged): the dx image under latest must be the one on this default image
        rc=0; E=$(tag_digest "${dimg}" latest) || rc=$?
        [[ "${rc}" == 0 ]] || { [[ "${rc}" == 3 ]] && fail "dx was skipped but ${dimg}:latest does not exist"; read_error "${dimg}:latest"; }
    elif [[ -z "${E}" ]]; then
        # dispatched alone: the newest dx build made on this default image
        for t in $(skopeo list-tags "docker://${dimg}" 2> /dev/null | jq -r '.Tags[]' | grep -E '^latest-[0-9]{8}-[0-9a-f]{7}$' | sort -r | head -n 20); do
            rc=0; d=$(tag_digest "${dimg}" "${t}") || rc=$?
            [[ "${rc}" == 0 ]] || { [[ "${rc}" == 3 ]] && continue; read_error "${dimg}:${t}"; }
            if [[ "$(label "${dimg}" "${d}" "${l_base}")" == "${V}" ]]; then E="${d}"; break; fi
        done
        [[ -n "${E}" ]] || fail "no dx image was built on ${V}: build dx first (scope vanilla-only skips that requirement)"
    fi
fi

# ---- 2. verification
must_be_signed "${vimg}@${V}"
rev=$(label "${vimg}" "${V}" "${l_rev}")
is_commit "${rev}" || fail "${vimg}@${V}: its revision label '${rev}' is not a commit of this repository"
git merge-base --is-ancestor "${rev}" "${main_ref}" || fail "${vimg}@${V} was built from ${rev}, which is not on ${main_ref}: only images built from main are published as latest"
if [[ "${scope}" == both ]]; then
    must_be_signed "${dimg}@${E}"
    [[ "$(label "${dimg}" "${E}" "${l_base}")" == "${V}" ]] || fail "${dimg}@${E} was not built on ${V} (its base digest label is '$(label "${dimg}" "${E}" "${l_base}")')"
fi

# ---- 3. ordering guard: never move latest backwards
# older <image> <candidate digest> <current digest> -> 0 when the candidate is older than the current one
older() {
    local img=$1 cand=$2 cur=$3 cr ur cc uc
    # `|| exit 1`: older() runs in a condition, where set -e does not stop the script; an unreadable label must fail the run, never skip the ordering guard
    cr=$(label "${img}" "${cand}" "${l_rev}") || exit 1; ur=$(label "${img}" "${cur}" "${l_rev}") || exit 1
    cc=$(label "${img}" "${cand}" "${l_created}") || exit 1; uc=$(label "${img}" "${cur}" "${l_created}") || exit 1
    if ! is_commit "${ur}"; then echo "::warning::the image under ${img}:latest has no usable revision label (${ur:-none}): the ordering guard cannot compare" >&2; return 1; fi
    if [[ "${cr}" == "${ur}" ]]; then [[ -n "${cc}" && -n "${uc}" && "${cc}" < "${uc}" ]]; return; fi
    git merge-base --is-ancestor "${cr}" "${ur}"
}
# the digest under latest now: absent (3) means none yet; a read error fails the run (it must not look like "nothing is published", which would move latest unguarded)
rc=0; Lv=$(tag_digest "${vimg}" latest) || rc=$?
[[ "${rc}" == 0 || "${rc}" == 3 ]] || read_error "${vimg}:latest"
[[ "${rc}" == 0 ]] || Lv=""
Ld=""
if [[ "${scope}" != vanilla-only ]]; then
    rc=0; Ld=$(tag_digest "${dimg}" latest) || rc=$?
    [[ "${rc}" == 0 || "${rc}" == 3 ]] || read_error "${dimg}:latest"
    [[ "${rc}" == 0 ]] || Ld=""
fi
held=""
if [[ "${back}" == true ]]; then
    echo "ROLLBACK: the ordering guard is skipped; an older verified pair may be put under latest"
elif [[ -n "${Lv}" && "${Lv}" != "${V}" ]] && older "${vimg}" "${V}" "${Lv}"; then held="${vimg}:latest (${Lv}) is newer than the candidate ${V}"; fi
if [[ "${back}" != true && "${scope}" == both && -n "${Ld}" && "${Ld}" != "${E}" ]] && older "${dimg}" "${E}" "${Ld}"; then held="${dimg}:latest (${Ld}) is newer than the candidate ${E}"; fi
if [[ -n "${held}" ]]; then
    summary "latest held: ${held}; nothing was moved${reason:+ (reason: ${reason})}"
    exit 0
fi

# ---- 4. plan
plan=()
[[ "${Lv}" == "${V}" ]] || plan+=("${vimg}: latest ${Lv:-none} -> ${V} (${vtag:-from the dx run}, main commit ${rev:0:7})")
if [[ "${scope}" == both ]]; then
    [[ "${Ld}" == "${E}" ]] || plan+=("${dimg}: latest ${Ld:-none} -> ${E}")
fi
if [[ ${#plan[@]} -eq 0 ]]; then
    summary "latest unchanged: ${vimg}:latest is already ${V}$([[ "${scope}" == both ]] && echo " and ${dimg}:latest is already ${E}"); nothing new was built"
    exit 0
fi
if [[ "${dry}" == true || "${write}" != true ]]; then
    summary "DRY RUN (${dry}, write allowed: ${write}): would move latest:"
    for p in "${plan[@]}"; do summary "  ${p}"; done
    exit 0
fi

# ---- 5. move: dx first (the proven one), the default image last; each copy is read back and verified
move() { # image digest
    "${here}/retry.sh" skopeo copy --all --preserve-digests "docker://$1@$2" "docker://$1:latest"
    # the read-back polls (a registry may show the previous manifest or fail a read for a moment right after a copy): registry-settled.sh, the same one push-tags.sh uses
    "${here}/registry-settled.sh" "$1" latest "$2" || fail "$1:latest does not show $2 after the copy"
    must_be_signed "$1:latest"
}
if [[ "${scope}" == both && "${Ld}" != "${E}" ]]; then move "${dimg}" "${E}"; fi
if [[ "${Lv}" != "${V}" ]]; then move "${vimg}" "${V}"; fi
pre=""; [[ "${back}" != true ]] || pre="ROLLBACK, "
if [[ "${scope}" == both ]]; then
    summary "${pre}latest moved: ${vimg} ${Lv:-none} -> ${V}, ${dimg} ${Ld:-none} -> ${E} (main commit ${rev:0:7})${reason:+; reason: ${reason}}"
else
    summary "${pre}latest moved (vanilla-only): ${vimg} ${Lv:-none} -> ${V} (main commit ${rev:0:7})${reason:+; reason: ${reason}}. ${dimg}:latest is NOT moved and is behind (still $(tag_digest "${dimg}" latest || echo none)); a later green dx run for this or a newer default image catches it up"
fi
out "moved=true"
