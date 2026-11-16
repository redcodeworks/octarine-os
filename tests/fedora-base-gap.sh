#!/usr/bin/env bash
# Tests the Fedora base gap analysis (.github/workflows/build-fedora-base.yml and .github/scripts/gap-{collect,report,issue}.sh): the workflow's
# guarantees (never publishes or signs, minimum permissions, dispatch and monthly schedule, a failed build is recorded and not raised) and the report
# assembly with fixture facts. Run: tests/fedora-base-gap.sh
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
wf="$here/.github/workflows/build-fedora-base.yml"
root=$(mktemp -d)
trap 'rm -rf -- "$root"' EXIT
pass=0; failn=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { failn=$((failn + 1)); echo "FAIL $1"; [ -f "$root/out" ] && sed 's/^/     /' "$root/out"; }
check() { local d=$1; shift; if "$@" > "$root/out" 2>&1; then ok "$d"; else bad "$d"; fi; }

check "workflow: bash syntax of every run block" python3 - "$wf" <<'PY'
import subprocess, sys, yaml
w = yaml.safe_load(open(sys.argv[1]))
for name, job in w["jobs"].items():
    for s in job.get("steps", []):
        if "run" in s:
            r = subprocess.run(["bash", "-n"], input=s["run"], text=True, capture_output=True)
            assert r.returncode == 0, (name, s.get("name"), r.stderr)
PY
check "workflow: monthly schedule plus manual dispatch only (never push or pull request), with the two inputs" python3 - "$wf" <<'PY'
import sys, yaml
w = yaml.safe_load(open(sys.argv[1])); on = w.get(True) or w.get("on")
assert set(on) == {"schedule", "workflow_dispatch"}, set(on)
c = on["schedule"][0]["cron"].split()
assert c[2] != "*" and c[3:] == ["*", "*"], c  # one day of the month
assert set(on["workflow_dispatch"]["inputs"]) == {"fedora_version", "base_image"}
PY
check "workflow: nothing is pushed, tagged, copied or signed (comments aside), packages: write only on the binaries job, the signing secret only handed to it" bash -c "
  code=\$(sed 's/#.*//' '$wf') &&
  ! grep -qE 'podman push|skopeo copy|push-tags|cosign sign |docker/build-push' <<<\"\$code\" &&
  [ \$(grep -c 'packages: write' <<<\"\$code\") = 1 ] && [ \$(grep -c SIGNING_SECRET <<<\"\$code\") = 1 ]"
check "workflow: the gap job has minimum permissions (contents and packages read, issues write) and every action is pinned to a commit" python3 - "$wf" <<'PY'
import re, sys, yaml
w = yaml.safe_load(open(sys.argv[1]))
assert w["permissions"] == {"contents": "read"}
assert w["jobs"]["gap"]["permissions"] == {"contents": "read", "packages": "read", "issues": "write"}, w["jobs"]["gap"]["permissions"]
for j in w["jobs"].values():
    for s in j.get("steps", []):
        u = s.get("uses", "")
        if u and not u.startswith("./"):
            assert re.search(r"@[0-9a-f]{40}", u), u
PY
check "workflow: the build step records the outcome and always exits 0; the report step runs after it; the issue step comes last" python3 - "$wf" <<'PY'
import sys, yaml
w = yaml.safe_load(open(sys.argv[1]))
steps = w["jobs"]["gap"]["steps"]
names = [s.get("name", "") for s in steps]
b = next(s for s in steps if s.get("id") == "build")
assert "set +e" in b["run"] and b["run"].rstrip().endswith("exit 0") and "outcome=" in b["run"]
assert "if" not in b
i = names.index(b["name"])
assert names.index("Write the report") > i and names[-1].startswith("Open the issue")
assert "gap-issue.sh" in steps[-1]["run"] and "gap-report.sh" in next(s for s in steps if s.get("id") == "report")["run"]
PY
check "workflow: inputs reach the shell through env only, never inside a run block" python3 - "$wf" <<'PY'
import sys, yaml
w = yaml.safe_load(open(sys.argv[1]))
for j in w["jobs"].values():
    for s in j.get("steps", []):
        assert "${{" not in s.get("run", ""), s.get("name")
PY

mk() { # dir pkg...
    local d=$1; shift; mkdir -p "$d"; local c
    for c in packages repos units-system units-user ublue-paths dconf flatpak; do : > "$d/$c.txt"; done
    printf '%s\n' "$@" | sort > "$d/packages.txt"
}
mk "$root/ublue" bash ublue-os-just ublue-os-update-services fish
mk "$root/official" bash fish
mk "$root/reference" bash ublue-os-just fish extra
mk "$root/built" bash fish extra
echo "/usr/share/ublue-os/just/00-default.just" > "$root/ublue/ublue-paths.txt"
cat > "$root/log" <<'L'
STEP 3/20: RUN ls
STEP 7/20: RUN /ctx/build.sh
+ dnf5 install -y ublue-os-just
Error: Unable to find a match: ublue-os-just
Error: building at STEP "RUN /ctx/build.sh": exit status 1
L
r="$root/rep1"
check "report, build failed: exits 0, names the first error and the STEP it happened in, compares the two bases" bash -c "
  bash '$here/.github/scripts/gap-report.sh' --out '$r' --ublue '$root/ublue' --official '$root/official' --reference '$root/reference' --outcome failed --log '$root/log' --meta 'Official base=x' &&
  grep -q 'failed' '$r/report.md' && grep -qF 'Error: Unable to find a match: ublue-os-just' '$r/report.md' && grep -qF 'STEP 7/20: RUN /ctx/build.sh' '$r/report.md' &&
  grep -qx -- '- ublue-os-just' '$r/diffs/ublue-to-official-packages.diff' && grep -qx -- '- /usr/share/ublue-os/just/00-default.just' '$r/diffs/ublue-to-official-ublue-paths.diff' &&
  ! ls '$r/diffs' | grep -q reference-to-built && grep -q 'Official base: x' '$r/report.md'"
# a build.sh log as the real first run printed it: set -x everywhere, the EXIT trap definition (which contains the words error and failed), then the failing step
cat > "$root/log2" <<'L'
[4/4] STEP 6/8: RUN --mount=type=bind,from=ctx,source=/,target=/ctx /ctx/build.sh
+ trap 'rc=$?; if (( rc != 0 )); then echo "::endgroup::"; echo "::error::build.sh failed (exit ${rc})"; fi' EXIT
::group::Base image
+ echo '::group::Base image'
NAME="Fedora Linux"
::endgroup::
+ echo ::endgroup::
::group::System files
+ echo '::group::System files'
+ for f in 00-default 10-update 30-distrobox
+ mv /usr/share/ublue-os/just/00-default.just /usr/share/ublue-os/just/00-default-base.just
mv: cannot stat '/usr/share/ublue-os/just/00-default.just': No such file or directory
+ rc=1
+ echo '::error::build.sh failed (exit 1)'
::endgroup::
::error::build.sh failed (exit 1)
Error: building at STEP "RUN ... /ctx/build.sh": while running runtime: exit status 1
error: recipe `build` failed with exit code 1
L
r="$root/rep1b"
check "report, xtrace-heavy build.sh log: the first error line is the real failure (not the trap definition or the wrapper's last line) and the build.sh step is named" bash -c "
  bash '$here/.github/scripts/gap-report.sh' --out '$r' --ublue '$root/ublue' --official '$root/official' --reference '$root/reference' --outcome failed --log '$root/log2' &&
  grep -qF 'First error line: \`mv: cannot stat' '$r/report.md' && ! grep -F 'First error line' '$r/report.md' | grep -q 'trap' &&
  grep -qF 'build.sh step it happened in: \`System files' '$r/report.md' && grep -qF 'STEP 6/8' '$r/report.md'"
r="$root/rep2"
check "report, build succeeded: adds the comparison of the result with the published default image (what the result lacks and has extra)" bash -c "
  bash '$here/.github/scripts/gap-report.sh' --out '$r' --ublue '$root/ublue' --official '$root/official' --reference '$root/reference' --built '$root/built' --outcome built &&
  grep -q 'builds on the official base' '$r/report.md' && grep -qx -- '- ublue-os-just' '$r/diffs/reference-to-built-packages.diff' && ! grep -q 'extra' '$r/diffs/reference-to-built-packages.diff'"
r="$root/rep3"; seq 1 300 | sed 's/^/pkg/' > "$root/many.txt"
mk "$root/ublue2" bash; sort "$root/many.txt" > "$root/ublue2/packages.txt"
check "report: the issue body shows at most GAP_LINES lines per diff and stays far below the 65536 character limit; the complete diff is kept" bash -c "
  GAP_LINES=50 bash '$here/.github/scripts/gap-report.sh' --out '$r' --ublue '$root/ublue2' --official '$root/official' --reference '$root/reference' --outcome failed &&
  [ \$(wc -l < '$r/diffs/ublue-to-official-packages.diff') -ge 300 ] && [ \$(grep -c '^- pkg' '$r/report.md') = 50 ] && [ \$(wc -c < '$r/report.md') -lt 20000 ]"
check "report: a missing argument or a bad outcome is a usage error (exit 2), not a silent report" bash -c "
  bash '$here/.github/scripts/gap-report.sh' --out '$root/x' --outcome built; [ \$? = 2 ] && bash '$here/.github/scripts/gap-report.sh' --out '$root/x' --ublue '$root/ublue' --official '$root/official' --reference '$root/reference' --outcome weird; [ \$? = 2 ]"

check "collect: writes the seven sorted fact files for the machine it runs on and exits 0" bash -c "
  bash '$here/.github/scripts/gap-collect.sh' '$root/facts' &&
  for c in packages repos units-system units-user ublue-paths dconf flatpak; do test -f '$root/facts/'\$c.txt || exit 1; done &&
  sort -c '$root/facts/packages.txt'"

mkdir -p "$root/bin"
cat > "$root/bin/gh" <<'S'
#!/usr/bin/env bash
echo "gh $*" >> "$GH_LOG"
case "$1 $2" in
    "issue list") printf '4\n7\n' ;;
    "issue create") echo "https://github.com/o/r/issues/9" ;;
esac
S
chmod +x "$root/bin/gh"
printf 'body\n' > "$root/body.md"
check "issue: creates the label, opens ONE issue labelled gap-fedora-base, and closes the older open ones with a pointer" bash -c "
  GH_LOG='$root/ghlog' PATH='$root/bin:'\$PATH GITHUB_REPOSITORY=o/r bash '$here/.github/scripts/gap-issue.sh' 'Title' '$root/body.md' &&
  grep -q 'label create gap-fedora-base' '$root/ghlog' && [ \$(grep -c 'issue create' '$root/ghlog') = 1 ] && grep -q 'issue create.*--label gap-fedora-base' '$root/ghlog' &&
  grep -q 'issue comment 4.*Superseded by https://github.com/o/r/issues/9' '$root/ghlog' && grep -q 'issue close 7' '$root/ghlog' && ! grep -q 'issue close 9' '$root/ghlog'"

echo
echo "${pass} passed, ${failn} failed"
[ "$failn" -eq 0 ]
