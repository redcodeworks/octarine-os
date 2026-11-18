#!/usr/bin/env python3
"""Decide the result of the aggregate job `Build and push image` from the results of the jobs before it.

Environment: PLAN, BUILD, PROMOTE, SIGN (job results: success, failure, cancelled, skipped), BUILD_WANTED, PROMOTE_WANTED (plan outputs), PUBLISH (build_push output `publish`).
Exit 0 = pass. It means: planned, built (or promoted, or docs-only skipped) and, when anything was published, signed and verified. A skipped sign job is fine only when nothing was published.
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
    build_wanted, promote_wanted, publish = env("BUILD_WANTED", ""), env("PROMOTE_WANTED", ""), env("PUBLISH", "")
    print(f"plan={plan} build wanted={build_wanted} build={build} promote wanted={promote_wanted} promote={promote} publish={publish} sign={sign}")
    if plan != "success":
        ci.fail("The plan job did not succeed")
    sign_expected = False
    if build_wanted == "true":
        if not (build == "success" and promote == "skipped"):
            ci.fail(f"The image build did not succeed ({build}, promote {promote})")
        sign_expected = publish == "true"
    elif promote_wanted == "true":
        if not (promote == "success" and build == "skipped"):
            ci.fail(f"The promotion did not succeed ({promote}, build {build})")
        sign_expected = True
        print("Promoted a tested image: no rebuild")
    else:
        if not (build == "skipped" and promote == "skipped"):
            ci.fail(f"Unexpected results (build {build}, promote {promote})")
        print("Docs-only change or unchanged scheduled run: heavy build skipped")
    if sign_expected:
        if sign != "success":
            ci.fail(f"Signing and verification did not succeed ({sign})")
    elif sign != "skipped":
        ci.fail(f"Unexpected sign result {sign} with nothing published")
    print("ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
