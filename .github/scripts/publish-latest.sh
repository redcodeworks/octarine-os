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
l_rev="org.opencontainers.image.revision"
l_created="org.opencontainers.image.created"
l_base="org.opencontainers.image.base.digest"
digest_re='^sha256:[0-9a-f]{64}$'
tag_re='^(latest-[0-9a-f]{7}|latest-[0-9]{8}-[0-9a-f]{7}|[0-9]{8}-[0-9a-f]{7})$'

fail() { echo "::error::$*"; exit 1; }
summary() { echo "$*"; [[ -z "${GITHUB_STEP_SUMMARY:-}" ]] || echo "$*" >> "${GITHUB_STEP_SUMMARY}" 2> /dev/null || true; }
out() { [[ -z "${GITHUB_OUTPUT:-}" ]] || echo "$1" >> "${GITHUB_OUTPUT}"; }
tag_digest() { IMAGE="$1" "${here}/registry-digest.sh" "$2" 2> /dev/null; }              # image tag -> digest, fails when absent
label() { skopeo inspect --config "docker://$1@$2" 2> /dev/null | jq -r --arg k "$3" '.config.Labels[$k] // empty'; }
signed() { cosign verify --key cosign.pub "$1" > /dev/null 2>&1; }
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
        V=$(tag_digest "${vimg}" "${vtag}") || fail "${vimg}:${vtag} does not exist"
    else
        n=0
        for c in $(git rev-list --first-parent --max-count="${max_walk}" "${main_ref}"); do
            t="latest-$(git rev-parse --short=7 "${c}")"
            if d=$(tag_digest "${vimg}" "${t}"); then V="${d}"; vtag="${t}"; break; fi
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
        E=$(tag_digest "${dimg}" latest) || fail "dx was skipped but ${dimg}:latest does not exist"
    elif [[ -z "${E}" ]]; then
        # dispatched alone: the newest dx build made on this default image
        for t in $(skopeo list-tags "docker://${dimg}" 2> /dev/null | jq -r '.Tags[]' | grep -E '^latest-[0-9]{8}-[0-9a-f]{7}$' | sort -r | head -n 20); do
            d=$(tag_digest "${dimg}" "${t}") || continue
            if [[ "$(label "${dimg}" "${d}" "${l_base}")" == "${V}" ]]; then E="${d}"; break; fi
        done
        [[ -n "${E}" ]] || fail "no dx image was built on ${V}: build dx first (scope vanilla-only skips that requirement)"
    fi
fi

# ---- 2. verification
signed "${vimg}@${V}" || fail "${vimg}@${V} has no valid signature (cosign.pub)"
rev=$(label "${vimg}" "${V}" "${l_rev}")
is_commit "${rev}" || fail "${vimg}@${V}: its revision label '${rev}' is not a commit of this repository"
git merge-base --is-ancestor "${rev}" "${main_ref}" || fail "${vimg}@${V} was built from ${rev}, which is not on ${main_ref}: only images built from main are published as latest"
if [[ "${scope}" == both ]]; then
    signed "${dimg}@${E}" || fail "${dimg}@${E} has no valid signature (cosign.pub)"
    [[ "$(label "${dimg}" "${E}" "${l_base}")" == "${V}" ]] || fail "${dimg}@${E} was not built on ${V} (its base digest label is '$(label "${dimg}" "${E}" "${l_base}")')"
fi

# ---- 3. ordering guard: never move latest backwards
# older <image> <candidate digest> <current digest> -> 0 when the candidate is older than the current one
older() {
    local img=$1 cand=$2 cur=$3 cr ur cc uc
    cr=$(label "${img}" "${cand}" "${l_rev}"); ur=$(label "${img}" "${cur}" "${l_rev}")
    cc=$(label "${img}" "${cand}" "${l_created}"); uc=$(label "${img}" "${cur}" "${l_created}")
    if ! is_commit "${ur}"; then echo "::warning::the image under ${img}:latest has no usable revision label (${ur:-none}): the ordering guard cannot compare" >&2; return 1; fi
    if [[ "${cr}" == "${ur}" ]]; then [[ -n "${cc}" && -n "${uc}" && "${cc}" < "${uc}" ]]; return; fi
    git merge-base --is-ancestor "${cr}" "${ur}"
}
Lv=$(tag_digest "${vimg}" latest) || Lv=""
Ld=""
[[ "${scope}" == vanilla-only ]] || { Ld=$(tag_digest "${dimg}" latest) || Ld=""; }
held=""
if [[ -n "${Lv}" && "${Lv}" != "${V}" ]] && older "${vimg}" "${V}" "${Lv}"; then held="${vimg}:latest (${Lv}) is newer than the candidate ${V}"; fi
if [[ "${scope}" == both && -n "${Ld}" && "${Ld}" != "${E}" ]] && older "${dimg}" "${E}" "${Ld}"; then held="${dimg}:latest (${Ld}) is newer than the candidate ${E}"; fi
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
    skopeo copy --all --preserve-digests "docker://$1@$2" "docker://$1:latest"
    local got
    got=$(tag_digest "$1" latest) || fail "cannot read $1:latest after the copy"
    [[ "${got}" == "$2" ]] || fail "$1:latest is ${got}, expected $2"
    signed "$1:latest" || fail "$1:latest does not verify after the copy"
}
if [[ "${scope}" == both && "${Ld}" != "${E}" ]]; then move "${dimg}" "${E}"; fi
if [[ "${Lv}" != "${V}" ]]; then move "${vimg}" "${V}"; fi
if [[ "${scope}" == both ]]; then
    summary "latest moved: ${vimg} ${Lv:-none} -> ${V}, ${dimg} ${Ld:-none} -> ${E} (main commit ${rev:0:7})${reason:+; reason: ${reason}}"
else
    summary "latest moved (vanilla-only): ${vimg} ${Lv:-none} -> ${V} (main commit ${rev:0:7})${reason:+; reason: ${reason}}. ${dimg}:latest is NOT moved and is behind (still $(tag_digest "${dimg}" latest || echo none)); a later green dx run for this or a newer default image catches it up"
fi
out "moved=true"
