#!/usr/bin/env bash
# Tests of the thin datastore recipes of the dx image (`ujust datastore-install`, `datastore`, `datastore-setup`) with a stub podman:
# the pull, create, export and extract path, --digest, an old list-only bundle, the atomic replace, root refusal and the passthrough.
# Never touches the real home or the network. Needs: bash, just, tar. Run: tests/datastore-recipe.sh
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
rjust="$here/variants/dx/system_files/usr/share/ublue-os/just/72-octarine-datastore.just"
root=$(mktemp -d)
trap 'rm -rf -- "$root"' EXIT
pass=0; failn=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { failn=$((failn + 1)); echo "FAIL $1"; [ -f "$root/out" ] && sed 's/^/     /' "$root/out"; }
check() { local d=$1; shift; if "$@" >"$root/out" 2>&1; then ok "$d"; else bad "$d"; fi; }

# a new bundle (bin/datastore echoes what it was called with) and an old one (only the list)
mkdir -p "$root/new/bin" "$root/new/quadlets" "$root/old"
printf '#!/usr/bin/env bash\necho "bundle ARGS=$* UJUST=${DATASTORE_UJUST:-}"\n' >"$root/new/bin/datastore"; chmod +x "$root/new/bin/datastore"
echo "postgresql x" >"$root/new/images.txt"; echo "postgresql x" >"$root/old/images.txt"
echo marker-new >"$root/new/MARK"
bin="$root/bin"; mkdir -p "$bin"
cat >"$bin/podman" <<'F'
#!/usr/bin/env bash
echo "podman $*" >>"$LOG"
case "$1" in
    pull) [ -z "${FAKE_PULL_FAIL:-}" ] ;;
    create) echo cid-1 ;;
    export) tar -c -C "${FAKE_BUNDLE}" . ;;
    rm) ;;
esac
F
cat >"$bin/id" <<'F'
#!/usr/bin/env bash
echo "${FAKE_UID:-1000}"
F
chmod +x "$bin"/*
export LOG="$root/log" HOME="$root/home" XDG_DATA_HOME="$root/home/.local/share"
unset DATASTORE_BUNDLE_REF DATASTORE_BUNDLE_DIR
mkdir -p "$HOME"
dir="$HOME/.local/share/octarine-os/datastore"
run() { : >"$LOG"; PATH="$bin:$PATH" FAKE_BUNDLE="${FAKE_BUNDLE:-$root/new}" just --justfile "$rjust" "$@" >"$root/run" 2>&1; rc=$?; }
dg=sha256:$(printf 'a%.0s' $(seq 64))

check "the recipe file parses and lists the three recipes in group Setup, one-line descriptions" bash -c "
    [ \"\$(just --justfile '$rjust' --summary)\" = 'datastore datastore-install datastore-setup' ] &&
    [ \$(grep -c \"^\\[group('Setup')\\]\" '$rjust') = 3 ]"
check "no sudo, pkexec or run0 in the recipe file" bash -c "! grep -E '(sudo|pkexec|run0)' '$rjust'"

run datastore
check "datastore without the bundle: says to run ujust datastore-install, exit 1" bash -c "[ $rc = 1 ] && grep -q 'ujust datastore-install' '$root/run'"
run datastore-setup --status
check "datastore-setup without the bundle: the same message, exit 1" bash -c "[ $rc = 1 ] && grep -q 'ujust datastore-install' '$root/run'"

run datastore-install
check "install: pull of the latest tag, create, export and remove, then the bundle's install runs with DATASTORE_UJUST=1" bash -c "
    [ $rc = 0 ] && grep -qx 'podman pull ghcr.io/redcodeworks/datastore-images:latest' '$LOG' && grep -q '^podman create ghcr.io/redcodeworks/datastore-images:latest' '$LOG' &&
    grep -qx 'podman export cid-1' '$LOG' && grep -qx 'podman rm cid-1' '$LOG' && grep -qx 'bundle ARGS=install UJUST=1' '$root/run'"
check "install: the bundle is unpacked in ~/.local/share/octarine-os/datastore, no temporary directory is left, the undo is printed" bash -c "
    [ -x '$dir/bin/datastore' ] && [ -z \"\$(ls '$HOME/.local/share/octarine-os' | grep -v '^datastore\$')\" ] && grep -q 'undo' '$root/run'"

run datastore status --no
check "datastore passes its arguments through with DATASTORE_UJUST=1" grep -qx 'bundle ARGS=status --no UJUST=1' "$root/run"
run datastore-setup --pin postgresql=17.1
check "datastore-setup passes 'setup' and its arguments through with DATASTORE_UJUST=1" grep -qx 'bundle ARGS=setup --pin postgresql=17.1 UJUST=1' "$root/run"

run datastore-install --digest "$dg"
check "install --digest pulls that digest of the same repository" bash -c "[ $rc = 0 ] && grep -qx 'podman pull ghcr.io/redcodeworks/datastore-images@$dg' '$LOG'"
DATASTORE_BUNDLE_REF=localhost:5000/x/b:tag run datastore-install --digest "$dg"
check "install --digest keeps a registry port and drops only the tag" bash -c "grep -qx 'podman pull localhost:5000/x/b@$dg' '$LOG'"
run datastore-install --digest nonsense
check "install: a malformed digest exits 2 and pulls nothing" bash -c "[ $rc = 2 ] && ! grep -q pull '$LOG'"
run datastore-install --bogus
check "install: an unknown option exits 2" test "$rc" = 2

# replace: the directory is swapped as a whole, a failed or old pull keeps the installed one
echo stale >"$dir/STALE"
FAKE_BUNDLE="$root/new" run datastore-install
check "install again: the directory is replaced (nothing of the earlier copy remains), no .old or .new leftovers" bash -c "
    [ $rc = 0 ] && [ ! -e '$dir/STALE' ] && [ -f '$dir/MARK' ] && [ -z \"\$(ls '$HOME/.local/share/octarine-os' | grep -v '^datastore\$')\" ]"
echo keep >"$dir/KEEP"
FAKE_BUNDLE="$root/old" run datastore-install
check "install of an old list-only bundle: says so, exits 1, the installed bundle is untouched, nothing is left over" bash -c "
    [ $rc = 1 ] && grep -q 'without bin/datastore' '$root/run' && [ -f '$dir/KEEP' ] && [ -z \"\$(ls '$HOME/.local/share/octarine-os' | grep -v '^datastore\$')\" ] && grep -qx 'podman rm cid-1' '$LOG'"
FAKE_PULL_FAIL=1 run datastore-install
check "install: a failed pull (network or policy) exits 1, mentions the policy, keeps the installed bundle" bash -c "[ $rc = 1 ] && grep -qi 'policy' '$root/run' && [ -f '$dir/KEEP' ]"
rm -rf "$HOME/.local/share/octarine-os"
FAKE_BUNDLE="$root/old" run datastore-install
check "install of an old bundle on a fresh machine leaves no directory behind" bash -c "[ $rc = 1 ] && [ -z \"\$(ls '$HOME/.local/share/octarine-os' 2>/dev/null)\" ]"

for r in datastore-install "datastore status" "datastore-setup --yes"; do
    FAKE_UID=0 run $r
    check "'$r' refuses root, exit 1, no podman call" bash -c "[ $rc = 1 ] && grep -q 'not as root' '$root/run' && ! grep -q podman '$LOG'"
done

echo "passed: $pass, failed: $failn"
[ "$failn" = 0 ]
