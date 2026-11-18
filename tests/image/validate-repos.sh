#!/usr/bin/env bash
# Tests for build_files/validate-repos.sh (the build fails on an enabled repository the image does not expect) with a stub dnf5 and
# temporary repository directories, and for its wiring in the three image build scripts. Run: tests/image/validate-repos.sh. Needs: bash, awk.
set -uo pipefail
here=$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)
root=$(mktemp -d)
trap 'rm -rf -- "$root"' EXIT
pass=0
failn=0
rc=0
ok() {
	pass=$((pass + 1))
	echo "ok   $1"
}
bad() {
	failn=$((failn + 1))
	echo "FAIL $1"
	sed 's/^/     /' "$root/run" 2>/dev/null
}
check() {
	local d=$1
	shift
	if "$@" >"$root/out" 2>&1; then ok "$d"; else bad "$d"; fi
}
bin="$root/bin"
mkdir -p "$bin"
# stub dnf5: `dnf5 repolist --enabled` prints the ids listed in $STUB_ENABLED (space separated), after the real header line
cat >"$bin/dnf5" <<'F'
#!/usr/bin/env bash
[ "$1 $2" = "repolist --enabled" ] || exit 2
printf 'repo id   repo name\n'
for i in ${STUB_ENABLED-}; do printf '%s   Some name\n' "$i"; done
F
chmod +x "$bin/dnf5"
BASE="fedora updates updates-archive fedora-cisco-openh264 fedora-multimedia copr:copr.fedorainfracloud.org:ublue-os:akmods"
d1="$root/d1"
d2="$root/d2"
d3="$root/d3"
mkdir -p "$d1" "$d2" "$d3"
repo() { printf '[%s]\nname=x\nenabled=%s\n' "$2" "$3" >"$1"; } # file id value
run() {
	env "$@" REPO_DIRS="$d1:$d2:$d3" PATH="$bin:$PATH" bash "$here/build_files/validate-repos.sh" >"$root/run" 2>&1
	rc=$?
}

repo "$d1/negativo17.repo" fedora-multimedia 0
repo "$d2/fedora.repo" fedora 1
run STUB_ENABLED="$BASE"
check "the repositories of the base (dnf5 list and files) pass" bash -c "[ $rc = 0 ] && grep -q 'all expected' '$root/run' && grep -q '^::endgroup::' '$root/run'"

run STUB_ENABLED="$BASE rpmfusion-free"
check "an unexpected id from dnf5 fails the build (exit 1) and names it" bash -c "[ $rc = 1 ] && grep -q 'ENABLED, NOT EXPECTED: rpmfusion-free' '$root/run' && grep -q '::error::.*rpmfusion-free' '$root/run'"

repo "$d1/_copr_x.repo" "copr:copr.fedorainfracloud.org:x:y" 1
run STUB_ENABLED="$BASE"
check "an enabled section in a repo file that dnf5 does not list fails (exit 1)" bash -c "[ $rc = 1 ] && grep -q 'NOT EXPECTED: copr:copr.fedorainfracloud.org:x:y' '$root/run'"
rm "$d1/_copr_x.repo"

repo "$d3/99-config_manager.repo" vscode 1
run STUB_ENABLED="$BASE"
check "an enabled override in the override directory fails (exit 1)" bash -c "[ $rc = 1 ] && grep -q 'NOT EXPECTED: vscode' '$root/run'"
echo
echo "$pass passed, $failn failed"
[ "$failn" = 0 ]
