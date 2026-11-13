#!/usr/bin/env bash
# Tests for the weekly datastore pin bump (.github/scripts/datastore-pin-bump.sh, used by bump-pins.yml) with a fake skopeo: the newest
# tag inside the pinned major with its digest, a newer major only reported, equal, unreachable registry, bad pin, unknown service.
# Nothing is pulled. Needs: bash, python3. Run: tests/datastore-bump.sh
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
root=$(mktemp -d)
trap 'rm -rf -- "${root:?}"' EXIT
pass=0; failn=0; rc=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { failn=$((failn + 1)); echo "FAIL $1"; sed 's/^/     /' "$root/run" 2>/dev/null; echo "     rc=$rc"; }
check() { local d=$1; shift; if "$@" >"$root/out" 2>&1; then ok "$d"; else bad "$d"; fi; }
bin="$root/bin"; mkdir -p "$bin"
cat >"$bin/skopeo" <<'F'
#!/usr/bin/env bash
echo "skopeo $*" >>"$LOG"
case "$1" in
    list-tags) [ "${SKOPEO_FAIL:-0}" = 1 ] && exit 1; echo "{\"Tags\":[${TAGS}]}" ;;
    inspect) printf 'manifest of %s' "${@: -1}" ;;
esac
F
chmod +x "$bin/skopeo"
export LOG="$root/log"
dg() { printf 'manifest of docker://%s' "$1" | sha256sum | sed 's/ .*//'; }
fresh() { cp "$here/variants/dx/datastore/datastore.env" "$root/ds.env"; : >"$LOG"; : >"$root/gho"; }
bump() { local svc=$1; shift; env "$@" PATH="$bin:$PATH" DATASTORE_ENV="$root/ds.env" GITHUB_OUTPUT="$root/gho" bash "$here/.github/scripts/datastore-pin-bump.sh" "$svc" >"$root/run" 2>&1; rc=$?; }
pgtags='"latest","17-alpine","17.12-alpine","17.13-alpine","17.13","17.14-alpine","17.14-rc1-alpine","16.9-alpine","alpine"'
fresh; bump postgresql TAGS="$pgtags"
want_digest="sha256:$(dg docker.io/library/postgres:17.14-alpine)"
check "newer patch in the pinned major with the same suffix: pin rewritten to 17.14-alpine with its digest, exit 10, nothing else changes" bash -c "[ $rc = 10 ] && grep -qx 'POSTGRESQL_TAG=17.14-alpine' '$root/ds.env' && grep -qx 'POSTGRESQL_DIGEST=$want_digest' '$root/ds.env' && diff <(grep -v '^POSTGRESQL_\\(TAG\\|DIGEST\\)=' '$here/variants/dx/datastore/datastore.env') <(grep -v '^POSTGRESQL_\\(TAG\\|DIGEST\\)=' '$root/ds.env') && grep -qx 'result=different' '$root/gho'"
check "release candidates, the suffix-less 17.13, floating tags and other majors are never chosen" bash -c "! grep -q 'rc1' '$root/ds.env' && grep -qx 'POSTGRESQL_TAG=17.14-alpine' '$root/ds.env'"
fresh; bump postgresql TAGS='"17.12-alpine","17.11-alpine","18.1-alpine","18.2-alpine"'
check "a newer major is only reported (major_note) and the pin stays: exit 0, file unchanged" bash -c "[ $rc = 0 ] && grep -q 'newer major available (18), manual decision' '$root/run' && grep -q '^major_note=newer major available (18)' '$root/gho' && cmp -s '$here/variants/dx/datastore/datastore.env' '$root/ds.env'"
fresh; bump postgresql TAGS='"17.12-alpine","17.11-alpine"'
check "already the newest: equal, nothing to bump, exit 0" bash -c "[ $rc = 0 ] && grep -q 'nothing to bump' '$root/run' && grep -qx 'result=equal' '$root/gho' && cmp -s '$here/variants/dx/datastore/datastore.env' '$root/ds.env'"
fresh; bump kafka TAGS='"4.3.2","4.4.0","4.4.1","4.4.1-rc1","5.0.0","latest"'
check "bare version tags (kafka 4.3.2): 4.4.1 chosen inside major 4, 5.0.0 reported as a newer major" bash -c "[ $rc = 10 ] && grep -qx 'KAFKA_TAG=4.4.1' '$root/ds.env' && grep -q 'newer major available (5)' '$root/run'"
fresh; bump seaweedfs TAGS='"3.99","3.100","3.101","4.60"'
check "version sort is numeric (3.101 beats 3.99), 4.60 is a newer major" bash -c "[ $rc = 10 ] && grep -qx 'SEAWEEDFS_TAG=3.101' '$root/ds.env' && grep -q 'newer major available (4)' '$root/run'"
fresh; bump valkey TAGS='"9.1.3-alpine","9.1.4-alpine","9.2.0-alpine","9.2-alpine","9.2.0","9.1.4-bookworm"'
check "valkey: the -alpine suffix is kept (9.2.0-alpine), the two-part 9.2-alpine and other suffixes are ignored" bash -c "[ $rc = 10 ] && grep -qx 'VALKEY_TAG=9.2.0-alpine' '$root/ds.env'"
fresh; bump postgresql SKOPEO_FAIL=1 TAGS=''
check "an unreachable registry: exit 1, file unchanged, result=unreachable" bash -c "[ $rc = 1 ] && grep -qx 'result=unreachable' '$root/gho' && cmp -s '$here/variants/dx/datastore/datastore.env' '$root/ds.env'"
fresh; bump postgresql TAGS='"latest","alpine"'
check "no tag that looks like the pin: exit 1, file unchanged" bash -c "[ $rc = 1 ] && cmp -s '$here/variants/dx/datastore/datastore.env' '$root/ds.env'"
fresh; sed -i 's/^KAFKA_DIGEST=.*/KAFKA_DIGEST=sha256:short/' "$root/ds.env"; bump kafka TAGS='"4.4.0"'
check "a malformed pin: exit 3, no registry call" bash -c "[ $rc = 3 ] && ! grep -q skopeo '$LOG'"
fresh; bump nosuch TAGS=''
check "an unknown service: exit 3" test "$rc" = 3
fresh; sed -i 's/^POSTGRESQL_TAG=.*/POSTGRESQL_TAG=18.1-alpine/' "$root/ds.env"; bump postgresql TAGS='"18.1-alpine"'
check "a tag outside the pinned major in the file is a bad pin" test "$rc" = 3
check "the workflow picks this script for the four datastore images and passes the major note to the pull request body" bash -c "grep -q 'datastore-pin-bump.sh \"\\\${IMAGE}\"' '$here/.github/workflows/bump-pins.yml' && grep -q 'MAJOR_NOTE' '$here/.github/workflows/bump-pins.yml' && grep -q 'Majors are never bumped automatically' '$here/.github/workflows/bump-pins.yml'"
echo
echo "passed: $pass, failed: $failn"
[ "$failn" = 0 ]
