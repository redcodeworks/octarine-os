#!/usr/bin/env bash
# Static shape of the "promote the default and dx images together" design: no job of a main build, promotion or dx run writes the bare `latest`
# tag of octarine-os or octarine-os-dx any more; publish-latest.yml is the one place, reusable and dispatchable, without the signing
# environment; dx on main is grouped per commit; the dx run calls it as its last job; failures open one issue. Run: tests/publish-latest-workflow.sh
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fail=0
check() { local d=$1; shift; if "$@" > "$(mktemp)" 2>&1; then echo "ok   $d"; else echo "FAIL $d"; "$@" 2>&1 | sed 's/^/     /' | tail -5; fail=1; fi; }
wf="$here/.github/workflows"

check "just generate-build-tags: with bare=false the bare latest is not in the list, the dated ones and the same-day aliases are; testing and the default call keep their bare tag" bash -c "
    cd '$here'
    nolatest=\$(just generate-build-tags x latest false 2>/dev/null | tail -n1)
    withlatest=\$(just generate-build-tags x latest 2>/dev/null | tail -n1)
    testing=\$(just generate-build-tags x testing false 2>/dev/null | tail -n1)
    tok() { tr ' ' '\\n' <<< \"\$1\"; }
    ! tok \"\$nolatest\" | grep -qx latest && tok \"\$nolatest\" | grep -qE '^latest-[0-9]{8}\$' && tok \"\$nolatest\" | grep -qE '^[0-9]{8}\$' &&
    tok \"\$withlatest\" | grep -qx latest && tok \"\$testing\" | grep -qx testing"
check "build.yml: the main build and the promotion ask for the tag list without the bare latest; nothing in the file pushes or copies to :latest" python3 - "$wf/build.yml" <<'PY'
import sys, re, yaml
t = open(sys.argv[1]).read()
w = yaml.safe_load(t)
gen = [s for j in ("build_push", "promote") for s in w["jobs"][j]["steps"] if "generate-build-tags" in str(s.get("run", ""))]
assert len(gen) == 2
for s in gen:
    assert re.search(r"generate-build-tags[^\n]*(\\\n[^\n]*)*\bfalse\)", s["run"]), s["run"]
PY
check "build.yml: dispatch_dx hands the published or promoted digest to dx on main (and nothing on testing)" python3 - "$wf/build.yml" <<'PY'
import sys, yaml
w = yaml.safe_load(open(sys.argv[1]))
j = w["jobs"]["dispatch_dx"]
assert j["needs"] == ["build_result", "build_push", "promote"], j["needs"]
step = next(s for s in j["steps"] if "Dispatch" in s["name"])
assert "needs.build_push.outputs.digests || needs.promote.outputs.digests" in step["env"]["BASE_DIGEST"]
assert "github.ref == 'refs/heads/main'" in step["env"]["BASE_DIGEST"]
assert '"${BASE_DIGEST}"' in step["run"]
PY
check "build-dx.yml: channel latest is grouped per commit (testing and beta per channel), never cancelling; the pin reaches the plan" python3 - "$wf/build-dx.yml" <<'PY'
import sys, yaml
w = yaml.safe_load(open(sys.argv[1]))
g = w["concurrency"]["group"]
assert "format('latest-{0}', substring(inputs.sha || github.sha, 0, 7))" in g and "inputs.channel" in g, g
assert w["concurrency"]["cancel-in-progress"] is False
plan = next(s for s in w["jobs"]["plan"]["steps"] if s.get("id") == "plan")
assert plan["env"]["BASE_DIGEST_PIN"] == "${{ inputs.channel == 'latest' && inputs.base_digest || '' }}"
PY
check "build-dx.yml: the latest channel pushes and promotes dated tags only; beta keeps its bare tag; no step copies to :latest" python3 - "$wf/build-dx.yml" <<'PY'
import sys, re, yaml
w = yaml.safe_load(open(sys.argv[1]))
tags = next(s for s in w["jobs"]["build"]["steps"] if s.get("id") == "tags")["run"]
assert 'alias_tags="latest-$(date +%Y%m%d)-${sha}"' in tags and 'alias_tags="${CHANNEL}-$(date +%Y%m%d)-${sha} ${CHANNEL}"' in tags
prom = next(s for s in w["jobs"]["promote"]["steps"] if s.get("id") == "tags")["run"]
assert 'alias_tags="latest-$(date +%Y%m%d)-$(git rev-parse --short=7 HEAD)"' in prom and " latest\"" not in prom
PY
check "build-dx.yml: the last job publishes: it calls publish-latest.yml on main for channel latest after a green result, never in a dry run, and has the permissions the called jobs need" python3 - "$wf/build-dx.yml" <<'PY'
import sys, yaml
w = yaml.safe_load(open(sys.argv[1]))
j = w["jobs"]["publish"]
assert j["uses"] == "./.github/workflows/publish-latest.yml"
c = " ".join(j["if"].split())
for part in ("github.ref == 'refs/heads/main'", "inputs.channel == 'latest'", "!inputs.dry_run", "needs.plan.result == 'success'", "needs.dx_result.result == 'success'"):
    assert part in c, part
assert j["needs"] == ["plan", "build", "promote", "sign", "dx_result"]
assert j["permissions"] == {"contents": "read", "packages": "write", "issues": "write"}
assert j["with"]["vanilla_digest"] == "${{ needs.plan.outputs.base_digest }}"
assert j["with"]["dx_digest"] == "${{ needs.build.outputs.digests || needs.promote.outputs.digests }}"
PY
check "publish-latest.yml: workflow_call and workflow_dispatch (scope both|vanilla-only, vanilla_tag, reason, dry_run), no environment, writes packages only in the publish job, never cancels, writes only on main" python3 - "$wf/publish-latest.yml" <<'PY'
import sys, yaml
w = yaml.safe_load(open(sys.argv[1]))
on = w.get(True) or w.get("on")
assert set(on) == {"workflow_call", "workflow_dispatch"}, set(on)
d = on["workflow_dispatch"]["inputs"]
assert set(d) == {"scope", "vanilla_tag", "reason", "dry_run"} and d["scope"]["options"] == ["both", "vanilla-only"] and d["scope"]["default"] == "both"
assert set(on["workflow_call"]["inputs"]) == {"vanilla_digest", "dx_digest", "main_sha", "dry_run"}
assert w["permissions"] == {"contents": "read"}
pub = w["jobs"]["publish"]
assert "environment" not in pub and all("environment" not in j for j in w["jobs"].values()), "no signing environment"
assert pub["concurrency"] == {"group": "publish-latest", "cancel-in-progress": False}
assert pub["permissions"] == {"contents": "read", "packages": "write"}
env = next(s for s in pub["steps"] if s.get("id") == "publish")["env"]
assert env["WRITE"] == "${{ github.ref == 'refs/heads/main' && 'true' || 'false' }}"
assert all("github.event_name" not in str(v) for v in env.values()), "the event name is the caller's in a called workflow"
assert next(s for s in pub["steps"] if s.get("id") == "publish")["run"] == ".github/scripts/publish-latest.sh"
assert w["jobs"]["recover"]["permissions"] == {"contents": "read", "issues": "write"}
assert "needs.publish.outputs.moved == 'true'" in w["jobs"]["recover"]["if"]
assert "needs.publish.result == 'failure'" in w["jobs"]["alert"]["if"]
PY
check "build-dx.yml: the alert job runs only for latest on main after a failure, with issues: write and nothing else" python3 - "$wf/build-dx.yml" <<'PY'
import sys, yaml
w = yaml.safe_load(open(sys.argv[1]))
j = w["jobs"]["alert"]
c = " ".join(j["if"].split())
for part in ("always()", "github.ref == 'refs/heads/main'", "inputs.channel == 'latest'", "!inputs.dry_run", "contains(needs.*.result, 'failure')"):
    assert part in c, part
assert j["permissions"] == {"contents": "read", "issues": "write"}
assert any(s.get("run") == ".github/scripts/ci-issue.sh fail" for s in j["steps"])
PY
check "no workflow other than publish-latest.yml writes a bare :latest tag of the default or the dx image (skopeo copy or push-tags to a :latest tag)" bash -c "
    ! grep -nE 'skopeo copy[^#]*(octarine-os|octarine-os-dx|IMAGE)[^ ]*:latest( |\$)' $wf/build.yml $wf/build-dx.yml $wf/build-beta.yml &&
    grep -q 'docker://\$1:latest' '$here/.github/scripts/publish-latest.sh'"
exit "$fail"
