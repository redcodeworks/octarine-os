#!/usr/bin/env bash
# The weekly bump check of ONE pin: decide (the decision scripts of its kind) and, when something is newer, write the pin into the working tree and make ONE
# commit for it (its message ends with the row of the pull request's table: pin | from | to | what changed upstream | days the new value has existed).
# bump-weekly.sh runs every pin one after the other, each on its own branch cut from testing, and opens one independent pull request per pin. Exits non-zero when the pin's check FAILED (a registry that
# cannot be reached, a signature that does not verify, a bad pin); the working tree is restored then. Prints one line per pin (also into the job summary).
# Run from the repository root on a clean checkout, with GH_TOKEN set, a git identity, and skopeo, cosign and just for the kinds that use them.
#
#   bump-run.sh chunkah|brew|bins|dev-packages|gaming-packages
#
# Kinds: the image digest pin of chunkah (bump-pin.sh), the Homebrew files image (the `just brew-bump` recipe is the pin writer, so its cosign verification runs
# on every write) and the octarine-bins image (`just bins-bump` is the pin writer: it resolves octarine-bins:latest, verifies the digest with keys/octarine-bins.pub
# and writes it; the scx, extest, Ghostty and builder pins live in the octarine-bins repository) and the dev-packages list image of octarine-images (pinned in
# variants/dx/Containerfile; resolve dev-packages:latest, verify the digest with keys/redcodeworks-toolbox-cosign.pub, write the digest and a dated tag for humans) and the gaming-packages list image of
# octarine-images (the same, pinned in variants/gx/Containerfile).
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
    chunkah)
        files=(config/chunkah.env); ref=quay.io/coreos/chunkah:latest; src="${ref}, keyless cosign signature verified"
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
    bins)
        files=(Containerfile)
        cur=$(sed -n 's/^ARG BINS_DIGEST=//p' Containerfile); curtag=$(sed -n 's/^ARG BINS_TAG=//p' Containerfile)
        [[ "${cur}" =~ ^sha256:[0-9a-f]{64}$ ]] || fail "BINS_DIGEST in the Containerfile is missing or malformed"
        current="${curtag} ${cur:0:19}"
        ref=ghcr.io/redcodeworks/octarine-bins
        manifest=$(skopeo inspect --raw "docker://${ref}:latest" 2> /dev/null) || manifest=""
        [[ -n "${manifest}" ]] || fail "cannot resolve ${ref}:latest"
        new="sha256:$(printf '%s' "${manifest}" | sha256sum | sed 's/ .*//')"
        if [[ "${new}" == "${cur}" ]]; then status="nothing to bump: the pin equals ${ref}:latest (${curtag})"
        else
            just bins-bump latest || fail "just bins-bump failed (digest, signature or version label; nothing changed)"
            proposed="$(sed -n 's/^ARG BINS_TAG=//p' Containerfile) $(sed -n 's/^ARG BINS_DIGEST=//p' Containerfile | cut -c1-19)"
            commit_pin "Bump the octarine-bins image to ${proposed%% *}" "a new octarine-bins digest, ${ref}:latest verified with keys/octarine-bins.pub; its testing build is the first OS build with these binaries" "$(image_age "${ref}:latest")"
        fi ;;
    dev-packages | gaming-packages)
        # the two shared package LIST images of octarine-images, pinned the same way in the Containerfile of the variant that installs them (dx, gx)
        if [[ "${pin}" == dev-packages ]]; then variant=dx; prefix=DEV_PACKAGES; ref=ghcr.io/redcodeworks/dev-packages
        else variant=gx; prefix=GAMING_PACKAGES; ref=ghcr.io/redcodeworks/gaming-packages; fi
        files=("variants/${variant}/Containerfile")
        cur=$(sed -n "s/^ARG ${prefix}_DIGEST=//p" "${files[0]}"); curtag=$(sed -n "s/^ARG ${prefix}_TAG=//p" "${files[0]}")
        [[ "${cur}" =~ ^sha256:[0-9a-f]{64}$ ]] || fail "${prefix}_DIGEST in ${files[0]} is missing or malformed"
        current="${curtag} ${cur:0:19}"
        manifest=$(skopeo inspect --raw "docker://${ref}:latest" 2> /dev/null) || manifest=""
        [[ -n "${manifest}" ]] || fail "cannot resolve ${ref}:latest"
        new="sha256:$(printf '%s' "${manifest}" | sha256sum | sed 's/ .*//')"
        if [[ "${new}" == "${cur}" ]]; then status="nothing to bump: the pin equals ${ref}:latest (${curtag})"
        else
            "${here}/retry.sh" cosign verify --key keys/redcodeworks-toolbox-cosign.pub "${ref}@${new}" > /dev/null || fail "${ref}@${new} does not verify with keys/redcodeworks-toolbox-cosign.pub (nothing changed)"
            # the dated tag that points at the same digest (a label for humans), else `latest`
            newtag=latest
            for t in $(skopeo list-tags "docker://${ref}" 2> /dev/null | jq -r '.Tags[] | select(test("^latest-[0-9]{8}-[0-9a-f]{7}$"))' 2> /dev/null | sort -r | head -n 10); do
                if [[ "sha256:$(skopeo inspect --raw "docker://${ref}:${t}" 2> /dev/null | sha256sum | sed 's/ .*//')" == "${new}" ]]; then newtag=${t}; break; fi
            done
            sed -i -e "s/^ARG ${prefix}_TAG=.*/ARG ${prefix}_TAG=${newtag}/" -e "s/^ARG ${prefix}_DIGEST=.*/ARG ${prefix}_DIGEST=${new}/" "${files[0]}"
            proposed="${newtag} ${new:0:19}"
            commit_pin "Bump the ${pin} image to ${newtag}" "a new ${pin} digest, ${ref}:latest verified with keys/redcodeworks-toolbox-cosign.pub; its ${variant} testing build is the first with this list" "$(image_age "${ref}:latest")"
        fi ;;
    *) fail "unknown pin '${pin}'" ;;
esac
exit 0
