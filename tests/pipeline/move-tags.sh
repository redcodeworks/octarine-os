#!/usr/bin/env bash
# Tests move-tags.sh (the post-signing move of `testing`) with a fake skopeo that keeps tag -> digest in a directory (the raw "manifest" of a tag is its digest string, and
# `manifest-digest` prints it back): every moving tag ends on the digest, a read-back that still shows another digest fails, a failing copy fails and leaves the tag, no tags is
# a no-op, a bad digest is refused. The read-back is the real registry-settled.sh over the real registry-digest.sh. Run: tests/pipeline/move-tags.sh
set -uo pipefail
here=$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)
root=$(mktemp -d); trap 'rm -rf -- "${root:?}"' EXIT
pass=0; failn=0; rc=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { failn=$((failn + 1)); echo "FAIL $1"; sed 's/^/     /' "$root/run" 2> /dev/null; echo "     rc=$rc"; }
check() { local d=$1; shift; if "$@" > "$root/out" 2>&1; then ok "$d"; else bad "$d"; fi; }
export RETRY_DELAY=0 RETRY_TRIES=1 READBACK_TRIES=1 READBACK_WAIT=0 TAGS_DIR="$root/tags"
bin="$root/bin"; mkdir -p "$bin" "$TAGS_DIR"
cat > "$bin/skopeo" << 'F'
#!/usr/bin/env bash
case "$1" in
    copy) [[ "${MODE:-}" != fail ]] || { echo "boom" >&2; exit 1; }
          src=${@: -2:1}; dst=${@: -1}; d=${src#*@}; t=${dst##*:}
          [[ "${MODE:-}" == stale ]] || printf '%s' "${d}" > "${TAGS_DIR}/${t}" ;;
    inspect) ref=${@: -1}; t=${ref##*:}; [[ -f "${TAGS_DIR}/${t}" ]] || { echo "manifest unknown" >&2; exit 1; }; cat "${TAGS_DIR}/${t}" ;;
    manifest-digest) cat "$2" ;;
esac
F
chmod +x "$bin/skopeo"
D=sha256:$(printf 'a%.0s' {1..64}); OLD=sha256:$(printf 'b%.0s' {1..64})
run() { PATH="$bin:$PATH" env "$@" bash "$here/.github/scripts/move-tags.sh" ghcr.io/o/i "${D}" testing testing-20261116 > "$root/run" 2>&1; rc=$?; }
reset() { printf '%s' "${OLD}" > "$TAGS_DIR/testing"; printf '%s' "${OLD}" > "$TAGS_DIR/testing-20261116"; }
reset; run X=1
check "every moving tag ends on the signed digest" bash -c "[ $rc = 0 ] && [ \"\$(cat '$TAGS_DIR/testing')\" = '$D' ] && [ \"\$(cat '$TAGS_DIR/testing-20261116')\" = '$D' ]"
reset; run MODE=stale
check "a read-back that still shows another digest fails" test "$rc" != 0
reset; run MODE=fail
check "a failing copy fails and leaves the tags where they were" bash -c "[ $rc != 0 ] && [ \"\$(cat '$TAGS_DIR/testing')\" = '$OLD' ]"
PATH="$bin:$PATH" bash "$here/.github/scripts/move-tags.sh" ghcr.io/o/i "${D}" > "$root/run" 2>&1; rc=$?
check "no tags: nothing to do" test "$rc" = 0
PATH="$bin:$PATH" bash "$here/.github/scripts/move-tags.sh" ghcr.io/o/i notadigest testing > "$root/run" 2>&1; rc=$?
check "a bad digest is refused" test "$rc" != 0

echo; echo "passed: $pass, failed: $failn"
[ "$failn" = 0 ]
