#!/usr/bin/env bash
# Tests for build_files/validate-repos.sh (the build fails on an enabled repository the image does not expect) with a stub dnf5 and
# temporary repository directories, and for its wiring in the three image build scripts. Run: tests/validate-repos.sh. Needs: bash, awk.
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
root=$(mktemp -d); trap 'rm -rf -- "$root"' EXIT
pass=0; failn=0; rc=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { failn=$((failn + 1)); echo "FAIL $1"; sed 's/^/     /' "$root/run" 2>/dev/null; }
check() { local d=$1; shift; if "$@" >"$root/out" 2>&1; then ok "$d"; else bad "$d"; fi; }
bin="$root/bin"; mkdir -p "$bin"
# stub dnf5: `dnf5 repolist --enabled` prints the ids listed in $STUB_ENABLED (space separated), after the real header line
cat >"$bin/dnf5" <<'F'
#!/usr/bin/env bash
[ "$1 $2" = "repolist --enabled" ] || exit 2
printf 'repo id   repo name\n'
for i in ${STUB_ENABLED-}; do printf '%s   Some name\n' "$i"; done
F
chmod +x "$bin/dnf5"
BASE="fedora updates updates-archive fedora-cisco-openh264 fedora-multimedia copr:copr.fedorainfracloud.org:ublue-os:akmods"
d1="$root/d1"; d2="$root/d2"; d3="$root/d3"; mkdir -p "$d1" "$d2" "$d3"
repo() { printf '[%s]\nname=x\nenabled=%s\n' "$2" "$3" >"$1"; }  # file id value
run() { env "$@" REPO_DIRS="$d1:$d2:$d3" PATH="$bin:$PATH" bash "$here/build_files/validate-repos.sh" >"$root/run" 2>&1; rc=$?; }

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
rm "$d3/99-config_manager.repo"

printf '[tailscale-stable]\nname=x\nenabled = 1\n' >"$d1/tailscale.repo"
run STUB_ENABLED="$BASE"
check "the spaced form 'enabled = 1' is recognised" bash -c "[ $rc = 1 ] && grep -q 'NOT EXPECTED: tailscale-stable' '$root/run'"
repo "$d1/tailscale.repo" tailscale-stable 0
run STUB_ENABLED="$BASE"
check "the same repository with enabled=0 passes" bash -c "[ $rc = 0 ]"

printf '[a]\nenabled=1\n[b]\nenabled=0\n' >"$d1/two.repo"
run STUB_ENABLED="$BASE"
check "only the section that is enabled is named (a, not b)" bash -c "[ $rc = 1 ] && grep -q 'NOT EXPECTED: a\$' '$root/run' && ! grep -q 'NOT EXPECTED: b\$' '$root/run'"
rm "$d1/two.repo"

env STUB_ENABLED="$BASE" REPO_DIRS="$root/nope1:$root/nope2" PATH="$bin:$PATH" bash "$here/build_files/validate-repos.sh" >"$root/run" 2>&1; rc=$?
check "missing directories are fine" bash -c "[ $rc = 0 ] && grep -q 'does not exist' '$root/run'"

env STUB_ENABLED="$BASE" DNF5="$root/no-such-dnf5" REPO_DIRS="$d1:$d2:$d3" bash "$here/build_files/validate-repos.sh" >"$root/run" 2>&1; rc=$?
check "without dnf5 only the files are checked (and pass when they hold nothing unexpected)" bash -c "[ $rc = 0 ] && grep -q 'files only' '$root/run'"

check "the allow-list holds exactly the repository ids the base enables (fedora, updates, updates-archive, fedora-cisco-openh264, fedora-multimedia, the ublue akmods COPR)" bash -c "awk '/^ALLOWED=\\(/{f=1;next} /^\\)/{f=0} f' '$here/build_files/validate-repos.sh' | tr -d ' \"' | sort | tr '\\n' ' ' | grep -qx 'copr:copr.fedorainfracloud.org:ublue-os:akmods fedora fedora-cisco-openh264 fedora-multimedia updates updates-archive '"

for s in build_files/build.sh variants/dx/dx.sh variants/nvidia/nvidia.sh; do
    check "$s runs validate-repos.sh before final-cleanup.sh" bash -c "a=\$(grep -n '/ctx/validate-repos.sh' '$here/$s' | head -1 | cut -d: -f1); b=\$(grep -n '^/ctx/final-cleanup.sh' '$here/$s' | cut -d: -f1); [ -n \"\$a\" ] && [ -n \"\$b\" ] && [ \"\$a\" -lt \"\$b\" ]"
done
for c in variants/dx/Containerfile variants/nvidia/Containerfile; do
    check "$c copies validate-repos.sh into the build context" grep -q 'COPY build_files/validate-repos.sh /validate-repos.sh' "$here/$c"
done
check "the shell syntax of the script is valid" bash -n "$here/build_files/validate-repos.sh"
echo; echo "$pass passed, $failn failed"; [ "$failn" = 0 ]
