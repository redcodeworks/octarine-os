#!/usr/bin/env bash
# Tests for the sched_ext scheduler runtime of the image (no scheduler is ever loaded here): the registry and unit drop-ins
# generated from the manifest (build_files/gen-schedulers.sh), the template unit and the preset, the polkit rule (node, with
# simulated actions), the root-side helpers scx-preflight, scx-run and scx-verify (instance validation, markers, failure counting)
# and the GameMode hooks (stub systemctl and friends). The recipe is tests/scheduler-recipe.sh. Needs: bash, node, flock, awk.
# Run: tests/schedulers.sh
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
root=$(mktemp -d)
trap 'rm -rf -- "${root:?}"' EXIT
pass=0
failn=0
rc=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { failn=$((failn + 1)); echo "FAIL $1"; [ -f "$root/out" ] && sed 's/^/     /' "$root/out"; [ -f "$root/run" ] && sed 's/^/     run: /' "$root/run"; echo "     rc=$rc"; }
check() { local d=$1; shift; if "$@" >"$root/out" 2>&1; then ok "$d"; else bad "$d"; fi; }
lib="$here/system_files/usr/libexec/octarine-os"
tsv_src="$here/binaries/scx/schedulers.tsv"
real_names="rusty lavd cake bpfland cosmos flash p2dq"

# ---- the registry and the drop-ins generated from the manifest
mk_dest() { # dest, tsv content on stdin
    rm -rf "${1:?}"; mkdir -p "$1/usr/share/octarine-os/polkit" "$1/usr/bin"
    cp "$here/system_files/usr/share/octarine-os/polkit/50-octarine-scx.rules.in" "$1/usr/share/octarine-os/polkit/"
    mkdir -p "$1/usr/lib/systemd/system"; cp "$here/system_files/usr/lib/systemd/system/scx@.service" "$1/usr/lib/systemd/system/"
    cat >"$1/usr/share/octarine-os/schedulers.tsv"
    while IFS= read -r l; do [ -n "$l" ] && { n=$(cut -f1 <<<"$l"); printf '#!/bin/sh\n' >"$1/usr/bin/$n"; chmod +x "$1/usr/bin/$n"; }; done <"$1/usr/share/octarine-os/schedulers.tsv"
}
# the real source list as the installed four-field manifest (name, bin/name, minimum kernel, description)
grep -vE '^[[:space:]]*(#|$)' "$tsv_src" | awk -F'\t' '{ printf "%s\tbin/%s\t%s\t%s\n", $1, $1, $2, $3 }' >"$root/real4.tsv"
d="$root/dest"; mk_dest "$d" <"$root/real4.tsv"
gen() { DESTDIR="$1" bash "$here/build_files/gen-schedulers.sh" >"$root/run" 2>&1; rc=$?; }
gen "$d"
reg="$d/usr/share/octarine-os/schedulers.d"
check "gen: one registry file per scheduler, instance = name without scx_ (rusty lavd cake bpfland cosmos flash p2dq)" bash -c "[ $rc = 0 ] && [ \"\$(ls '$reg' | sed 's/.conf$//' | sort | tr '\n' ' ')\" = \"\$(echo $real_names | tr ' ' '\n' | sort | tr '\n' ' ')\" ]"
check "gen: no registered instance name is another one followed by _ (the ops-name prefix match must stay unambiguous; a new scheduler that breaks this needs a smarter match)" bash -c "for a in \$(ls '$reg' | sed 's/.conf\$//'); do for b in \$(ls '$reg' | sed 's/.conf\$//'); do case \$b in \${a}_*) echo ambiguous: \$a \$b; exit 1;; esac; done; done"
check "gen: registry fields NAME INSTANCE BINARY DESCRIPTION MIN_KERNEL FLAGS, empty minimum kernel kept empty" bash -c "grep -qx 'NAME=scx_rusty' '$reg/rusty.conf' && grep -qx 'INSTANCE=rusty' '$reg/rusty.conf' && grep -qx 'BINARY=/usr/bin/scx_rusty' '$reg/rusty.conf' && grep -qx 'MIN_KERNEL=' '$reg/rusty.conf' && grep -qx 'FLAGS=' '$reg/rusty.conf' && grep -q '^DESCRIPTION=.\\{10,\\}' '$reg/rusty.conf'"
check "gen: every description of the registry is the manifest's, at most 120 characters" bash -c "for n in $real_names; do dsc=\$(sed -n 's/^DESCRIPTION=//p' '$reg'/\$n.conf); [ -n \"\$dsc\" ] && [ \${#dsc} -le 120 ] && grep -qF -- \"\$dsc\" '$root/real4.tsv' || exit 1; done"
for n in $real_names; do
    dd="$d/usr/lib/systemd/system/scx@$n.service.d"
    others=$(for o in $real_names; do [ "$o" = "$n" ] || printf 'scx@%s.service ' "$o"; done)
    check "gen: scx@$n conflicts with exactly the six others, no kernel condition (minimum kernel empty)" bash -c "grep -qx 'Conflicts=${others% }' '$dd/10-conflicts.conf' && [ ! -e '$dd/20-kernel.conf' ]"
done
# a minimum kernel gives a ConditionKernelVersion drop-in
printf 'scx_a\tbin/scx_a\t6.12\tAlpha\nscx_b\tbin/scx_b\t\tBeta\n' | mk_dest "$root/d2"; gen "$root/d2"
check "gen: a registry minimum kernel (6.12) writes ConditionKernelVersion=>=6.12 for that instance only" bash -c "[ $rc = 0 ] && grep -qx 'ConditionKernelVersion=>=6.12' '$root/d2/usr/lib/systemd/system/scx@a.service.d/20-kernel.conf' && [ ! -e '$root/d2/usr/lib/systemd/system/scx@b.service.d/20-kernel.conf' ] && grep -qx 'MIN_KERNEL=6.12' '$root/d2/usr/share/octarine-os/schedulers.d/a.conf'"
printf 'scx_a\tbin/scx_a\t\tAlone\n' | mk_dest "$root/d3"; gen "$root/d3"
check "gen: a single scheduler gets a conflicts drop-in without a Conflicts= line" bash -c "[ $rc = 0 ] && ! grep -q 'Conflicts=' '$root/d3/usr/lib/systemd/system/scx@a.service.d/10-conflicts.conf'"
printf 'scx_a\tbin/scx_a\tAlpha without kernel field\n' | mk_dest "$root/d4"; gen "$root/d4"
check "gen: a manifest line with three fields (the empty one collapsed) fails" bash -c "[ $rc != 0 ] && grep -q 'four tab separated' '$root/run'"
printf 'bad name\tbin/bad name\t\tX\n' | mk_dest "$root/d5"; gen "$root/d5"
check "gen: a bad scheduler name fails" test "$rc" != 0
printf 'scx_a\tbin/scx_a\t\tAlpha\nscx_a\tbin/scx_a\t\tAgain\n' | mk_dest "$root/d6"; gen "$root/d6"
check "gen: a duplicate fails" test "$rc" != 0
printf 'scx_a\tbin/scx_a\t\t%s\n' "$(printf 'x%.0s' {1..121})" | mk_dest "$root/d7"; gen "$root/d7"
check "gen: a description over 120 characters fails" test "$rc" != 0
printf 'scx_a\tbin/scx_a\t\tAlpha\n' | mk_dest "$root/d8"; rm "$root/d8/usr/bin/scx_a"; gen "$root/d8"
check "gen: a scheduler whose binary is not installed fails" test "$rc" != 0
printf 'scx_a\tbin/scx_a\tsix\tAlpha\n' | mk_dest "$root/d9"; gen "$root/d9"
check "gen: a minimum kernel that is not MAJOR.MINOR fails" test "$rc" != 0
check "build.sh generates the registry after installing the binaries, and checks the helpers and the rule are there" bash -c "grep -qx '/ctx/gen-schedulers.sh' '$here/build_files/build.sh' && grep -q 'scx-preflight scx-run scx-verify gamemode-start gamemode-end' '$here/build_files/build.sh' && grep -q '50-octarine-scx.rules' '$here/build_files/build.sh'"

# ---- the template unit and the preset
u="$here/system_files/usr/lib/systemd/system/scx@.service"
check "unit: Type=simple, ExecCondition preflight, ExecStart run, ExecStartPost verify, all with %i" bash -c "grep -qx 'Type=simple' '$u' && grep -qx 'ExecCondition=/usr/libexec/octarine-os/scx-preflight %i' '$u' && grep -qx 'ExecStart=/usr/libexec/octarine-os/scx-run %i' '$u' && grep -qx 'ExecStartPost=/usr/libexec/octarine-os/scx-verify %i' '$u'"
check "unit: ConditionPathExists=/sys/kernel/sched_ext, Restart=on-failure, RestartSec=5, StartLimitIntervalSec=0" bash -c "grep -qx 'ConditionPathExists=/sys/kernel/sched_ext' '$u' && grep -qx 'Restart=on-failure' '$u' && grep -qx 'RestartSec=5' '$u' && grep -qx 'StartLimitIntervalSec=0' '$u'"
check "unit: no sandboxing or capability directives that could block loading a BPF scheduler (as upstream's unit)" bash -c "! grep -E '^(NoNewPrivileges|Protect[A-Za-z]*|Private[A-Za-z]*|Restrict[A-Za-z]*|SystemCallFilter|CapabilityBoundingSet|AmbientCapabilities|MemoryDenyWriteExecute|LockPersonality|User|DynamicUser)=' '$u'"
check "unit: no ConditionKernelVersion in the template (only generated per instance, when the registry has a minimum)" bash -c "! grep -q '^ConditionKernelVersion' '$u'"
check "preset: scx@ instances are disabled and nothing in system_files enables a scheduler" bash -c "grep -qx 'disable scx@\\*.service' '$here/system_files/usr/lib/systemd/system-preset/00-octarine-scx.preset' && ! grep -rE '^enable .*scx' '$here/system_files'"
check "build files never enable or start a scheduler" bash -c "! grep -E 'systemctl (enable|start|preset).*scx' '$here/build_files/build.sh' '$here/build_files/gen-schedulers.sh' '$here/build_files/install-binaries.sh'"

# ---- the polkit rule: GENERATED from the template and the registry, tested with simulated actions (node)
rules="$d/usr/share/polkit-1/rules.d/50-octarine-scx.rules"
tpl="$here/system_files/usr/share/octarine-os/polkit/50-octarine-scx.rules.in"
check "polkit: the repo has only the template (the rule that ships is generated at image build from the registry)" bash -c "[ -f '$tpl' ] && grep -q '@INSTANCES@' '$tpl' && [ ! -e '$here/system_files/usr/share/polkit-1/rules.d/50-octarine-scx.rules' ]"
check "polkit: the generated rule has the exact alternation of the registry instance names, no placeholder, no generic character class" bash -c "grep -qF '/^scx@(rusty|lavd|cake|bpfland|cosmos|flash|p2dq)\\.service\$/' '$rules' && ! grep -q '@INSTANCES@' '$rules' && ! grep -q 'A-Za-z0-9_-' '$rules'"
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
  ["a registered name as a prefix of another (rust)", action(MU, { unit: "scx@rust.service", verb: "start" }), subj({}), undefined],
  ["a name with a hyphen", action(MU, { unit: "scx@rusty-x.service", verb: "start" }), subj({}), undefined],
  ["a registered name in uppercase", action(MU, { unit: "scx@RUSTY.service", verb: "start" }), subj({}), undefined],
  ["scx@ without instance", action(MU, { unit: "scx@.service", verb: "start" }), subj({}), undefined],
  ["two instances", action(MU, { unit: "scx@rusty@lavd.service", verb: "start" }), subj({}), undefined],
  ["different unit", action(MU, { unit: "sshd.service", verb: "start" }), subj({}), undefined],
  ["unit that only contains scx@", action(MU, { unit: "evil-scx@rusty.service", verb: "start" }), subj({}), undefined],
  ["scx@ with a slash", action(MU, { unit: "scx@a/b.service", verb: "start" }), subj({}), undefined],
  ["scx@ with a space", action(MU, { unit: "scx@a b.service", verb: "start" }), subj({}), undefined],
  ["scx@ not a service", action(MU, { unit: "scx@rusty.timer", verb: "start" }), subj({}), undefined],
  ["missing verb", action(MU, { unit: "scx@rusty.service" }), subj({}), undefined],
  ["missing unit", action(MU, { verb: "start" }), subj({}), undefined],
  ["no details at all", action(MU, {}), subj({}), undefined],
  ["verb kill", action(MU, { unit: "scx@rusty.service", verb: "kill" }), subj({}), undefined],
  ["verb reload", action(MU, { unit: "scx@rusty.service", verb: "reload" }), subj({}), undefined],
  ["verb try-restart", action(MU, { unit: "scx@rusty.service", verb: "try-restart" }), subj({}), undefined],
  ["verb reload-or-restart", action(MU, { unit: "scx@rusty.service", verb: "reload-or-restart" }), subj({}), undefined],
  ["verb reset-failed", action(MU, { unit: "scx@rusty.service", verb: "reset-failed" }), subj({}), undefined],
  ["verb set-property", action(MU, { unit: "scx@rusty.service", verb: "set-property" }), subj({}), undefined],
  ["verb start;kill", action(MU, { unit: "scx@rusty.service", verb: "start;kill" }), subj({}), undefined],
  ["inactive subject", action(MU, { unit: "scx@rusty.service", verb: "start" }), subj({ active: false }), undefined],
  ["remote subject", action(MU, { unit: "scx@rusty.service", verb: "start" }), subj({ local: false }), undefined],
  ["not in wheel", action(MU, { unit: "scx@rusty.service", verb: "start" }), subj({ isInGroup: () => false }), undefined],
  ["manage-unit-files (enable) is not granted", action("org.freedesktop.systemd1.manage-unit-files", { unit: "scx@rusty.service", verb: "enable" }), subj({}), undefined],
  ["another action id", action("org.freedesktop.login1.reboot", { unit: "scx@rusty.service", verb: "start" }), subj({}), undefined],
  ["non-string unit", action(MU, { unit: 5, verb: "start" }), subj({}), undefined],
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
    check "polkit rule (node, GENERATED rule): each of the seven real names matches for start and stop, restart does not match for any; unregistered, suffixed, hyphenated, uppercase and empty names, other verbs and subjects do not" node "$root/rule-test.js" "$rules" "$real_names"
else
    bad "polkit rule test needs node (install nodejs)"
fi
# adding a scheduler is one line in the manifest: the rule follows
{ cat "$root/real4.tsv"; printf 'scx_newone\tbin/scx_newone\t\tA new scheduler\n'; } | mk_dest "$root/dpol"; gen "$root/dpol"
check "polkit: adding one manifest line adds that instance to the generated rule, and it then matches" bash -c "[ $rc = 0 ] && grep -qF '|newone)' '$root/dpol/usr/share/polkit-1/rules.d/50-octarine-scx.rules' && node '$root/rule-test.js' '$root/dpol/usr/share/polkit-1/rules.d/50-octarine-scx.rules' '$real_names newone' | grep -q 'ok   registered newone stop' && ! grep -qF 'newone' '$rules'"
rm -rf "${root:?}/dpol"
printf 'scx_a\tbin/scx_a\t\tAlpha\n' | mk_dest "$root/dpol2"; rm "$root/dpol2/usr/share/octarine-os/polkit/50-octarine-scx.rules.in"; gen "$root/dpol2"
check "polkit: a missing rule template fails the generation" test "$rc" != 0
printf 'scx_a\tbin/scx_a\t\tAlpha\n' | mk_dest "$root/dpol3"; rm "$root/dpol3/usr/lib/systemd/system/scx@.service"; gen "$root/dpol3"
check "polkit: the rule is never generated without the scx@.service template unit (StartTransientUnit under a matching name would otherwise create a root unit)" bash -c "[ $rc != 0 ] && grep -q 'not generating the polkit rule' '$root/run' && [ ! -e '$root/dpol3/usr/share/polkit-1/rules.d/50-octarine-scx.rules' ]"
check "guard: usr/lib/systemd/system/scx@.service exists in the tree under exactly that name, next to the rule template; both workflows' smoke tests check it and that the rule lists the registry instances" bash -c "[ -f '$here/system_files/usr/lib/systemd/system/scx@.service' ] && [ -f '$here/system_files/usr/share/octarine-os/polkit/50-octarine-scx.rules.in' ] && for w in build.yml build-beta.yml; do grep -q 'test -f /usr/lib/systemd/system/scx@.service' '$here/.github/workflows/'\$w && grep -q 'polkit rule: generated from the registry' '$here/.github/workflows/'\$w || exit 1; done"
check "polkit rule: YES is returned in one place only, the verbs are exactly start and stop (no restart), and the side doors are documented in the rule" bash -c "[ \$(grep -c 'polkit.Result.YES' '$tpl') = 1 ] && grep -q 'verb !== \"start\" && verb !== \"stop\") {' '$tpl' && ! grep -q 'restart\"' '$tpl' && grep -q 'FreezeUnit' '$tpl' && grep -q 'StartTransientUnit' '$tpl'"
check "nothing relies on an unprivileged restart of scx units (hooks, recipe, restore use start and stop only)" bash -c "! grep -n 'systemctl[^|]*restart' '$lib'/gamemode-lib.sh '$lib'/gamemode-start '$lib'/gamemode-end '$here/system_files/usr/share/ublue-os/just/60-custom.just' | grep scx"

# ---- the root-side helpers: instance validation, preflight, run, verify
export OCTARINE_SCX_REGISTRY="$root/reg" OCTARINE_SCX_SYSFS="$root/sys" OCTARINE_SCX_BTF="$root/btf" OCTARINE_SCX_STATE="$root/state" OCTARINE_SCX_KERNEL="6.99.0-test"
mkdir -p "$root/reg" "$root/sys/root" "$root/state" "$root/bin"
for n in rusty lavd; do printf 'NAME=scx_%s\nINSTANCE=%s\nBINARY=/usr/bin/scx_%s\nDESCRIPTION=%s test\nMIN_KERNEL=\nFLAGS=\n' $n $n $n $n >"$root/reg/$n.conf"; done
echo btf >"$root/btf"
# logger is a stub so nothing reaches the journal
printf '#!/bin/sh\necho "logger $*" >>"$LOGF"\n' >"$root/bin/logger"; chmod +x "$root/bin/logger"
export LOGF="$root/logf"; : >"$LOGF"
export PATH="$root/bin:$PATH"
pre() { bash "$lib/scx-preflight" "$@" >"$root/run" 2>&1; rc=$?; }
# validation of the instance name in all three helpers
for bad_name in "../x" "" "a b" "RUSTY" "rusty/../lavd" "rusty.conf" "ru*" 'rusty;touch x' "foo" "rusty
lavd"; do
    pre "$bad_name"; r1=$rc
    bash "$lib/scx-run" "$bad_name" >"$root/run" 2>&1; r2=$?
    bash "$lib/scx-verify" "$bad_name" >"$root/run" 2>&1; r3=$?
    rc="$r1 $r2 $r3"
    check "validation: instance name '$(printf '%s' "$bad_name" | tr '\n' '|')' is refused by preflight, run and verify (exit 2 each), nothing written" bash -c "[ '$r1' = 2 ] && [ '$r2' = 2 ] && [ '$r3' = 2 ] && [ -z \"\$(find '$root/state' -type f)\" ]"
done
pre rusty
check "preflight: a registered instance with BTF and no marker may start (exit 0)" test "$rc" = 0
mv "$root/btf" "$root/btf.off"; pre rusty; mv "$root/btf.off" "$root/btf"
check "preflight: no kernel BTF: refuses with exit 1 (the unit is skipped, not failed)" bash -c "[ $rc = 1 ] && grep -q 'BTF' '$root/run'"
mkdir -p "$root/state/scx-disabled"; echo "6.99.0-test" >"$root/state/scx-disabled/rusty"; pre rusty; r_cur=$rc; pre lavd; r_other=$rc
check "preflight: a marker holding the running kernel refuses that instance only" test "$r_cur" = 1 -a "$r_other" = 0
echo "6.1.0-older" >"$root/state/scx-disabled/rusty"; pre rusty
check "preflight: a marker for another kernel does not block (a new kernel is tried again)" test "$rc" = 0
rm -f "${root:?}/state/scx-disabled/rusty"
check "run: the binary comes only from the registry, under /usr/bin/scx_*, with a cleared environment" bash -c "grep -q -- '-i PATH=/usr/bin:/usr/sbin LANG=C' '$lib/scx-run' && grep -q 'bin/scx_' '$lib/scx-run'"
printf 'NAME=scx_evil\nINSTANCE=evil\nBINARY=/tmp/evil\nDESCRIPTION=x\nMIN_KERNEL=\nFLAGS=\n' >"$root/reg/evil.conf"
bash "$lib/scx-run" evil >"$root/run" 2>&1; rc=$?
check "run: a registry entry whose binary is not /usr/bin/scx_* is refused (exit 2)" bash -c "[ $rc = 2 ] && grep -q 'bad or missing binary' '$root/run'"
rm -f "${root:?}/reg/evil.conf"
check "no helper reads a user-writable file: no HOME, XDG, ~ or user config path in scx-lib, scx-preflight, scx-run, scx-verify" bash -c "! grep -E '\\\$HOME|XDG_|~/|/home/|scheduler.conf' '$lib/scx-lib.sh' '$lib/scx-preflight' '$lib/scx-run' '$lib/scx-verify'"
check "no sudo, pkexec or run0 in any helper, hook or the unit" bash -c "! grep -E '(sudo|pkexec|run0)' '$lib'/* '$u'"

# run: the kernel config for libbpf (private mount namespace) and which exits may restart
sb="$root/sb"; mkdir -p "$sb" "$root/bootdir" "$root/modules/6.99.0-test" "$root/runflags"
echo 'CONFIG_HZ=1000' >"$root/modules/6.99.0-test/config"
printf '#!/bin/sh\necho "unshare $*" | tr "\\n" " " >>%s/ulog; echo >>%s/ulog\n[ "$1" = -m ] && shift; [ "$1" = -- ] && shift\nexec "$@"\n' "$sb" "$sb" >"$sb/unshare"
printf '#!/bin/sh\necho "mount $*" >>%s/mlog\n[ -z "$STUB_MOUNT_FAIL" ] || exit 1\nexit 0\n' "$sb" >"$sb/mount"
printf '#!/bin/sh\necho "args:$*" >>%s/blog\nenv | grep -cE "^(OCTARINE|INVOCATION_ID|HOME|LOGF)" >>%s/blog\ncase "$(cat %s/mode)" in fail) exit 1 ;; crash) sleep 0.3; exit 3 ;; run) trap "exit 0" TERM; sleep 30 & wait ;; esac\nexit 0\n' "$sb" "$sb" "$sb" >"$sb/scx_rusty"
chmod +x "$sb/unshare" "$sb/mount" "$sb/scx_rusty"
printf 'NAME=scx_rusty\nINSTANCE=rusty\nBINARY=/usr/bin/scx_rusty\nDESCRIPTION=rusty test\nMIN_KERNEL=\nFLAGS=--alpha --beta=1\n' >"$root/reg/rusty.conf"
rrun() { : >"$sb/ulog"; : >"$sb/mlog"; : >"$sb/blog"; rm -rf "${root:?}/runflags/"*
    env OCTARINE_SCX_BIN_DIR="$sb" OCTARINE_SCX_UNSHARE="$sb/unshare" OCTARINE_SCX_MOUNT="$sb/mount" OCTARINE_SCX_BOOT="$root/bootdir" \
        OCTARINE_SCX_PROC_CONFIG="$root/no-proc-config.gz" OCTARINE_SCX_MODULES="$root/modules" OCTARINE_SCX_RUN="$root/runflags" "$@" \
        bash "$lib/scx-run" rusty >"$root/run" 2>&1; rc=$?; }
echo run >"$sb/mode"; echo fail >"$sb/mode"
rrun INVOCATION_ID=inv1
check "run: no config at libbpf's two places: the scheduler is started through unshare -m with tmpfs on /boot, the image's config bound read-only at /boot/config-<release>" bash -c "grep -q 'unshare -m -- ' '$sb/ulog' && grep -qF -- '-t tmpfs tmpfs $root/bootdir' '$sb/mlog' && grep -qF -- '--bind -o ro $root/modules/6.99.0-test/config $root/bootdir/config-6.99.0-test' '$sb/mlog' && grep -q 'libbpf' '$root/run'"
check "run: the registry flags reach the binary as separate arguments (positional parameters, never interpolated into the script) and the environment is cleared" bash -c "grep -q 'args:--alpha --beta=1' '$sb/blog' && [ \"\$(tail -n1 '$sb/blog')\" = 0 ]"
check "run: the real /boot is never named: only the configured boot directory is used" bash -c "! grep -q ' /boot' '$sb/mlog'"
rrun INVOCATION_ID=inv1
check "run: a scheduler that fails before it was verified active ends with 75 (no automatic restart), the log says so" bash -c "[ $rc = 75 ] && grep -q 'not restarted automatically (exit 75)' '$root/run'"
echo ok >"$root/bootdir/config-6.99.0-test"; rrun INVOCATION_ID=inv1
check "run: libbpf already finds /boot/config-<release>: no namespace, no mount" bash -c "[ ! -s '$sb/ulog' ] && [ ! -s '$sb/mlog' ] && grep -q 'args:--alpha --beta=1' '$sb/blog'"
rm -f "$root/bootdir/config-6.99.0-test"; : >"$root/proc-config.gz"; rrun INVOCATION_ID=inv1 OCTARINE_SCX_PROC_CONFIG="$root/proc-config.gz"
check "run: /proc/config.gz present: no namespace either" bash -c "[ ! -s '$sb/ulog' ]"
rm -f "$root/modules/6.99.0-test/config"; rrun INVOCATION_ID=inv1
check "run: the image's config file is missing: a warning, the scheduler still runs (no namespace)" bash -c "grep -q 'WARNING' '$root/run' && [ ! -s '$sb/ulog' ] && grep -q 'args:--alpha' '$sb/blog'"
echo 'CONFIG_HZ=1000' >"$root/modules/6.99.0-test/config"
echo ok >"$sb/mode"; rrun INVOCATION_ID=inv1 STUB_MOUNT_FAIL=1
check "run: a failing mount stops the start with a clear line, the scheduler is never started, exit 75" bash -c "[ $rc = 75 ] && grep -q 'could not prepare the kernel config for libbpf' '$root/run' && [ ! -s '$sb/blog' ]"
echo crash >"$sb/mode"; mkdir -p "$root/runflags"; : >"$root/runflags/active-inv2"
rrun2() { : >"$sb/blog"; env OCTARINE_SCX_BIN_DIR="$sb" OCTARINE_SCX_UNSHARE="$sb/unshare" OCTARINE_SCX_MOUNT="$sb/mount" OCTARINE_SCX_BOOT="$root/bootdir" OCTARINE_SCX_PROC_CONFIG="$root/no-proc-config.gz" OCTARINE_SCX_MODULES="$root/modules" OCTARINE_SCX_RUN="$root/runflags" "$@" bash "$lib/scx-run" rusty >"$root/run" 2>&1; rc=$?; }
rrun2 INVOCATION_ID=inv2
check "run: the scheduler WAS active (flag from scx-verify) and then crashed (status 3): the status is kept (Restart=on-failure applies) and the flag is removed" bash -c "[ $rc = 3 ] && [ ! -e '$root/runflags/active-inv2' ]"
echo run >"$sb/mode"; : >"$root/runflags/active-inv3"
env OCTARINE_SCX_BIN_DIR="$sb" OCTARINE_SCX_UNSHARE="$sb/unshare" OCTARINE_SCX_MOUNT="$sb/mount" OCTARINE_SCX_BOOT="$root/bootdir" OCTARINE_SCX_PROC_CONFIG="$root/no-proc-config.gz" OCTARINE_SCX_MODULES="$root/modules" OCTARINE_SCX_RUN="$root/runflags" INVOCATION_ID=inv3 setsid bash "$lib/scx-run" rusty >"$root/run" 2>&1 &
rp=$!; sleep 1; kill -TERM -- "-$rp" 2>/dev/null; wait "$rp"; rc=$?
check "run: a stop (SIGTERM) of an active scheduler is a clean end, exit 0" test "$rc" = 0
rm -f "$root/runflags/active-inv3"
env OCTARINE_SCX_BIN_DIR="$sb" OCTARINE_SCX_UNSHARE="$sb/unshare" OCTARINE_SCX_MOUNT="$sb/mount" OCTARINE_SCX_BOOT="$root/bootdir" OCTARINE_SCX_PROC_CONFIG="$root/no-proc-config.gz" OCTARINE_SCX_MODULES="$root/modules" OCTARINE_SCX_RUN="$root/runflags" INVOCATION_ID=inv4 setsid bash "$lib/scx-run" rusty >"$root/run" 2>&1 &
rp=$!; sleep 1; kill -TERM -- "-$rp" 2>/dev/null; wait "$rp"; rc=$?
check "run: systemd stopping a start that never became active (verify failed) ends with 75, not 0 and not a restartable status" test "$rc" = 75
check "unit: Restart=on-failure with RestartPreventExitStatus=75, the status scx-run uses for a start that never became active" bash -c "grep -qx 'Restart=on-failure' '$u' && grep -qx 'RestartPreventExitStatus=75' '$u' && grep -q 'exit 75' '$lib/scx-run'"
check "unit: no mount-namespace properties (they die with 226/NAMESPACE on the real machine); the namespace is scx-run's unshare" bash -c "! grep -E '^(TemporaryFileSystem|BindReadOnlyPaths|BindPaths)=' '$u' && grep -q 'unshare' '$lib/scx-run'"
check "run: only the scheduler runs in the namespace: scx-run uses absolute paths for unshare, mount, sh and env" bash -c "grep -q 'unshare=\${OCTARINE_SCX_UNSHARE:-/usr/bin/unshare}' '$lib/scx-run' && grep -q 'mount_bin=\${OCTARINE_SCX_MOUNT:-/usr/bin/mount}' '$lib/scx-run' && grep -q 'sh_bin=\${OCTARINE_SCX_SH:-/usr/bin/sh}' '$lib/scx-run'"
echo 'FLAGS=' >/dev/null
printf 'NAME=scx_rusty\nINSTANCE=rusty\nBINARY=/usr/bin/scx_rusty\nDESCRIPTION=rusty test\nMIN_KERNEL=\nFLAGS=\n' >"$root/reg/rusty.conf"

# verify: success, failures, threshold, reset, interrupts
export OCTARINE_SCX_VERIFY_SECONDS=1
ver() { bash "$lib/scx-verify" "$@" >"$root/run" 2>&1; rc=$?; }
set_active() { echo enabled >"$root/sys/state"; echo "${1}_1.1.4_x86_64_unknown_linux_gnu" >"$root/sys/root/ops"; }
set_inactive() { echo disabled >"$root/sys/state"; rm -f "${root:?}/sys/root/ops"; }
set_active rusty; ver rusty
check "verify: the instance is the active scheduler: exit 0" test "$rc" = 0
set_active lavd; ver rusty; r_wrong=$rc
check "verify: another scheduler holds sched_ext (ops lavd): the start fails (non-zero) but nothing is counted and no marker is written" bash -c "[ $r_wrong != 0 ] && grep -q 'busy' '$root/run' && [ -z \"\$(find '$root/state' -type f)\" ]"
for i in $(seq 1 12); do ver rusty; done
check "verify: twelve start attempts while another scheduler is active (the ignore-dependencies attack) count nothing and write no marker" bash -c "[ -z \"\$(find '$root/state' -type f)\" ]"
echo enabled >"$root/sys/state"; echo "some_foreign_sched" >"$root/sys/root/ops"; ver rusty
check "verify: a scheduler that is not one of ours holding sched_ext is busy too, not counted" bash -c "[ $rc != 0 ] && [ -z \"\$(find '$root/state' -type f)\" ]"
R=rusty_1.1.4_x86_64_unknown_linux_gnu; L=lavd_1.1.4_x86_64_unknown_linux_gnu
echo enabled >"$root/sys/state"; echo "$R" >"$root/sys/root/ops"; ver rusty; rc_r=$rc
check "verify: the kernel's REAL ops string ($R) is this instance: success, the raw string is in the log (observed on hardware 2026-11-14)" bash -c "[ $rc_r = 0 ] && grep -q \"active (kernel ops name '$R')\" '$root/run' && [ -z \"\$(find '$root/state' -type f)\" ]"
echo "$L" >"$root/sys/root/ops"; ver rusty
check "verify: the real string of ANOTHER registered instance ($L) is busy: non-zero, not counted, the log names the raw string and the instance" bash -c "[ $rc != 0 ] && grep -q \"held by '$L' (instance: 'lavd'\" '$root/run' && [ -z \"\$(find '$root/state' -type f)\" ]"
echo "rustyfoo_1.0_x86_64" >"$root/sys/root/ops"; ver rusty
check "verify: a name that merely STARTS with the instance but not followed by _ (rustyfoo) is not this instance: busy" bash -c "[ $rc != 0 ] && grep -q 'busy' '$root/run'"
echo "rusty" >"$root/sys/root/ops"; ver rusty
check "verify: the bare instance name still matches" test "$rc" = 0
echo "$R" >"$root/sys/root/ops"; echo disabled >"$root/sys/state"; ver rusty
check "verify: a leftover ops file while sched_ext is disabled is a real failure, counted" bash -c "[ $rc != 0 ] && [ \"\$(cat '$root/state/scx-failures/rusty')\" = 1 ]"
rm -rf "${root:?}/state/scx-failures" "${root:?}/state/scx-disabled"
set_inactive; ver rusty; set_active lavd; ver rusty; set_active lavd; ver rusty; set_inactive; ver rusty
check "verify: mixed sequence (real failure, busy, busy, real failure) counts exactly the two real failures" bash -c "[ \"\$(cat '$root/state/scx-failures/rusty')\" = 2 ] && [ ! -e '$root/state/scx-disabled/rusty' ]"
rm -rf "${root:?}/state/scx-failures" "${root:?}/state/scx-disabled"
set_inactive; ver rusty; ver rusty
check "verify: two consecutive failures: count 2, still no marker" bash -c "[ \"\$(cat '$root/state/scx-failures/rusty')\" = 2 ] && [ ! -e '$root/state/scx-disabled/rusty' ]"
ver rusty
check "verify: the third consecutive real failure (sched_ext not enabled) writes the marker with the running kernel" bash -c "[ \"\$(cat '$root/state/scx-disabled/rusty')\" = 6.99.0-test ] && grep -q 'disabled for kernel 6.99.0-test' '$root/run'"
pre rusty
check "verify and preflight together: after the marker the instance is refused on this kernel" test "$rc" = 1
check "verify: the other instance is not affected by the marker" bash -c "[ ! -e '$root/state/scx-disabled/lavd' ]"
set_active rusty; INVOCATION_ID=invX OCTARINE_SCX_RUN="$root/runflags" ver rusty
check "verify: a success leaves the active flag for this invocation (scx-run then treats a later exit as a crash or stop)" test -e "$root/runflags/active-invX"
rm -f "$root/runflags/active-invX"; set_inactive; INVOCATION_ID=invY OCTARINE_SCX_RUN="$root/runflags" ver rusty
check "verify: a failure leaves no active flag" bash -c "[ ! -e '$root/runflags/active-invY' ]"
rm -rf "${root:?}/state/scx-failures" "${root:?}/state/scx-disabled"
check "restart semantics: ONE failed start is ONE counted failure (scx-run exits 75, the unit does not restart it), so the threshold of three means three separate attempts" bash -c "grep -qx 'RestartPreventExitStatus=75' '$u'"
set_active rusty; ver rusty
check "verify: a success removes the failure count and the marker" bash -c "[ $rc = 0 ] && [ ! -e '$root/state/scx-failures/rusty' ] && [ ! -e '$root/state/scx-disabled/rusty' ]"
rm -rf "${root:?}/state/scx-failures" "${root:?}/state/scx-disabled"
set_inactive; ver lavd; ver lavd; set_active lavd; ver lavd; set_inactive; ver lavd; ver lavd
check "verify: failures must be consecutive: a success in between resets the count (no marker after 2+2)" bash -c "[ ! -e '$root/state/scx-disabled/lavd' ] && [ \"\$(cat '$root/state/scx-failures/lavd')\" = 2 ]"
rm -rf "${root:?}/state/scx-failures" "${root:?}/state/scx-disabled"
set_active rusty
for i in $(seq 1 12); do ver rusty; done
check "verify: rapid start/stop cycles (twelve successful verifications) write no marker and no failure count" bash -c "[ -z \"\$(find '$root/state' -type f)\" ]"
set_inactive
export OCTARINE_SCX_VERIFY_SECONDS=30
bash "$lib/scx-verify" rusty >"$root/run" 2>&1 &
vp=$!
sleep 1
kill -TERM "$vp"; wait "$vp"; rc=$?
export OCTARINE_SCX_VERIFY_SECONDS=1
check "verify: a stop during the wait (SIGTERM) is not a failure: exit 143, nothing counted, nothing written" bash -c "[ $rc = 143 ] && [ -z \"\$(find '$root/state' -type f)\" ] && grep -q 'not counted' '$LOGF'"
check "verify: the threshold defaults to three failures" bash -c "grep -q 'SCX_MAX_FAILURES=\\\${OCTARINE_SCX_MAX_FAILURES:-3}' '$lib/scx-lib.sh'"

# ---- the GameMode hooks (stub systemctl, tuned-adm, notify-send)
hb="$root/hbin"; mkdir -p "$hb"
cat >"$hb/systemctl" <<'F'
#!/usr/bin/env bash
echo "systemctl $*" >>"$HLOG"
case "$1" in
    is-enabled) for e in $ENABLED; do [ "$2" = "scx@$e.service" ] && { echo enabled; exit 0; }; done; echo disabled; exit 1 ;;
    start) i=${2#scx@}; i=${i%.service}
        [ "${SYSTEMCTL_FAIL:-}" = all ] && exit 1
        for f in $FAIL_START; do [ "$f" = "$i" ] && exit 1; done
        echo enabled >"$OCTARINE_SCX_SYSFS/state"; mkdir -p "$OCTARINE_SCX_SYSFS/root"; echo "${i}_1.1.4_x86_64_unknown_linux_gnu" >"$OCTARINE_SCX_SYSFS/root/ops" ;;
    stop) [ "${SYSTEMCTL_FAIL:-}" = all ] && exit 1
        echo disabled >"$OCTARINE_SCX_SYSFS/state"; rm -f "$OCTARINE_SCX_SYSFS/root/ops" ;;
esac
exit 0
F
printf '#!/bin/sh\necho "tuned-adm $*" >>"$HLOG"\n' >"$hb/tuned-adm"
printf '#!/bin/sh\necho "notify-send $*" >>"$HLOG"\n' >"$hb/notify-send"
printf '#!/bin/sh\necho "logger $*" >>"$HLOG"\n' >"$hb/logger"
chmod +x "$hb"/*
export HLOG="$root/hlog" OCTARINE_SCX_RUN_DIR="$root/gmrun" OCTARINE_SCX_USER_CONF="$root/user.conf" OCTARINE_SCX_ACTIVE_WAIT=1 OCTARINE_SCX_SYSTEMCTL_TIMEOUT=5
unset OCTARINE_SCX_STATE
hreset() { : >"$HLOG"; rm -rf "${root:?}/gmrun" "${root:?}/user.conf"; set_inactive; unset FAIL_START SYSTEMCTL_FAIL; export ENABLED=""; }
hook() { PATH="$hb:/usr/bin:/bin" bash "$lib/gamemode-$1" >"$root/run" 2>&1; rc=$?; }
ops_now() { sed 's/_1\.1\.4_x86_64_unknown_linux_gnu$//' "$root/sys/root/ops" 2>/dev/null; }

hreset; hook start; r1=$rc; hook end; r2=$rc
check "hooks: no choice file means skip: tuned as before, no systemctl start or stop, both exit 0" bash -c "[ $r1 = 0 ] && [ $r2 = 0 ] && grep -q 'tuned-adm profile latency-performance' '$HLOG' && grep -q 'tuned-adm profile balanced' '$HLOG' && ! grep -qE 'systemctl (start|stop)' '$HLOG'"
hreset; echo 'GAMEMODE_SCHED=skip' >"$root/user.conf"; hook start
check "hooks: skip does nothing to schedulers" bash -c "! grep -qE 'systemctl (start|stop)' '$HLOG'"
hreset; echo 'GAMEMODE_SCHED=lavd' >"$root/user.conf"; hook start; r1=$rc; o1=$(ops_now); hook end; r2=$rc; o2=$(ops_now)
check "hooks: a name with no boot scheduler: start switches to it (verified), end returns to the kernel default; exit 0 both" bash -c "[ $r1 = 0 ] && [ $r2 = 0 ] && [ '$o1' = lavd ] && [ -z '$o2' ] && grep -q 'systemctl start scx@lavd.service' '$HLOG' && grep -q 'systemctl stop scx@lavd.service' '$HLOG'"
hreset; ENABLED=rusty; set_active rusty; echo 'GAMEMODE_SCHED=lavd' >"$root/user.conf"; hook start; o1=$(ops_now); hook end; o2=$(ops_now)
check "hooks: a name with a boot scheduler: start switches to it, end restores the boot scheduler (the instance systemctl reports enabled)" bash -c "[ '$o1' = lavd ] && [ '$o2' = rusty ]"
hreset; ENABLED=rusty; set_active rusty; echo 'GAMEMODE_SCHED=none' >"$root/user.conf"; hook start; o1=$(ops_now); hook end; o2=$(ops_now)
check "hooks: none stops the boot scheduler for the game and end brings it back" bash -c "[ -z '$o1' ] && [ '$o2' = rusty ] && grep -q 'systemctl stop scx@rusty.service' '$HLOG'"
hreset; echo 'GAMEMODE_SCHED=none' >"$root/user.conf"; hook start; hook end
check "hooks: none with no scheduler active changes nothing" bash -c "! grep -qE 'systemctl (start|stop)' '$HLOG'"
hreset; ENABLED=rusty; set_active rusty; echo 'GAMEMODE_SCHED=lavd' >"$root/user.conf"; FAIL_START=lavd hook start; r1=$rc; o1=$(ops_now)
check "hooks: the chosen scheduler fails to start: the boot choice stays or is restored, a notification is sent, exit 0, nothing marked as switched" bash -c "[ $r1 = 0 ] && [ '$o1' = rusty ] && grep -q 'notify-send' '$HLOG' && grep -q 'logger -t octarine-scx' '$HLOG' && [ ! -e '$root/gmrun/switched' ]"
hreset; ENABLED=rusty; set_active rusty; echo 'GAMEMODE_SCHED=lavd' >"$root/user.conf"; mkdir -p "$root/state/scx-disabled"; echo 6.99.0-test >"$root/state/scx-disabled/lavd"; FAIL_START=lavd OCTARINE_SCX_STATE="$root/state" hook start
check "hooks: a start that fails with a disabled marker for this kernel says so and names the marker, the counter and the journal command" bash -c "grep -q 'disabled for this kernel after repeated load failures' '$root/run' && grep -qF 'rm -- $root/state/scx-disabled/lavd $root/state/scx-failures/lavd' '$root/run' && grep -q 'journalctl -u scx@lavd' '$root/run'"
rm -f "${root:?}/state/scx-disabled/lavd"
hreset; ENABLED=rusty; set_active rusty; echo 'GAMEMODE_SCHED=lavd' >"$root/user.conf"; FAIL_START=lavd hook start
check "hooks: a start that fails without a marker points at the journal" bash -c "grep -q 'did not start' '$root/run' && grep -q 'journalctl -u scx@lavd' '$root/run'"
unset FAIL_START
hreset; ENABLED=rusty; set_active rusty; echo 'GAMEMODE_SCHED=lavd' >"$root/user.conf"
PATH="$hb:/usr/bin:/bin" bash "$lib/gamemode-start" >/dev/null 2>&1 &
PATH="$hb:/usr/bin:/bin" bash "$lib/gamemode-start" >/dev/null 2>&1
wait
PATH="$hb:/usr/bin:/bin" bash "$lib/gamemode-end" >/dev/null 2>&1 &
PATH="$hb:/usr/bin:/bin" bash "$lib/gamemode-end" >/dev/null 2>&1
wait
check "hooks: two games overlapping (two starts, two ends at once): lavd is started once, the boot scheduler is restored once, the second end finds nothing to restore" bash -c "[ \$(grep -c 'systemctl start scx@lavd.service' '$HLOG') = 1 ] && [ \$(grep -c 'systemctl start scx@rusty.service' '$HLOG') = 1 ] && [ \"\$(cat '$root/sys/root/ops')\" = rusty_1.1.4_x86_64_unknown_linux_gnu ]"
# a stale game-time scheduler from a crashed session (gamemoded died, end never ran) is repaired by the next start
printf 'NAME=scx_cake\nINSTANCE=cake\nBINARY=/usr/bin/scx_cake\nDESCRIPTION=cake test\nMIN_KERNEL=\nFLAGS=\n' >"$root/reg/cake.conf"
hreset; ENABLED=rusty; set_active cake; echo 'GAMEMODE_SCHED=lavd' >"$root/user.conf"; hook start; o1=$(ops_now)
check "hooks: a stale scheduler (cake, neither the boot choice rusty nor the requested lavd) is first replaced by the boot choice, then the requested one is switched in" bash -c "[ '$o1' = lavd ] && [ \$(grep -n 'systemctl start scx@rusty.service' '$HLOG' | head -1 | cut -d: -f1) -lt \$(grep -n 'systemctl start scx@lavd.service' '$HLOG' | head -1 | cut -d: -f1) ] && grep -q 'stale scheduler cake' '$HLOG'"
hook end; o2=$(ops_now)
check "hooks: after that start, end restores the boot choice again" test "$o2" = rusty
hreset; ENABLED=""; set_active cake; echo 'GAMEMODE_SCHED=lavd' >"$root/user.conf"; hook start; o1=$(ops_now)
check "hooks: a stale scheduler and NO boot instance: it is stopped, the requested one switched in" bash -c "[ '$o1' = lavd ] && grep -q 'systemctl stop scx@cake.service' '$HLOG'"
hreset; ENABLED=rusty; set_active rusty; echo 'GAMEMODE_SCHED=lavd' >"$root/user.conf"; hook start
check "hooks: states that already match (boot scheduler running, game choice requested): no restore, one switch only" bash -c "[ \$(grep -c 'systemctl start scx@rusty.service' '$HLOG') = 0 ] && [ \$(grep -c 'systemctl start scx@lavd.service' '$HLOG') = 1 ] && ! grep -q 'stale scheduler' '$HLOG'"
hreset; ENABLED=rusty; set_active lavd; echo 'GAMEMODE_SCHED=lavd' >"$root/user.conf"; hook start; hook end; o2=$(ops_now)
check "hooks: a game scheduler already active but not the boot choice (crashed session, marker lost): start takes over the restore duty, end restores the boot choice" test "$o2" = rusty
hreset; ENABLED=rusty; set_active cake; echo 'GAMEMODE_SCHED=skip' >"$root/user.conf"; hook start
check "hooks: skip never touches a running scheduler, stale or not" bash -c "! grep -qE 'systemctl (start|stop)' '$HLOG'"
hreset; echo 'GAMEMODE_SCHED=../../etc/passwd' >"$root/user.conf"; hook start; r1=$rc
check "hooks: an unregistered or hostile GAMEMODE_SCHED is ignored (treated as skip), no systemctl call, exit 0" bash -c "[ $r1 = 0 ] && ! grep -qE 'systemctl (start|stop)' '$HLOG' && grep -q 'ignoring GAMEMODE_SCHED' '$HLOG'"
hreset; echo 'GAMEMODE_SCHED=lavd' >"$root/user.conf"; SYSTEMCTL_FAIL=all hook start; r1=$rc; SYSTEMCTL_FAIL=all hook end; r2=$rc
check "hooks: systemctl failing everywhere still exits 0 for start and end" test "$r1" = 0 -a "$r2" = 0
hreset; echo 'GAMEMODE_SCHED=lavd' >"$root/user.conf"; mv "$hb/tuned-adm" "$hb/tuned-adm.off"; hook start; r1=$rc; mv "$hb/tuned-adm.off" "$hb/tuned-adm"
check "hooks: without tuned-adm the scheduler switch still happens and the hook exits 0" bash -c "[ $r1 = 0 ] && grep -q 'systemctl start scx@lavd.service' '$HLOG'"
start_t=$(date +%s); hreset; echo 'GAMEMODE_SCHED=lavd' >"$root/user.conf"; hook start; el=$(( $(date +%s) - start_t ))
check "hooks: a normal start finishes in a couple of seconds, far below the 20 s script_timeout" test "$el" -lt 5
check "hooks: only the hook library reads scheduler.conf; the root helpers and the unit never mention it" bash -c "grep -q 'scheduler.conf' '$lib/gamemode-lib.sh' && ! grep -rq 'scheduler.conf' '$lib/scx-lib.sh' '$lib/scx-preflight' '$lib/scx-run' '$lib/scx-verify' '$u'"
gm="$here/system_files/usr/share/octarine-os/gamemode.ini"
check "gamemode.ini ships the hooks as start= and end= and a script_timeout above the default" bash -c "grep -qx 'start=/usr/libexec/octarine-os/gamemode-start' '$gm' && grep -qx 'end=/usr/libexec/octarine-os/gamemode-end' '$gm' && grep -qx 'script_timeout=20' '$gm' && ! grep -q '^start=tuned-adm' '$gm'"
check "every shipped script under libexec parses and is executable" bash -c "for f in '$lib'/scx-preflight '$lib'/scx-run '$lib'/scx-verify '$lib'/gamemode-start '$lib'/gamemode-end; do bash -n \"\$f\" && [ -x \"\$f\" ] || exit 1; done; for f in '$lib'/*-lib.sh '$here'/build_files/gen-schedulers.sh; do bash -n \"\$f\" || exit 1; done"

echo
echo "passed: $pass, failed: $failn"
[ "$failn" = 0 ]
