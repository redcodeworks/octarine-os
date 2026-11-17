#!/usr/bin/env bash
# Tests .github/scripts/plan-dx.sh (skip, promote or build, per channel) with stub skopeo and cosign in a temporary git
# repository. Run: tests/plan-dx.sh
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
plan="$here/.github/scripts/plan-dx.sh"
root=$(mktemp -d)
trap 'rm -rf -- "$root"' EXIT
fail=0
pass() { echo "PASS $1"; }
bad() { echo "FAIL $1"; fail=1; }

mkdir -p "$root/bin" "$root/cfg" "$root/repo/variants/dx" "$root/repo/variants/gx"
cd "$root/repo"
git init -q -b testing .
git config user.email t@example.invalid; git config user.name t
echo a > variants/dx/f; echo a > variants/gx/f; echo a > x; git add -A; git commit -qm one
echo b >> x; git add -A; git commit -qm two
echo c >> variants/dx/f; git add -A; git commit -qm "three (dx only)"
inputs=$("$here/.github/scripts/inputs-hash.sh" dx HEAD)
inputs_gx=$("$here/.github/scripts/inputs-hash.sh" gx HEAD)
sha7=$(git rev-parse --short=7 HEAD)
older7=$(git rev-parse --short=7 HEAD~1)

# stub registry: config of octarine-os-dx:<tag> is $root/cfg/<tag> (missing = not published); the raw manifest is
# derived from the reference (a reference listed in $root/missing does not exist; a line "<from> <to>" in $root/alias
# gives <from> the manifest of <to>, like a retag); cosign fails for references listed in $root/unsigned and for the key check of nothing else
cat > "$root/bin/skopeo" <<'F'
#!/usr/bin/env bash
ref="${@: -1}"
echo "$*" >> "${SK_LOG:-/dev/null}"
case "$1 $2" in
    "inspect --raw")
        ref="${ref#docker://}"
        [[ -z "${SK_READ_ERROR:-}" ]] || { echo "dial tcp: i/o timeout" >&2; exit 1; }
        ! grep -qxF "${ref}" "${MISSING}" || { echo "Error: reading manifest: manifest unknown" >&2; exit 1; }
        to=$(awk -v r="${ref}" '$1 == r { print $2 }' "${ALIAS}"); printf 'manifest of docker://%s' "${to:-${ref}}" ;;
    "inspect --config") tag="${ref##*:}"; [[ -z "${SK_READ_ERROR_DX:-}" || "${ref}" != *octarine-os-dx:* ]] || { echo "dial tcp: i/o timeout" >&2; exit 1; }; [[ ( "${ref}" == *octarine-os-dx:* || "${ref}" == *octarine-os-nvidia-dx:* || "${ref}" == *octarine-os-gx:* ) && -f "${CFG}/${tag}" ]] && { cat "${CFG}/${tag}"; exit 0; }; [[ -z "${SK_READ_ERROR:-}" ]] || { echo "dial tcp: i/o timeout" >&2; exit 1; }; echo "Error: manifest unknown" >&2; exit 1 ;;
esac
F
cat > "$root/bin/cosign" <<'F'
#!/usr/bin/env bash
ref="${@: -1}"
[[ "${COSIGN_BASE_FAIL:-}" != 1 || "${ref}" != *octarine-os@* ]] || { echo "Error: no matching signatures" >&2; exit 1; }
[[ -z "${COSIGN_READ_ERROR:-}" ]] || { echo "Error: GET https://ghcr.io/v2/: net/http: TLS handshake timeout" >&2; exit 1; }
! grep -qxF "${ref}" "${UNSIGNED}" || { echo "Error: no signatures found" >&2; exit 1; }
F
chmod +x "$root/bin"/*
export RETRY_DELAY=0 CFG="$root/cfg" UNSIGNED="$root/unsigned" MISSING="$root/missing" ALIAS="$root/alias"
: > "$UNSIGNED"; : > "$MISSING"; : > "$ALIAS"

dig() { printf 'manifest of %s' "$1" | sha256sum | sed 's/ .*//'; }
base() { dig "docker://ghcr.io/redcodeworks/octarine-os:$1"; }   # the base digest of a channel's tag
dxd() { dig "docker://ghcr.io/redcodeworks/octarine-os-dx:$1"; }  # the manifest digest of a dx tag
cfg() { # tag base-digest inputs
    printf '{"config":{"Labels":{"org.opencontainers.image.base.digest":"%s","io.github.redcodeworks.octarine-os.dx-inputs":"%s"}}}' "$2" "$3" > "$CFG/$1"
}
cfgx() { # tag base-digest inputs (an image of the gx variant: the label is gx-inputs)
    printf '{"config":{"Labels":{"org.opencontainers.image.base.digest":"%s","io.github.redcodeworks.octarine-os.gx-inputs":"%s"}}}' "$2" "$3" > "$CFG/$1"
}
run() { # channel [force]; outputs in $root/out; VARIANT in the environment (dx by default)
    : > "$root/out"; : > "$root/sum"
    PATH="$root/bin:$PATH" CHANNEL="$1" FORCE="${2:-false}" VARIANT="${VARIANT:-dx}" GITHUB_REPOSITORY_OWNER=RedCodeWorks \
        GITHUB_OUTPUT="$root/out" GITHUB_STEP_SUMMARY="$root/sum" bash "$plan" > "$root/log" 2>&1
}
get() { sed -n "s/^$1=//p" "$root/out"; }
expect() { # name build promote source_tag
    if [[ "$(get build)" == "$2" && "$(get promote)" == "$3" && "$(get source_tag)" == "$4" ]]; then pass "$1"
    else bad "$1 (got build=$(get build) promote=$(get promote) tag=$(get source_tag); want $2 $3 $4)"; sed 's/^/     /' "$root/log"; fi
}
other="sha256:$(printf 'a%.0s' {1..64})"
bt="sha256:$(base "testing-${sha7}")"; bf="sha256:$(base testing)"; bl="sha256:$(base latest)"

echo "== testing channel"
rm -f "$CFG"/*
run testing; expect "testing, first run (nothing published): build" true false ""
cfg testing "${bt}" "${inputs}"; run testing; expect "testing, same base digest and dx inputs: skip" false false ""

echo "== latest channel (main)"
rm -f "$CFG"/*
run latest; expect "latest, nothing published, no testing image: build" true false ""
cfg latest "${bl}" "${inputs}"; run latest; expect "latest, same base and dx inputs: skip" false false ""
rm -f "$CFG/latest"
cfg testing "${bl}" "${inputs}"
run latest; expect "latest, tested testing image with the same base and dx inputs: promote" false true testing
rm -f "$CFG"/testing-*; rm -f "$CFG/latest"; cfg testing "${bl}" "${inputs}"; echo "ghcr.io/redcodeworks/octarine-os-dx@sha256:$(dxd testing)" > "$UNSIGNED"
run latest; expect "latest, matching testing image but unsigned: build, not promoted" true false ""

echo "== gx variant (same plan, the label gx-inputs and the gx hash)"
rm -f "$CFG"/*
VARIANT=gx run testing; expect "gx testing, nothing published: build" true false ""
[[ "$(get inputs)" == "${inputs_gx}" ]] && pass "gx: the plan reports the gx inputs hash" || bad "gx: the plan reports the gx inputs hash (got $(get inputs))"
cfgx testing "${bt}" "${inputs_gx}"; VARIANT=gx run testing; expect "gx testing, same base digest and gx inputs: skip" false false ""
cfgx testing "${bt}" "${inputs}"; VARIANT=gx run testing; expect "gx testing, the label holds the dx hash: build (the hashes are not interchangeable)" true false ""
cfg testing "${bt}" "${inputs}"; VARIANT=gx run testing; expect "gx testing, only a dx-inputs label: build" true false ""
rm -f "$CFG"/*
cfgx testing "${bl}" "${inputs_gx}"; VARIANT=gx run latest; expect "gx latest, a tested gx testing image with the same base and gx inputs: promote" false true testing
VARIANT=gx run latest true; expect "gx latest, force" true false ""
rm -f "$CFG"/*; cfg latest "${bl}" "${inputs}"; VARIANT=gx run latest; expect "gx latest: a published dx image of the same base is not a gx skip" true false ""
VARIANT=zx run latest; [[ "$(grep -c 'Unknown variant' "$root/log")" == 1 ]] && pass "an unknown variant is refused" || bad "an unknown variant is refused"

exit "${fail}"
