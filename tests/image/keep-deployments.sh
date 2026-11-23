#!/usr/bin/env bash
# Tests for keep-deployments (the five-newest boot entries): which deployments get pinned or unpinned for a given `ostree admin status`, with a fake `ostree`.
# Needs: bash, awk.
# Run: tests/image/keep-deployments.sh
set -uo pipefail

here=$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)
root=$(mktemp -d)
trap 'rm -rf -- "${root:?}"' EXIT
script="$here/system_files/usr/libexec/octarine-os/keep-deployments"
pass=0
failn=0

# a fake ostree: `admin status` prints the fixture, `admin pin ...` logs its arguments
mkdir "$root/bin"
cat >"$root/bin/ostree" <<'FAKE'
#!/usr/bin/env bash
case "$1 $2" in
"admin status") cat "$FIXTURE" ;;
"admin pin") shift 2 && { [[ "$1" == --unpin ]] && echo "unpin $2" || echo "pin $1"; } >>"$CALLS" ;;
*) exit 1 ;;
esac
FAKE
chmod +x "$root/bin/ostree"

# entry <booted:0|1> <pinned:0|1> [label]: one deployment as `ostree admin status` prints it
n=0
entry() {
	n=$((n + 1))
	printf '%s default %064d.0%s\n' "$([[ $1 == 1 ]] && echo '*' || echo ' ')" "$n" "${3:+ ($3)}"
	[[ $2 == 0 ]] || echo '    Pinned: yes'
	echo '    origin: <unknown origin type>'
}

# run <name> <expected calls, one per line> <KEEP> with the fixture on stdin
run() {
	rm -f "$root/calls"
	touch "$root/calls"
	cat >"$root/fixture"
	FIXTURE="$root/fixture" CALLS="$root/calls" KEEP_DEPLOYMENTS="${3:-5}" PATH="$root/bin:$PATH" bash "$script" >"$root/out" 2>&1
	local rc=$?
	if [[ $rc == 0 && "$(cat "$root/calls")" == "$2" ]]; then
		pass=$((pass + 1))
		echo "ok   $1"
	else
		failn=$((failn + 1))
		echo "FAIL $1 (rc=$rc), calls:"
		sed 's/^/     /' "$root/calls"
	fi
}

# the cases: the fixture is built by a process substitution (a pipe would run `run` in a subshell and lose the counters)
n=0
run "the booted one is pinned, the hand pin stays" "pin 1" < <(
	entry 0 0 staged
	entry 1 0
	entry 0 1 rollback
)
n=0
run "nothing to do when everything is pinned" "" < <(
	entry 1 1
	entry 0 1 rollback
)
n=0
run "the pins after the fifth are removed" $'pin 0\nunpin 5\nunpin 6' < <(
	entry 1 0
	for _ in 1 2 3 4 5 6; do entry 0 1; done
)
n=0
run "a staged one is never pinned and does not count" "unpin 6" < <(
	entry 0 0 staged
	entry 1 1
	for _ in 1 2 3 4 5; do entry 0 1; done
)
n=0
run "the booted one stays pinned after a rollback past five" "unpin 5" < <(
	for _ in 1 2 3 4 5 6; do entry 0 1; done
	entry 1 1
)
n=0
run "unpinned entries do not count against the limit" $'pin 2\nunpin 3' 2 < <(
	entry 0 1
	entry 0 0
	entry 1 0
	entry 0 1
)
n=0
run "the limit comes from KEEP_DEPLOYMENTS" "unpin 2" 2 < <(
	entry 1 1
	entry 0 1
	entry 0 1
)

echo "passed: $pass, failed: $failn"
[[ "$failn" == 0 ]]
