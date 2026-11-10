#!/usr/bin/env bash
# Tests .github/scripts/push-tags.sh (one podman push, every other tag a registry-side copy of its digest) with stub
# podman and skopeo, and that the four image workflows publish through it and never push an image twice.
# Run: tests/push-tags.sh
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script="$here/.github/scripts/push-tags.sh"
root=$(mktemp -d)
trap 'rm -rf -- "$root"' EXIT
fail=0
pass() { echo "PASS $1"; }
bad() { echo "FAIL $1"; fail=1; }

mkdir -p "$root/bin" "$root/reg"
# stub registry: $root/reg/<tag> holds the manifest bytes of a tag; every `podman push` writes a NEW manifest (the bug:
# the same image pushed twice gives two digests); `skopeo copy ...@<digest> ...:<tag>` copies by digest (BREAK_COPY=1: wrong content)
cat > "$root/bin/podman" <<'F'
#!/usr/bin/env bash
echo "podman $*" >> "${CALLS}"
[[ "$1" == push ]] || exit 1
for a in "$@"; do case "$a" in --digestfile=*) df="${a#--digestfile=}" ;; esac; done
tag="${@: -1}"; tag="${tag##*:}"
n=$(grep -c '^podman push' "${CALLS}")
printf 'manifest-%s-%s' "${tag}" "${n}" > "${REG}/${tag}"
echo "sha256:$(sha256sum < "${REG}/${tag}" | sed 's/ .*//')" > "${df}"
F
cat > "$root/bin/skopeo" <<'F'
#!/usr/bin/env bash
echo "skopeo $*" >> "${CALLS}"
case "$1 $2" in
    "inspect --raw") tag="${3##*:}"; [[ -f "${REG}/${tag}" ]] && cat "${REG}/${tag}" || exit 1 ;;
    "copy --all")
        [[ "$3" == --preserve-digests ]] || exit 1
        src="${4#docker://}"; dst="${5#docker://}"; want="${src##*@}"
        for f in "${REG}"/*; do
            [[ "sha256:$(sha256sum < "${f}" | sed 's/ .*//')" == "${want}" ]] || continue
            if [[ "${BREAK_COPY:-}" == 1 ]]; then echo "other" > "${REG}/${dst##*:}"; else cp "${f}" "${REG}/${dst##*:}"; fi
            exit 0
        done
        exit 1 ;;
    *) exit 1 ;;
esac
F
chmod +x "$root/bin"/*
export CALLS="$root/calls" REG="$root/reg"
run() { rm -f "$REG"/*; : > "$CALLS"; : > "$root/out"; PATH="$root/bin:$PATH" GITHUB_OUTPUT="$root/out" bash "$script" "$@" > "$root/log" 2>&1; }
dg() { echo "sha256:$(sha256sum < "$REG/$1" | sed 's/ .*//')"; }

run local:build ghcr.io/o/img testing-abc1234 testing
rc=$?
[[ $rc -eq 0 ]] && pass "two tags: succeeds" || { bad "two tags (rc $rc)"; sed 's/^/     /' "$root/log"; }
[[ "$(grep -c '^podman push' "$CALLS")" == 1 ]] && pass "exactly one podman push" || bad "push count"
[[ "$(dg testing-abc1234)" == "$(dg testing)" ]] && pass "every tag has the same manifest digest" || bad "digests differ"
grep -q "^skopeo copy --all --preserve-digests docker://ghcr.io/o/img@$(dg testing-abc1234) docker://ghcr.io/o/img:testing\$" "$CALLS" && pass "the second tag is a digest copy of the pushed digest" || bad "copy call"
[[ "$(sed -n 's/^digests=//p' "$root/out")" == "$(dg testing)" ]] && pass "the output is the single digest, which the sign job signs" || bad "digests output"

run local:build ghcr.io/o/img latest-1 latest-20261110-abc1234 20261110-abc1234 20261110 latest latest-20261110
[[ $? -eq 0 && "$(grep -c '^podman push' "$CALLS")" == 1 && "$(grep -c '^skopeo copy' "$CALLS")" == 5 ]] && pass "six tags: one push, five copies" || bad "six tags"
[[ "$(sort -u <(for t in latest-1 latest-20261110-abc1234 20261110-abc1234 20261110 latest latest-20261110; do dg "$t"; done) | wc -l)" == 1 ]] && pass "six tags share one digest" || bad "six digests"

run local:build ghcr.io/o/img only
[[ $? -eq 0 && "$(grep -c '^skopeo copy' "$CALLS")" == 0 ]] && pass "one tag: a push and no copy" || bad "one tag"

BREAK_COPY=1 run local:build ghcr.io/o/img a b
[[ $? -ne 0 ]] && grep -q '::error::b is' "$root/log" && pass "a copy that changes the digest fails the step" || bad "broken copy"
run local:build ghcr.io/o/img
[[ $? -ne 0 ]] && pass "no tag: fails" || bad "no tag"

echo "== workflows"
for wf in build build-beta build-dx build-nvidia; do
    f="$here/.github/workflows/$wf.yml"
    [[ "$(grep -c 'podman push' "$f")" == 0 ]] && pass "$wf.yml: no podman push in the workflow (a second push of one image gives another digest)" || bad "$wf.yml: podman push"
    [[ "$(grep -c '\.github/scripts/push-tags.sh ' "$f")" == 1 ]] && pass "$wf.yml: pushes once through push-tags.sh" || bad "$wf.yml: push-tags.sh"
    grep -q 'for digest in \${DIGESTS}' "$f" && pass "$wf.yml: the sign job still signs the digests output" || bad "$wf.yml: sign loop"
done
grep -q 'push-tags.sh "${IMAGE_NAME}:${first}" "${IMAGE_REGISTRY}/${IMAGE_NAME}" ${ALIAS_TAGS}' "$here/.github/workflows/build.yml" && pass "build.yml: first alias tag is the local image, all alias tags are published" || bad "build.yml call"
exit "${fail}"
