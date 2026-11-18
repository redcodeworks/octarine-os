#!/usr/bin/env python3
"""The result of the aggregate job of build-variant.yml (`Build dx and push image`, `Build gx and push image`) and build-extra.yml from the results of the jobs before it.

Environment: PLAN, BUILD, PROMOTE, SIGN (job results: success, failure, cancelled, skipped), BUILD_WANTED and PROMOTE_WANTED (plan outputs). Exit 0 = pass.
  plan skipped        the triggering run is not one dx builds for (a failed or cancelled vanilla run): nothing to report, the job passes and posts no commit status (see build-variant.yml)
  build wanted        build and sign must have succeeded
  promote wanted      promote and sign (which verifies the signature of the retagged digest) must have succeeded
  DRY_RUN=true        plan only: build, promote and sign must all be skipped, always passes then
  neither             legitimate skip (base and dx inputs unchanged): build, promote and sign must all be skipped
"""
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ci  # noqa: E402

env = os.environ.get


def required(name):
    return env(name) or sys.exit(f"{name}: parameter null or not set")


def main():
    plan, build, promote, sign = (required(n) for n in ("PLAN", "BUILD", "PROMOTE", "SIGN"))
    build_wanted, promote_wanted = env("BUILD_WANTED", ""), env("PROMOTE_WANTED", "")
    print(f"plan={plan} build wanted={build_wanted} build={build} promote wanted={promote_wanted} promote={promote} sign={sign}")
    all_skipped = build == "skipped" and promote == "skipped" and sign == "skipped"
    if plan == "skipped":
        if not all_skipped:
            ci.fail("Plan skipped but later jobs ran")
        print("Not a run the dx image is built for: nothing to do")
        return 0
    if plan != "success":
        ci.fail(f"The plan job did not succeed ({plan})")
    if env("DRY_RUN") == "true":
        # a dry run plans and reports only: nothing may have been built, promoted or signed
        if not all_skipped:
            ci.fail(f"Dry run, but later jobs ran (build {build}, promote {promote}, sign {sign})")
        print(f"Dry run: planned build={build_wanted} promote={promote_wanted}; nothing was built, pushed or signed")
        return 0
    if build_wanted == "true":
        if not (build == "success" and promote == "skipped" and sign == "success"):
            ci.fail(f"The dx build did not succeed (build {build}, promote {promote}, sign {sign})")
    elif promote_wanted == "true":
        if not (promote == "success" and build == "skipped" and sign == "success"):
            ci.fail(f"The dx promotion did not succeed (promote {promote}, build {build}, sign {sign})")
        print("Promoted the tested dx image: no rebuild")
    else:
        if not all_skipped:
            ci.fail(f"Unexpected results (build {build}, promote {promote}, sign {sign})")
        print("Base and dx inputs unchanged: nothing to build")
    print("ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
