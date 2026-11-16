#!/usr/bin/env bash
# The weekly bump check of ONE pin: decide (the decision scripts of its kind) and, when something is newer, write the pin into the working tree and make ONE
# commit for it (its message ends with the row of the pull request's table: pin | from | to | what changed upstream | days the new value has existed).
# bump-weekly.sh runs every pin one after the other on one branch and opens the one pull request. Exits non-zero when the pin's check FAILED (a registry that
# cannot be reached, a signature that does not verify, a bad pin); the working tree is restored then. Prints one line per pin (also into the job summary).
# Run from the repository root on a clean checkout, with GH_TOKEN set, a git identity, and skopeo, cosign and just for the kinds that use them.
#
#   bump-run.sh scx|extest|ghostty|dev-packages|chunkah|brew|builder
#
# Kinds: source pins (upstream-check.sh and ghostty-check.sh; bump-ghostty.sh writes the Ghostty and Zig pins together), image digest pins (bump-pin.sh: the dev-packages
# list image of the fedora-toolbox repository, chunkah), the Homebrew files image (the `just brew-bump` recipe is the pin writer, so its cosign verification runs
# on every write) and the Fedora builder digest of binaries/builder.env (the same major, the newest digest of the tag once it has been the tag's value for
# MIN_AGE_DAYS, default 7: the creation date of the image is the stand-in for "has not been replaced since", a registry has no tag history).
set -uo pipefail
pin=${1:?pin name}
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
current="-" proposed="-" status="nothing to bump" files=()
say() { echo "$*"; [[ -z "${GITHUB_STEP_SUMMARY:-}" ]] || echo "- $*" >> "${GITHUB_STEP_SUMMARY}" || true; }
finish() {
    local rc=$?
    if [[ "${rc}" != 0 ]]; then git checkout -q -- . 2> /dev/null; say "\`${pin}\`: FAILED, ${status}"; else say "\`${pin}\`: ${status}"; fi
    exit "${rc}"
}
trap finish EXIT
fail() { echo "::error::${pin}: $*"; status="$*"; exit 1; }
days() { # an ISO date -> whole days since then, or "unknown"
    local t; [[ -n "${1:-}" ]] && t=$(date -u -d "$1" +%s 2> /dev/null) || { echo unknown; return; }
    echo $(( ($(date -u +%s) - t) / 86400 ))
}
commit_age() { days "$(gh api "repos/$1/commits/$2" --jq .commit.committer.date 2> /dev/null)"; }
image_age() { days "$(skopeo inspect --override-os linux --override-arch amd64 --config "docker://$1" 2> /dev/null | jq -r '.created // empty' 2> /dev/null)"; }
# commit_pin <subject> <what changed upstream: a link or an image> <days>: the pin was written; check that only its files changed, commit them
commit_pin() {
    local changed; changed=$(git diff --name-only)
    [[ -n "${changed}" ]] || fail "the writer changed nothing for ${proposed}"
    local f; for f in ${changed}; do printf '%s\n' "${files[@]}" | grep -qxF -- "${f}" || fail "the writer changed ${f}, which is not one of the pin files (${files[*]})"; done
    git commit -q -a -m "$1

${pin} | ${current} | ${proposed} | $2 | $3"
    status="moved ${current} to ${proposed}"
}
git diff --quiet || fail "the working tree is not clean"

case "${pin}" in
    scx | extest)
        files=("binaries/${pin}/upstream.env")
        # shellcheck source=../../binaries/lib/upstream-env.sh
        source binaries/lib/upstream-env.sh; upstream_env_load "${files[0]}" || fail "invalid ${files[0]}"
        current=${UPSTREAM_TAG:-${UPSTREAM_COMMIT:0:7}}
        decision=$("${here}/upstream-check.sh" "binaries/${pin}")
        echo "${pin}: ${decision}"
        read -r verb tag commit _ <<<"${decision}"
        case "${verb}" in
            bump)
                proposed=${tag}; old=${UPSTREAM_TAG:-${UPSTREAM_COMMIT}}; upstream_env_set "${files[0]}" "${tag}" "${commit}" || fail "cannot write ${files[0]}"
                commit_pin "Bump ${pin} to ${tag}" "https://github.com/${UPSTREAM_WATCH}/compare/${old}...${tag}" "$(commit_age "${UPSTREAM_WATCH}" "${commit}")" ;;
            forkbehind) status="the fork is behind upstream (${tag}): run gh repo sync on it first" ;;
            unreachable) fail "${decision#unreachable }" ;;
            *) status="nothing to bump: ${decision}" ;;
        esac ;;
    ghostty)
        files=(binaries/ghostty/upstream.env binaries/ghostty/zig.env)
        source binaries/lib/upstream-env.sh; upstream_env_load "${files[0]}" || fail "invalid upstream.env"
        current="${UPSTREAM_TAG}, zig $(sed -n 's/^ZIG_VERSION=//p' "${files[1]}")"
        decision=$("${here}/ghostty-check.sh")
        echo "ghostty: ${decision}"
        read -r verb a1 a2 a3 a4 a5 a6 <<<"${decision}"
        case "${verb}" in
            bump) # a new Ghostty tag brings the Zig minor it needs: one commit for both, they cannot be applied apart
                proposed="${a1}, zig ${a3}"; "${here}/bump-ghostty.sh" ghostty "${a1}" "${a2}" "${a3}" "${a4}" "${a5}" "${a6}" || fail "bump-ghostty.sh failed"
                commit_pin "Bump ghostty to ${a1} (Zig ${a3})" "https://github.com/${UPSTREAM_WATCH}/compare/${UPSTREAM_TAG}...${a1}" "$(commit_age "${UPSTREAM_WATCH}" "${a2}")" ;;
            wait) status="nothing to bump yet: ${decision#wait }" ;;
            unreachable) fail "${decision#unreachable }" ;;
            *) status="nothing to bump: ${decision}" ;;
        esac ;;
    dev-packages | chunkah)
        case "${pin}" in
            dev-packages) files=(variants/dx/Containerfile); ref=ghcr.io/redcodeworks/dev-packages:latest; src="the dev-packages list image of the fedora-toolbox repository (${ref}), cosign signature verified" ;;
            chunkah) files=(config/chunkah.env); ref=quay.io/coreos/chunkah:latest; src="${ref}, keyless cosign signature verified" ;;
        esac
        go=$(mktemp)
        GITHUB_OUTPUT="${go}" "${here}/bump-pin.sh" "${pin}"; rc=$?
        read_out() { sed -n "s/^$1=//p" "${go}" | tail -n1; }
        result=$(read_out result); old=$(read_out previous); new=$(read_out digest); tag=$(read_out tag); rm -f "${go}"
        current="${old:0:19}"; case "${rc}" in 0 | 10) ;; *) fail "the check failed (${result:-exit ${rc}})" ;; esac
        if [[ "${result}" == equal ]]; then status="nothing to bump: the pin equals latest"
        else
            proposed="${tag} ${new:0:19}"
            commit_pin "Bump the ${pin} pin to latest (${tag})" "${src}" "$(image_age "${ref}")"
        fi ;;
    brew)
        current=$(sed -n 's/^ARG BREW_TAG=//p' Containerfile)
        latest=$(skopeo list-tags docker://ghcr.io/ublue-os/brew 2> /dev/null | python3 -I -c 'import json,re,sys; print(sorted(t for t in json.load(sys.stdin)["Tags"] if re.fullmatch(r"\d{8}", t))[-1])' 2> /dev/null) || latest=""
        [[ "${latest}" =~ ^[0-9]{8}$ ]] || fail "cannot list the tags of ghcr.io/ublue-os/brew"
        if [[ "${latest}" == "${current}" || "${latest}" < "${current}" ]]; then status="nothing to bump: the pinned ${current} is the newest (or newer than the newest) dated tag ${latest}"
        else
            files=(Containerfile); proposed=${latest}
            just brew-bump "${latest}" || fail "just brew-bump ${latest} failed (digest or signature; nothing changed)"
            commit_pin "Bump the Homebrew files image to ${latest}" "ghcr.io/ublue-os/brew:${latest}, cosign signature verified" "$(image_age "ghcr.io/ublue-os/brew:${latest}")"
        fi ;;
    builder)
        files=(binaries/builder.env)
        cur=$(sed -n 's/^BUILDER=//p' "${files[0]}")
        [[ "${cur}" =~ ^(registry\.fedoraproject\.org/fedora):([0-9]+)@(sha256:[0-9a-f]{64})$ ]] || fail "binaries/builder.env has no digest-pinned BUILDER"
        repo=${BASH_REMATCH[1]} major=${BASH_REMATCH[2]} curdigest=${BASH_REMATCH[3]}
        current="${major}@${curdigest:0:19}"
        manifest=$(skopeo inspect --raw "docker://${repo}:${major}" 2> /dev/null) || manifest=""
        [[ -n "${manifest}" ]] || fail "cannot resolve ${repo}:${major}"
        new="sha256:$(printf '%s' "${manifest}" | sha256sum | sed 's/ .*//')"
        [[ "${new}" =~ ^sha256:[0-9a-f]{64}$ ]] || fail "cannot compute the digest of ${repo}:${major}"
        if [[ "${new}" == "${curdigest}" ]]; then status="nothing to bump: the pin is the current digest of ${major}"
        else
            created=$(skopeo inspect --override-os linux --override-arch amd64 --config "docker://${repo}:${major}" 2> /dev/null | jq -r '.created // empty') || created=""
            [[ -n "${created}" ]] || fail "cannot read the creation date of ${repo}:${major}"
            age=$(days "${created}"); min=${MIN_AGE_DAYS:-7}
            if [[ "${age}" -lt "${min}" ]]; then status="nothing to bump yet: ${new:0:19} was built ${age} days ago (${created}); a digest is proposed once it has been the tag's value for ${min} days"
            else
                proposed="${major}@${new:0:19}"
                sed -i "s|^BUILDER=.*|BUILDER=${repo}:${major}@${new}|" "${files[0]}"
                commit_pin "Bump the Fedora ${major} builder digest (built ${created%%T*})" "${repo}:${major}" "${age}"
            fi
        fi ;;
    *) fail "unknown pin '${pin}'" ;;
esac
exit 0
