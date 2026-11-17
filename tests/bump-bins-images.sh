#!/usr/bin/env bash
# Tests the `bins-dx` and `bins-gx` kinds of bump-run.sh (the weekly pin bump of the octarine-bins-dx and -gx images; the same code, run once per kind) with stub skopeo and cosign and a throwaway git repository:
# an equal pin changes nothing, a newer verified digest is written into the variant's Containerfile (variants/dx for bins-dx, variants/gx for bins-gx: digest and the image's version label as the tag) as ONE commit with the table row,
# a digest that does not verify fails and leaves the tree as it was. Needs: bash, git, jq. Run: tests/bump-bins-images.sh
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
root=$(mktemp -d)
trap 'rm -rf -- "${root:?}"' EXIT
pass=0; failn=0; rc=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { failn=$((failn + 1)); echo "FAIL $1"; sed 's/^/     /' "$root/run"; echo "     rc=$rc"; }
check() { local d=$1; shift; if "$@" > "$root/out" 2>&1; then ok "$d"; else bad "$d"; fi; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
bin="$root/bin"; mkdir -p "$bin"
# the registry: latest holds the manifest text in $MANIFEST (its sha256 is the digest). Tags: 20261120-abcdef1 and 20261119-1111111 (older) point at the new digest,
# 20261121-2222222 at another one (newer date, different content), inputs-0123 is no dated tag. The old tag 20261109-0969783 exists too. NOLABEL=1: a reproducible
# image without labels (the config has none); the tag must come from the registry either way. NODATED=1: no dated tag at the digest.
cat > "$bin/skopeo" << 'F'
#!/usr/bin/env bash
case "$1 $2" in
    "inspect --raw") case "$3" in
        *:latest) printf '%s' "$MANIFEST" ;;
        *:20261120-abcdef1 | *:20261119-1111111) [[ -z "${NODATED:-}" ]] && printf '%s' "$NEWTEXT" || printf 'elsewhere' ;;
        *:20261121-2222222) printf 'newer-other' ;;
        *:inputs-0123) printf '%s' "$NEWTEXT" ;;
        *) echo other ;; esac ;;
    "list-tags docker://ghcr.io/redcodeworks/octarine-bins-dx" | "list-tags docker://ghcr.io/redcodeworks/octarine-bins-gx") echo '{"Tags":["latest","20261109-0969783","20261119-1111111","20261120-abcdef1","20261121-2222222","inputs-0123"]}' ;;
    "inspect --override-os") echo '{"created":"2026-11-15T00:00:00Z"}' ;;
    "inspect --config") if [[ -n "${NOLABEL:-}" ]]; then echo '{"config":{"Labels":{}}}'; else echo '{"config":{"Labels":{"org.opencontainers.image.version":"20261120-abcdef1"}}}'; fi ;;
esac
F
cat > "$bin/cosign" << 'F'
#!/usr/bin/env bash
[[ -z "${COSIGN_FAIL:-}" ]] || { echo "no matching signatures" >&2; exit 1; }
echo "$@" >> "$LOG"
F
chmod +x "$bin"/*
for c in bash env cat grep sed jq git sort head tr date sha256sum awk mktemp rm cut sleep dirname mkdir cp wc tac; do p=$(command -v "$c") && ln -sf "$p" "$bin/$c"; done
export RETRY_DELAY=0 LOG="$root/log" PATH="$bin"

old=$(printf 'old' | sha256sum | sed 's/ .*//'); new=$(printf 'new' | sha256sum | sed 's/ .*//')
setup() {
    rm -rf "$root/r"; mkdir -p "$root/r/variants/$variant" "$root/r/keys" "$root/r/.github/scripts"; : > "$LOG"
    cp "$here/.github/scripts/bump-run.sh" "$here/.github/scripts/bins-tag.sh" "$here/.github/scripts/retry.sh" "$root/r/.github/scripts/"
    printf 'ARG %s_TAG=20261109-0969783\nARG %s_DIGEST=sha256:%s\nARG X=1\n' "$prefix" "$prefix" "$old" > "$root/r/variants/$variant/Containerfile"
    echo k > "$root/r/keys/octarine-bins.pub"
    (cd "$root/r" && git init -q -b testing . && git add -A && git commit -qm init)
}
run() { (cd "$root/r" && env "$@" bash .github/scripts/bump-run.sh $kind) > "$root/run" 2>&1; rc=$?; }
for kind in bins-dx bins-gx; do
    variant=${kind#bins-}; prefix=BINS_${variant^^}
    setup; run MANIFEST=old
    check "$kind: the pin equals latest: nothing changes, no commit, cosign not called" bash -c "[ $rc = 0 ] && grep -q 'nothing to bump' '$root/run' && [ \"\$(git -C '$root/r' rev-list --count HEAD)\" = 1 ] && [ ! -s '$LOG' ]"
    setup; run MANIFEST=new NEWTEXT=new
    check "$kind: a newer digest: verified with the octarine-bins key, written with the dated registry tag at the digest as the tag (the newest of two, the label is not read), one commit that changes only the Containerfile and carries the table row" bash -c "[ $rc = 0 ] && grep -q -- '--key keys/octarine-bins.pub ghcr.io/redcodeworks/octarine-$kind@sha256:$new' '$LOG' && grep -q '^ARG ${prefix}_DIGEST=sha256:$new\$' '$root/r/variants/$variant/Containerfile' && grep -q '^ARG ${prefix}_TAG=20261120-abcdef1\$' '$root/r/variants/$variant/Containerfile' && [ \"\$(git -C '$root/r' rev-list --count HEAD)\" = 2 ] && [ \"\$(git -C '$root/r' show --name-only --format= HEAD)\" = variants/$variant/Containerfile ] && git -C '$root/r' log -1 --format=%b | grep -q '^$kind | 20261109-0969783 sha256:'"
    setup; run MANIFEST=new NEWTEXT=new NOLABEL=1
    check "$kind: an image without labels (reproducible): the same tag, resolved from the registry" bash -c "[ $rc = 0 ] && grep -q '^ARG ${prefix}_TAG=20261120-abcdef1\$' '$root/r/variants/$variant/Containerfile' && grep -q '^ARG ${prefix}_DIGEST=sha256:$new\$' '$root/r/variants/$variant/Containerfile'"
    setup; run MANIFEST=new NEWTEXT=new NODATED=1
    check "$kind: no dated tag points at the digest: the run fails naming the digest, nothing is written or committed" bash -c "[ $rc != 0 ] && grep -q 'sha256:$new' '$root/run' && git -C '$root/r' diff --quiet && [ \"\$(git -C '$root/r' rev-list --count HEAD)\" = 1 ]"
    setup; run MANIFEST=new NEWTEXT=new COSIGN_FAIL=1
    check "$kind: a digest that does not verify fails the run, writes nothing and commits nothing" bash -c "[ $rc != 0 ] && git -C '$root/r' diff --quiet && [ \"\$(git -C '$root/r' rev-list --count HEAD)\" = 1 ]"
done
echo; echo "passed: $pass, failed: $failn"
[ "$failn" = 0 ]
