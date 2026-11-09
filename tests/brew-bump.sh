#!/usr/bin/env bash
# Tests for `just brew-bump` (the Justfile recipe that moves the Homebrew image pin) with fake skopeo and cosign, and
# for the format of the pin in the real Containerfile. Run: tests/brew-bump.sh
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(mktemp -d)
trap 'rm -rf -- "$root"' EXIT
pass=0
failn=0
bin="$root/bin"
work="$root/work"
mkdir -p "$bin" "$work/keys"
cp "$here/../Justfile" "$work/Justfile"
cp "$here/../Containerfile" "$work/Containerfile"
echo key >"$work/keys/ublue-os-brew-cosign.pub"
[ -d "$here/../githooks" ] && cp -r "$here/../githooks" "$work/githooks"
[ -f "$here/../image-template.env" ] && cp "$here/../image-template.env" "$work/image-template.env"
REAL_JUST=$(command -v just)
export LOG="$root/log"

cat >"$bin/skopeo" <<'F'
#!/usr/bin/env bash
echo "skopeo $*" >>"$LOG"
case "$1" in
    inspect) printf 'manifest of %s' "${@: -1}" ;;
    list-tags) echo '{"Tags":["latest","20261101","20261115","20261108","stable"]}' ;;
esac
F
cat >"$bin/cosign" <<'F'
#!/usr/bin/env bash
echo "cosign $*" >>"$LOG"
exit "${COSIGN_RC:-0}"
F
chmod +x "$bin"/*

ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { failn=$((failn + 1)); echo "FAIL $1"; sed 's/^/     /' "$root/out"; }
check() { local d=$1; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
run() { (cd "$work" && PATH="$bin:$PATH" "$REAL_JUST" --justfile Justfile --working-directory . brew-bump "$@") >"$root/out" 2>&1; rc=$?; }
expected() { printf 'manifest of docker://ghcr.io/ublue-os/brew:%s' "$1" | sha256sum | sed 's/ .*//'; }

# the real Containerfile pin is a digest
tag=$(sed -n 's/^ARG BREW_TAG=//p' "$here/../Containerfile")
dig=$(sed -n 's/^ARG BREW_DIGEST=//p' "$here/../Containerfile")
check "Containerfile: the tag is YYYYMMDD" test -n "$(printf '%s' "$tag" | grep -E '^[0-9]{8}$')"
check "Containerfile: the digest is sha256: plus 64 hex characters" test -n "$(printf '%s' "$dig" | grep -E '^sha256:[0-9a-f]{64}$')"
check "Containerfile: the brew image reference uses the tag and the digest" grep -qF 'ARG BREW_IMAGE=ghcr.io/ublue-os/brew:${BREW_TAG}@${BREW_DIGEST}' "$here/../Containerfile"

: >"$LOG"
run 20261122
check "bump with a tag: exit 0" test "$rc" = 0
check "bump: the digest comes from the raw manifest" grep -qx "ARG BREW_DIGEST=sha256:$(expected 20261122)" "$work/Containerfile"
check "bump: the tag is written" grep -qx 'ARG BREW_TAG=20261122' "$work/Containerfile"
check "bump: cosign verified the digest reference first" grep -qF "cosign verify --key keys/ublue-os-brew-cosign.pub ghcr.io/ublue-os/brew@sha256:$(expected 20261122)" "$LOG"
check "bump: the rest of the Containerfile is untouched" bash -c "diff <(grep -vE '^ARG BREW_(TAG|DIGEST)=' '$here/../Containerfile') <(grep -vE '^ARG BREW_(TAG|DIGEST)=' '$work/Containerfile')"

cp "$here/../Containerfile" "$work/Containerfile"
COSIGN_RC=1 run 20261122
check "verification failure: exit 1" test "$rc" = 1
check "verification failure: the Containerfile is unchanged" cmp -s "$here/../Containerfile" "$work/Containerfile"

run notatag
check "a bad tag is refused" test "$rc" = 1
check "a bad tag leaves the Containerfile alone" cmp -s "$here/../Containerfile" "$work/Containerfile"

run
check "default: the newest dated tag" grep -qx 'ARG BREW_TAG=20261115' "$work/Containerfile"

echo "passed: $pass, failed: $failn"
[ "$failn" = 0 ]
