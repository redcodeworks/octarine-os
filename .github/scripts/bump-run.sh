#!/usr/bin/env bash
# One weekly bump check of ONE pin: decide (decision scripts of its kind), and when something is newer open or update its pull request through
# bump-pr.sh (branch bump/<name>, into testing). Writes the summary row of the pin to $BUMP_ROW_DIR/<pin>.tsv (pin, current, proposed, pr, status, note;
# tab separated) whatever happens and exits non-zero when the pin's check FAILED (a registry that cannot be reached, a signature that does not verify,
# a bad pin): nothing is changed then. Run from the repository root on a checkout of testing, with GH_TOKEN set for the PR step.
#
#   bump-run.sh scx|extest|ghostty|dev-packages|chunkah|brew|builder
#
# Kinds: source pins (upstream-check.sh and ghostty-check.sh, written by bump-upstream.sh and bump-ghostty.sh), image digest pins (bump-pin.sh: the dev-packages list image of the fedora-toolbox repository, chunkah),
# the Homebrew files image (the `just brew-bump` recipe is the pin writer, so its cosign verification runs on every write) and the Fedora builder
# digest of binaries/builder.env (the same major, the newest digest of the tag once it has been the tag's value for MIN_AGE_DAYS, default 7: the creation date of the
# image is the stand-in for "has not been replaced since", a registry has no tag history).
set -uo pipefail
pin=${1:?pin name}
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
rowdir=${BUMP_ROW_DIR:-${RUNNER_TEMP:-/tmp}}
mkdir -p "${rowdir}"
current="-" proposed="-" pr="-" status=ok note=""
finish() {
    local rc=$?
    [[ "${rc}" == 0 ]] || { status=failed; [[ -n "${note}" ]] || note="exit ${rc}, see the log"; }
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "${pin}" "${current}" "${proposed}" "${pr}" "${status}" "${note}" > "${rowdir}/${pin}.tsv"
    exit "${rc}"
}
trap finish EXIT
fail() { echo "::error::${pin}: $*"; note="$*"; exit 1; }
prnum() { gh pr list --head "$1" --base testing --state open --json number --jq '.[0].number // empty' 2> /dev/null || true; }
open_pr() { # branch title bodyfile message file... -- writer...
    local branch=$1 title=$2 bodyfile=$3 message=$4; shift 4
    local fa=() ; while [[ "$1" != -- ]]; do fa+=(--file "$1"); shift; done; shift
    local out; out=$("${here}/bump-pr.sh" --branch "${branch}" --title "${title}" --body-file "${bodyfile}" --message "${message}" "${fa[@]}" -- "$@") || { echo "${out}"; fail "could not open or update the pull request"; }
    echo "${out}"
    pr=$(grep -m1 '^pr_number=' <<<"${out}" | cut -d= -f2); pr=${pr:-$(prnum "${branch}")}; pr="#${pr:-?}"
}
body_tail="Only the pin lines change. Not verified: nothing was built or booted by the check; the image build after the merge into \`testing\` is the first build with this pin. Bump pull requests are merged by the owner."

case "${pin}" in
    scx | extest)
        env_file="binaries/${pin}/upstream.env"
        # shellcheck source=../../binaries/lib/upstream-env.sh
        source binaries/lib/upstream-env.sh; upstream_env_load "${env_file}" || fail "invalid ${env_file}"
        current=${UPSTREAM_TAG:-${UPSTREAM_COMMIT:0:7}}
        decision=$("${here}/upstream-check.sh" "binaries/${pin}")
        echo "${pin}: ${decision}"
        read -r verb tag commit _ <<<"${decision}"
        case "${verb}" in
            bump) proposed=${tag}; "${here}/bump-upstream.sh" "binaries/${pin}" "${tag}" "${commit}" || fail "bump-upstream.sh failed"; pr="#$(prnum "bump/${pin}")" ;;
            forkbehind) proposed="${tag} (the fork is behind: gh repo sync first)"; note="fork behind upstream" ;;
            unreachable) fail "${decision#unreachable }" ;;
            *) note="${decision}" ; proposed="nothing to bump" ;;
        esac ;;
    ghostty)
        source binaries/lib/upstream-env.sh; upstream_env_load binaries/ghostty/upstream.env || fail "invalid upstream.env"
        current="${UPSTREAM_TAG}, zig $(sed -n 's/^ZIG_VERSION=//p' binaries/ghostty/zig.env)"
        decision=$("${here}/ghostty-check.sh")
        echo "ghostty: ${decision}"
        read -r verb a1 a2 a3 a4 a5 a6 <<<"${decision}"
        case "${verb}" in
            bump) proposed="${a1}, zig ${a3}"; "${here}/bump-ghostty.sh" ghostty "${a1}" "${a2}" "${a3}" "${a4}" "${a5}" "${a6}" || fail "bump-ghostty.sh failed"; pr="#$(prnum bump/ghostty)" ;;
            zigbump) proposed="zig ${a1} (low priority)"; "${here}/bump-ghostty.sh" zig "${a1}" "${a2}" "${a3}" "${a4}" || fail "bump-ghostty.sh failed"; pr="#$(prnum bump/zig)" ;;
            wait) proposed="nothing to bump"; note="${decision#wait }" ;;
            unreachable) fail "${decision#unreachable }" ;;
            *) proposed="nothing to bump"; note="${decision}" ;;
        esac ;;
    dev-packages | chunkah)
        go=$(mktemp)
        script="${here}/bump-pin.sh"; branch="bump/${pin}-digest"
        GITHUB_OUTPUT="${go}" "${script}" "${pin}"; rc=$?
        read_out() { sed -n "s/^$1=//p" "${go}" | tail -n1; }
        result=$(read_out result); old=$(read_out previous); new=$(read_out digest); tag=$(read_out tag)
        current="${old:0:19}"; case "${rc}" in 0 | 10) ;; *) fail "the check failed (${result:-exit ${rc}})" ;; esac
        if [[ "${result}" == equal ]]; then proposed="nothing to bump"; note="pin equals latest"
        else
            proposed="${tag} ${new:0:19}"
            mapfile -t changed < <(git diff --name-only); [[ "${#changed[@]}" -eq 1 ]] || fail "expected exactly one changed file, got: ${changed[*]:-none}"
            file=${changed[0]}; cp "${file}" "${go}.pin"; git checkout -- "${file}"
            bodyfile=$(mktemp)
            {
                case "${pin}" in
                    chunkah) echo "Moves the chunkah pin (\`config/chunkah.env\`, the layer splitter \`just rechunk\` runs) from \`${old}\` to \`${new}\`: the digest of \`quay.io/coreos/chunkah:latest\`, whose keyless cosign signature (GitHub Actions identity of the coreos/chunkah repository) verified." ;;
                    dev-packages) echo "Moves the dev-packages pin from \`${old}\` to \`${new}\` (tag \`${tag}\`): the digest of \`ghcr.io/redcodeworks/dev-packages:latest\`, whose cosign signature verified against \`keys/redcodeworks-toolbox-cosign.pub\`." ;;
                esac
                echo; echo "Only ${file} changes. ${body_tail}"
            } > "${bodyfile}"
            open_pr "${branch}" "Bump the ${pin} pin to latest (${tag})" "${bodyfile}" "Bump the ${pin} pin to its latest digest ${new}: it moves only through this reviewed change." "${file}" -- cp "${go}.pin" "${file}"
            rm -f "${bodyfile}"
        fi ;;
    brew)
        current=$(sed -n 's/^ARG BREW_TAG=//p' Containerfile)
        latest=$(skopeo list-tags docker://ghcr.io/ublue-os/brew 2> /dev/null | python3 -I -c 'import json,re,sys; print(sorted(t for t in json.load(sys.stdin)["Tags"] if re.fullmatch(r"\d{8}", t))[-1])' 2> /dev/null) || latest=""
        [[ "${latest}" =~ ^[0-9]{8}$ ]] || fail "cannot list the tags of ghcr.io/ublue-os/brew"
        if [[ "${latest}" == "${current}" || "${latest}" < "${current}" ]]; then proposed="nothing to bump"; note="the pinned ${current} is the newest (or newer than the newest) dated tag ${latest}"
        else
            just brew-bump "${latest}" || fail "just brew-bump ${latest} failed (digest or signature; nothing changed)"
            git diff --quiet -- Containerfile && fail "just brew-bump changed nothing for ${latest}"
            git checkout -- Containerfile
            proposed=${latest}
            bodyfile=$(mktemp)
            { echo "Moves the Homebrew files image pin (\`ARG BREW_TAG\` and \`ARG BREW_DIGEST\` in the Containerfile) from \`${current}\` to \`${latest}\`: the newest dated tag of \`ghcr.io/ublue-os/brew\`, its manifest digest from the registry, and its cosign signature verified against \`keys/ublue-os-brew-cosign.pub\` by the \`just brew-bump\` recipe (the manual path, reused as the pin writer)."; echo; echo "Only the two pin lines of the Containerfile change. ${body_tail}"; } > "${bodyfile}"
            open_pr bump/brew "Bump the Homebrew files image to ${latest}" "${bodyfile}" "Bump the Homebrew files image pin to ${latest}: newest dated tag, signature verified with keys/ublue-os-brew-cosign.pub" Containerfile -- just brew-bump "${latest}"
            rm -f "${bodyfile}"
        fi ;;
    builder)
        # shellcheck disable=SC1091
        cur=$(sed -n 's/^BUILDER=//p' binaries/builder.env)
        [[ "${cur}" =~ ^(registry\.fedoraproject\.org/fedora):([0-9]+)@(sha256:[0-9a-f]{64})$ ]] || fail "binaries/builder.env has no digest-pinned BUILDER"
        repo=${BASH_REMATCH[1]} major=${BASH_REMATCH[2]} curdigest=${BASH_REMATCH[3]}
        current="${major}@${curdigest:0:19}"
        manifest=$(skopeo inspect --raw "docker://${repo}:${major}" 2> /dev/null) || manifest=""
        [[ -n "${manifest}" ]] || fail "cannot resolve ${repo}:${major}"
        new="sha256:$(printf '%s' "${manifest}" | sha256sum | sed 's/ .*//')"
        [[ "${new}" =~ ^sha256:[0-9a-f]{64}$ ]] || fail "cannot compute the digest of ${repo}:${major}"
        if [[ "${new}" == "${curdigest}" ]]; then proposed="nothing to bump"; note="the pin is the current digest of ${major}"
        else
            created=$(skopeo inspect --override-os linux --override-arch amd64 --config "docker://${repo}:${major}" 2> /dev/null | jq -r '.created // empty') || created=""
            [[ -n "${created}" ]] || fail "cannot read the creation date of ${repo}:${major}"
            age=$(( ($(date -u +%s) - $(date -u -d "${created}" +%s)) / 86400 ))
            min=${MIN_AGE_DAYS:-7}
            if (( age < min )); then proposed="nothing to bump yet"; note="${new:0:19} was built ${age} days ago (${created}); a digest is proposed once it has been the tag's value for ${min} days"
            else
                proposed="${major}@${new:0:19}"
                bodyfile=$(mktemp)
                { echo "Moves the builder image of the prebuilt binaries (\`binaries/builder.env\`) from \`${curdigest}\` to \`${new}\`: the current digest of \`${repo}:${major}\` (the same Fedora ${major}), built ${created}, ${age} days ago (the cooldown is ${min} days: the tag has not moved since)."; echo; echo "**This changes the content key of EVERY binaries component, so scx, extest and Ghostty rebuild once after the merge** (about 4.4 minutes, 1 minute and 11 minutes on a runner, in parallel)."; echo; echo "Only the BUILDER line changes. ${body_tail}"; } > "${bodyfile}"
                open_pr bump/builder "Bump the Fedora ${major} builder digest (built ${created%%T*})" "${bodyfile}" "Bump the binaries builder to the current digest of fedora:${major} (${new:0:19})" binaries/builder.env -- sed -i "s|^BUILDER=.*|BUILDER=${repo}:${major}@${new}|" binaries/builder.env
                rm -f "${bodyfile}"
            fi
        fi ;;
    *) fail "unknown pin '${pin}'" ;;
esac
exit 0
