#!/usr/bin/env bash
# Tests for the sched_ext scheduler runtime (no scheduler is ever loaded here): the generated registry, the polkit rule (node, with simulated actions) and the root-side
# helpers scx-preflight, scx-run and scx-verify (markers, failure counting). Needs: bash, node, flock, awk.
# Run: tests/image/schedulers.sh
set -uo pipefail

here=$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)
root=$(mktemp -d)
trap 'rm -rf -- "${root:?}"' EXIT
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
	[ -f "$root/out" ] && sed 's/^/     /' "$root/out"
	[ -f "$root/run" ] && sed 's/^/     run: /' "$root/run"
	echo "     rc=$rc"
}
check() {
	local d=$1
	shift
	if "$@" >"$root/out" 2>&1; then ok "$d"; else bad "$d"; fi
}
lib="$here/system_files/usr/libexec/octarine-os"
# the source list (octarine-bins keeps the real one in src/scx/schedulers.tsv; the installed manifest has four fields, see tests/install-binaries.sh): a fixture here
tsv_src="$root/schedulers-src.tsv"
printf 'scx_rusty\t\tHybrid scheduler\nscx_lavd\t\tLatency scheduler\nscx_cake\t\tGaming scheduler\nscx_bpfland\t\tInteractive scheduler\nscx_cosmos\t\tLocality scheduler\nscx_flash\t\tDeadline scheduler\nscx_p2dq\t\tPick-two scheduler\n' >"$tsv_src"
# the instance names come from the manifest source (name without scx_), not from a literal list
real_names=$(grep -vE '^[[:space:]]*(#|$)' "$tsv_src" | cut -f1 | sed 's/^scx_//' | tr '\n' ' ')
real_names=${real_names% }
alt=${real_names// /|}

# ---- the registry and the drop-ins generated from the manifest
mk_dest() { # dest, tsv content on stdin
	rm -rf "${1:?}"
	mkdir -p "$1/usr/share/octarine-os/polkit" "$1/usr/bin"
	cp "$here/system_files/usr/share/octarine-os/polkit/50-octarine-scx.rules.in" "$1/usr/share/octarine-os/polkit/"
	mkdir -p "$1/usr/lib/systemd/system"
	cp "$here/system_files/usr/lib/systemd/system/scx@.service" "$1/usr/lib/systemd/system/"
	cat >"$1/usr/share/octarine-os/schedulers.tsv"
	while IFS= read -r l; do [ -n "$l" ] && {
		n=$(cut -f1 <<<"$l")
		printf '#!/bin/sh\n' >"$1/usr/bin/$n"
		chmod +x "$1/usr/bin/$n"
	}; done <"$1/usr/share/octarine-os/schedulers.tsv"
}
# the real source list as the installed four-field manifest (name, bin/name, minimum kernel, description)
grep -vE '^[[:space:]]*(#|$)' "$tsv_src" | awk -F'\t' '{ printf "%s\tbin/%s\t%s\t%s\n", $1, $1, $2, $3 }' >"$root/real4.tsv"
d="$root/dest"
mk_dest "$d" <"$root/real4.tsv"
gen() {
	DESTDIR="$1" bash "$here/build_files/gen-schedulers.sh" >"$root/run" 2>&1
	rc=$?
}
gen "$d"
reg="$d/usr/share/octarine-os/schedulers.d"
check "gen: one registry file per scheduler, instance = name without scx_" bash -c "[ $rc = 0 ] && [ \"\$(ls '$reg' | sed 's/.conf$//' | sort | tr '\n' ' ')\" = \"\$(echo $real_names | tr ' ' '\n' | sort | tr '\n' ' ')\" ]"
# ---- the polkit rule: GENERATED from the template and the registry, tested with simulated actions (node)
rules="$d/usr/share/polkit-1/rules.d/50-octarine-scx.rules"
tpl="$here/system_files/usr/share/octarine-os/polkit/50-octarine-scx.rules.in"
cat >"$root/rule-test.js" <<'JSEOF'
const fs = require("fs");
let handler = null;
const polkit = { addRule: (f) => { handler = f; }, Result: { YES: "YES", NO: "NO", AUTH_ADMIN: "AUTH_ADMIN", NOT_HANDLED: undefined } };
eval(fs.readFileSync(process.argv[2], "utf8"));
const names = process.argv[3].split(" ").filter(Boolean);
const action = (id, details) => ({ id, lookup: (k) => details[k] });
const subj = (o) => Object.assign({ local: true, active: true, isInGroup: (g) => g === "wheel" }, o);
const MU = "org.freedesktop.systemd1.manage-units";
const cases = [];
for (const n of names) for (const v of ["start", "stop"]) cases.push([`registered ${n} ${v}`, action(MU, { unit: `scx@${n}.service`, verb: v }), subj({}), "YES"]);
for (const n of names) cases.push([`restart is not granted for ${n}`, action(MU, { unit: `scx@${n}.service`, verb: "restart" }), subj({}), undefined]);
cases.push(
  ["unregistered name evil", action(MU, { unit: "scx@evil.service", verb: "start" }), subj({}), undefined],
  ["a registered name plus a suffix (rusty2)", action(MU, { unit: "scx@rusty2.service", verb: "start" }), subj({}), undefined],
  ["a registered name in uppercase", action(MU, { unit: "scx@RUSTY.service", verb: "start" }), subj({}), undefined],
  ["two instances", action(MU, { unit: "scx@rusty@lavd.service", verb: "start" }), subj({}), undefined],
  ["different unit", action(MU, { unit: "sshd.service", verb: "start" }), subj({}), undefined],
  ["verb kill", action(MU, { unit: "scx@rusty.service", verb: "kill" }), subj({}), undefined],
  ["verb start;kill", action(MU, { unit: "scx@rusty.service", verb: "start;kill" }), subj({}), undefined],
  ["inactive subject", action(MU, { unit: "scx@rusty.service", verb: "start" }), subj({ active: false }), undefined],
  ["remote subject", action(MU, { unit: "scx@rusty.service", verb: "start" }), subj({ local: false }), undefined],
  ["not in wheel", action(MU, { unit: "scx@rusty.service", verb: "start" }), subj({ isInGroup: () => false }), undefined],
  ["manage-unit-files (enable) is not granted", action("org.freedesktop.systemd1.manage-unit-files", { unit: "scx@rusty.service", verb: "enable" }), subj({}), undefined],
);
let bad = 0;
for (const [name, a, s, want] of cases) {
  const got = handler(a, s);
  if (got !== want) { console.log("FAIL " + name + ": got " + got + ", want " + want); bad++; } else { console.log("ok   " + name); }
}
console.log(cases.length + " simulated actions");
process.exit(bad ? 1 : 0);
JSEOF
if command -v node >/dev/null; then
	check "polkit rule (node, GENERATED rule): each of the real names matches for start and stop, restart does not match for any; unregistered, suffixed, hyphenated, uppercase and empty names, other verbs and subjects do not" node "$root/rule-test.js" "$rules" "$real_names"
else
	bad "polkit rule test needs node (install nodejs)"
fi
# adding a scheduler is one line in the manifest: the rule follows
{
	cat "$root/real4.tsv"
	printf 'scx_newone\tbin/scx_newone\t\tA new scheduler\n'
} | mk_dest "$root/dpol"
gen "$root/dpol"
check "polkit: adding one manifest line adds that instance to the generated rule, and it then matches" bash -c "[ $rc = 0 ] && grep -qF '|newone)' '$root/dpol/usr/share/polkit-1/rules.d/50-octarine-scx.rules' && node '$root/rule-test.js' '$root/dpol/usr/share/polkit-1/rules.d/50-octarine-scx.rules' '$real_names newone' | grep -q 'ok   registered newone stop' && ! grep -qF 'newone' '$rules'"
rm -rf "${root:?}/dpol"
# ---- the root-side helpers: instance validation, preflight, run, verify
export OCTARINE_SCX_REGISTRY="$root/reg" OCTARINE_SCX_SYSFS="$root/sys" OCTARINE_SCX_BTF="$root/btf" OCTARINE_SCX_STATE="$root/state" OCTARINE_SCX_KERNEL="6.99.0-test"
mkdir -p "$root/reg" "$root/sys/root" "$root/state" "$root/bin"
for n in rusty lavd; do printf 'NAME=scx_%s\nINSTANCE=%s\nBINARY=/usr/bin/scx_%s\nDESCRIPTION=%s test\nMIN_KERNEL=\nFLAGS=\n' $n $n $n $n >"$root/reg/$n.conf"; done
echo btf >"$root/btf"
# logger is a stub so nothing reaches the journal
printf '#!/bin/sh\necho "logger $*" >>"$LOGF"\n' >"$root/bin/logger"
chmod +x "$root/bin/logger"
export LOGF="$root/logf"
: >"$LOGF"
export PATH="$root/bin:$PATH"
pre() {
	bash "$lib/scx-preflight" "$@" >"$root/run" 2>&1
	rc=$?
}
pre rusty
check "preflight: a registered instance with BTF and no marker may start (exit 0)" test "$rc" = 0
mv "$root/btf" "$root/btf.off"
pre rusty
mv "$root/btf.off" "$root/btf"
check "preflight: no kernel BTF: refuses with exit 1 (the unit is skipped, not failed)" bash -c "[ $rc = 1 ] && grep -q 'BTF' '$root/run'"
mkdir -p "$root/state/scx-disabled"
echo "6.99.0-test" >"$root/state/scx-disabled/rusty"
pre rusty
r_cur=$rc
pre lavd
r_other=$rc
check "preflight: a marker holding the running kernel refuses that instance only" test "$r_cur" = 1 -a "$r_other" = 0
echo "6.1.0-older" >"$root/state/scx-disabled/rusty"
pre rusty
check "preflight: a marker for another kernel does not block (a new kernel is tried again)" test "$rc" = 0
rm -f "${root:?}/state/scx-disabled/rusty"
check "run: the binary comes only from the registry, under /usr/bin/scx_*, with a cleared environment" bash -c "grep -q -- '-i PATH=/usr/bin:/usr/sbin LANG=C' '$lib/scx-run' && grep -q 'bin/scx_' '$lib/scx-run'"
printf 'NAME=scx_evil\nINSTANCE=evil\nBINARY=/tmp/evil\nDESCRIPTION=x\nMIN_KERNEL=\nFLAGS=\n' >"$root/reg/evil.conf"
bash "$lib/scx-run" evil >"$root/run" 2>&1
rc=$?
check "run: a registry entry whose binary is not /usr/bin/scx_* is refused (exit 2)" bash -c "[ $rc = 2 ] && grep -q 'bad or missing binary' '$root/run'"
rm -f "${root:?}/reg/evil.conf"
# verify: success, failures, threshold, reset, interrupts
export OCTARINE_SCX_VERIFY_SECONDS=0 # one probe, no waiting: the failure paths still run (the real unit waits 5 s); a wait of 1 s made each of the ~25 failure and busy cases cost 1 to 2 s
ver() {
	bash "$lib/scx-verify" "$@" >"$root/run" 2>&1
	rc=$?
}
set_active() {
	echo enabled >"$root/sys/state"
	echo "${1}_1.1.4_x86_64_unknown_linux_gnu" >"$root/sys/root/ops"
}
set_inactive() {
	echo disabled >"$root/sys/state"
	rm -f "${root:?}/sys/root/ops"
}
set_active rusty
ver rusty
check "verify: the instance is the active scheduler: exit 0" test "$rc" = 0
set_active lavd
ver rusty
r_wrong=$rc
check "verify: another scheduler holds sched_ext (ops lavd): the start fails (non-zero) but nothing is counted and no marker is written" bash -c "[ $r_wrong != 0 ] && grep -q 'busy' '$root/run' && [ -z \"\$(find '$root/state' -type f)\" ]"
rm -rf "${root:?}/state/scx-failures" "${root:?}/state/scx-disabled"
set_inactive
ver rusty
ver rusty
check "verify: two consecutive failures: count 2, still no marker" bash -c "[ \"\$(cat '$root/state/scx-failures/rusty')\" = 2 ] && [ ! -e '$root/state/scx-disabled/rusty' ]"
ver rusty
check "verify: the third consecutive real failure (sched_ext not enabled) writes the marker with the running kernel" bash -c "[ \"\$(cat '$root/state/scx-disabled/rusty')\" = 6.99.0-test ] && grep -q 'disabled for kernel 6.99.0-test' '$root/run'"
pre rusty
check "verify and preflight together: after the marker the instance is refused on this kernel" test "$rc" = 1
check "verify: the other instance is not affected by the marker" bash -c "[ ! -e '$root/state/scx-disabled/lavd' ]"
set_active rusty
ver rusty
check "verify: a success removes the failure count and the marker" bash -c "[ $rc = 0 ] && [ ! -e '$root/state/scx-failures/rusty' ] && [ ! -e '$root/state/scx-disabled/rusty' ]"

echo
echo "passed: $pass, failed: $failn"
[ "$failn" = 0 ]
