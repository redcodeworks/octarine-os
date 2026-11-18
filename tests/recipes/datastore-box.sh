#!/usr/bin/env bash
# Tests for the datastore box recipes (variants/dx/system_files/usr/share/ublue-os/just/73-octarine-datastore-box.just).
# podman and distrobox are fakes on PATH that log their calls; nothing real is touched. Needs: bash, just.
# Run: tests/recipes/datastore-box.sh
set -uo pipefail

here=$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)
justfile="$here/variants/dx/system_files/usr/share/ublue-os/just/73-octarine-datastore-box.just"
ini="$here/variants/dx/system_files/usr/share/octarine-os/datastore/datastore.ini"
root=$(mktemp -d)
trap 'rm -rf -- "$root"' EXIT
pass=0
failn=0
bin="$root/bin"
mkdir -p "$bin"
export LOG="$root/log" HAS_BOX="$root/has_box" HAS_NET="$root/has_net"
export DATASTORE_BOX_INI="$ini"

cat >"$bin/podman" <<'F'
#!/usr/bin/env bash
echo "podman $*" >>"$LOG"
case "$1 $2" in
    "container exists") [ -e "$HAS_BOX" ] ;;
    "network exists") [ -e "$HAS_NET" ] ;;
    "network create") touch "$HAS_NET" ;;
    *) exit 0 ;;
esac
F
cat >"$bin/distrobox" <<'F'
#!/usr/bin/env bash
echo "distrobox $*" >>"$LOG"
exit "${DISTROBOX_RC:-0}"
F
chmod +x "$bin/podman" "$bin/distrobox"
sysbin="$root/sysbin"
mkdir -p "$sysbin"
for c in bash sh env cat grep awk tr cut sed mkdir rm dirname head tail id touch; do
	p=$(command -v "$c") && ln -sf "$p" "$sysbin/$c"
done
JUST=$(command -v just)

# run ARGS...: runs a recipe with the fakes only on PATH; sets OUT and RC
run() {
	: >"$LOG"
	OUT=$(PATH="$bin:$sysbin" "$JUST" --justfile "$justfile" "$@" 2>&1)
	RC=$?
}
ok() {
	pass=$((pass + 1))
	echo "ok   $1"
}
bad() {
	failn=$((failn + 1))
	echo "FAIL $1"
	echo "$OUT" | sed 's/^/     | /'
	echo "     log:"
	sed 's/^/     | /' "$LOG"
}
expect() { # name, condition...
	local name=$1
	shift
	if "$@"; then ok "$name"; else bad "$name"; fi
}
logged() { grep -qxF -- "$1" "$LOG"; }
line_no() { grep -nxF -- "$1" "$LOG" | head -1 | cut -d: -f1; }

# --- create
rm -f "$HAS_BOX" "$HAS_NET"
run datastore-box-create
expect "create: succeeds" test "$RC" = 0
expect "create: makes the lakehouse network when it is missing" logged "podman network create lakehouse"
expect "create: assembles from the shipped file" logged "distrobox assemble create --file $ini"
expect "create: the network step runs before the assemble" test "$(line_no 'podman network create lakehouse')" -lt "$(line_no "distrobox assemble create --file $ini")"
expect "create: names the next step" grep -q "ujust datastore-box setup" <<<"$OUT"

touch "$HAS_NET"
rm -f "$HAS_BOX"
run datastore-box-create
expect "create: an existing network is left alone" bash -c '! grep -q "network create" "$LOG"'
expect "create: assemble still runs" logged "distrobox assemble create --file $ini"

touch "$HAS_BOX"
run datastore-box-create
expect "create: an existing box is not touched (exit 0, no assemble)" bash -c 'test "$1" = 0 && ! grep -q assemble "$2"' _ "$RC" "$LOG"

rm -f "$HAS_BOX"
DISTROBOX_RC=1 run datastore-box-create
expect "create: a failed assemble exits non-zero with a plain message" bash -c 'test "$1" != 0 && grep -q "assemble failed" <<<"$2"' _ "$RC" "$OUT"

run datastore-box-create --help
expect "create: --help changes nothing" bash -c 'test "$1" = 0 && ! test -s "$2"' _ "$RC" "$LOG"
run datastore-box-create --bogus
expect "create: an unknown option exits 2" test "$RC" = 2

# --- verbs
touch "$HAS_BOX"
for v in "setup" "start" "stop kafka" "restart all" "enable" "disable" "status" "logs postgres" "psql" "valkey-cli" "secrets export --replace" "backup /tmp/b --stop" "restore /tmp/x.sql" "render /tmp/r"; do
	# shellcheck disable=SC2086
	run datastore-box $v
	expect "verb '$v' maps to: distrobox enter datastore -- datastore $v" logged "distrobox enter datastore -- datastore $v"
done

run datastore-box
expect "verbs: no argument prints usage and calls nothing" bash -c 'test "$1" = 0 && grep -q "Usage: ujust datastore-box" <<<"$2" && ! test -s "$3"' _ "$RC" "$OUT" "$LOG"
run datastore-box --help
expect "verbs: --help calls nothing" bash -c 'test "$1" = 0 && ! test -s "$2"' _ "$RC" "$LOG"
run datastore-box frobnicate
expect "verbs: an unknown verb exits 2 and runs nothing" bash -c 'test "$1" = 2 && ! grep -q "distrobox" "$2"' _ "$RC" "$LOG"

rm -f "$HAS_BOX"
run datastore-box status
expect "verbs: a missing box gives a plain message and exit 1" bash -c 'test "$1" = 1 && grep -q "ujust datastore-box-create" <<<"$2" && ! grep -q "distrobox" "$3"' _ "$RC" "$OUT" "$LOG"

# --- the shipped file
expect "ini: the section, image and network aliases" bash -c 'grep -qx "\[datastore\]" "$1" && grep -qx "image=ghcr.io/redcodeworks/datastore:latest" "$1" && grep -q "network-alias kafka" "$1" && grep -q "^unshare_netns=true" "$1"' _ "$ini"

echo "datastore-box: $pass passed, $failn failed"
[ "$failn" = 0 ]
