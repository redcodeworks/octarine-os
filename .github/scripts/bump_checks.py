#!/usr/bin/env python3
"""Makes the checks of a bump pull request count. Usage: bump_checks.py <branch> <commit sha>      env: GH_TOKEN, GITHUB_REPOSITORY

Two facts found 2026-11-15 on #137 (check runs existed on the head commit, `gh pr checks` reported nothing, GraphQL statusCheckRollup was null, the PR stayed BLOCKED on the ruleset's required
`test` and `secrets`):
  1. a workflow_dispatch run on the bump branch is NOT part of the pull request's status rollup (a dispatch by a person on a plain branch is not either);
  2. check runs that are posted through the API join the commit's GitHub Actions check suite when one exists (the dispatch run's own), and are not counted there either; on a commit WITHOUT a GitHub
     Actions suite the API creates one, and that one counts (an experiment PR went from BLOCKED to CLEAN, the rollup listed test and secrets).
So the Test workflow is dispatched on the testing ref with `ref=<bump commit>` (it checks that commit out; its suite belongs to testing's commit, the bump commit stays without a suite), and this script
waits for that run and posts check runs named `test` and `secrets` on the bump commit with the real conclusions of those two jobs. No token beyond GITHUB_TOKEN (permissions `checks: write`,
`actions: write`); a run that did not finish posts nothing (the PR stays blocked: fail closed).

Idempotent: nothing happens when the commit already has a check run `test` with the marker title. Always exits 0 (a warning line says what is missing). Env: BUMP_BASE (the ref Test is dispatched on,
default testing), BUMP_CHECKS_WAIT (seconds to wait for the dispatched run to appear, default 90; 0 = do not wait), BUMP_CHECKS_POLL (5), BUMP_CHECKS_RUN_MAX (seconds to watch the run, 900).
"""
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ci  # noqa: E402

env = os.environ.get
# The marker is stored in the check runs this script posts (its title is how a rerun finds them), so it keeps the text of the shell era.
MARKER = "Reported by bump-checks.sh"


def warn(msg):
    print(f"::warning::{msg}")
    try:
        ci.append_to("GITHUB_STEP_SUMMARY", f"- {msg}")
    except OSError:
        pass


def gh_json(*args):
    p = ci.capture(["gh", *args])
    try:
        return json.loads(p.stdout) if p.returncode == 0 else None
    except ValueError:
        return None


def main(argv):
    if len(argv) < 2:
        sys.exit("usage: bump_checks.py <branch> <commit sha>")
    branch, sha = argv[0], argv[1]
    repo = env("GITHUB_REPOSITORY") or sys.exit("GITHUB_REPOSITORY: parameter null or not set")
    base = env("BUMP_BASE") or "testing"
    wait_s, poll, run_max = ci.int_env("BUMP_CHECKS_WAIT", 90), ci.int_env("BUMP_CHECKS_POLL", 5), ci.int_env("BUMP_CHECKS_RUN_MAX", 900)
    if not re.fullmatch(r"[0-9a-f]{40}", sha):
        warn(f"bump checks for {branch}: not a commit sha '{sha}', nothing posted")
        return 0
    runs = gh_json("api", f"repos/{repo}/commits/{sha}/check-runs?per_page=100") or {}
    if any(r.get("name") == "test" and (r.get("output") or {}).get("title") == MARKER for r in runs.get("check_runs", [])):
        print(f"{sha[:7]} already has its reported checks")
        return 0
    title = f"Test of {sha}"

    def find_run():
        listing = gh_json("run", "list", "--workflow", "test.yml", "--event", "workflow_dispatch", "--limit", "50", "--json", "databaseId,displayTitle") or []
        found = [r["databaseId"] for r in listing if r.get("displayTitle") == title]
        return str(found[0]) if found else ""

    run_id = find_run()
    if not run_id:
        if ci.run(["gh", "workflow", "run", "test.yml", "--ref", base, "-f", f"ref={sha}"]).returncode == 0:
            print(f"Dispatched the Test workflow on {base} for {sha[:7]} ({branch})")
        else:
            warn(f"Could not dispatch the Test workflow on {branch}: start it by hand with: gh workflow run test.yml --ref {base} -f ref={sha}")
            return 0
    waited = 0
    while not run_id and waited < wait_s:
        time.sleep(poll)
        waited += poll
        run_id = find_run()
    if not run_id:
        warn(f"bump checks for {branch}: no Test run for {sha[:7]} found, nothing posted (re-run the bump workflow)")
        return 0
    try:
        subprocess.run(["gh", "run", "watch", run_id, "-R", repo, "--interval", "20"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=run_max)
    except (subprocess.TimeoutExpired, OSError):
        pass
    info = gh_json("run", "view", run_id, "-R", repo, "--json", "status,url,jobs") or {}
    if info.get("status") != "completed":
        warn(f"bump checks for {branch}: the Test run {run_id} did not finish, nothing posted")
        return 0
    url = info.get("url", "")
    for name in ("test", "secrets"):
        concl = next((j.get("conclusion") or "missing" for j in info.get("jobs", []) if j.get("name") == name), "missing")
        if concl != "success":
            concl = "failure"
        p = ci.run(["gh", "api", "-X", "POST", f"repos/{repo}/check-runs", "-f", f"name={name}", "-f", f"head_sha={sha}", "-f", "status=completed", "-f", f"conclusion={concl}",
                    "-f", f"details_url={url}", "-f", f"output[title]={MARKER}",
                    "-f", f"output[summary]=The job `{name}` of the dispatched Test run {url} finished with {concl}."], stdout=subprocess.DEVNULL)
        if p.returncode == 0:
            print(f"posted check run {name}={concl} on {sha[:7]}")
        else:
            warn(f"bump checks for {branch}: could not post the check run {name}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
