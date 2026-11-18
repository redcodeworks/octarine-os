#!/usr/bin/env python3
"""The result of the aggregate job of build-variant.yml (`Build dx and push image`,
`Build gx and push image`) and build-extra.yml from the results of the jobs before it.

Environment: PLAN, BUILD, PROMOTE, SIGN (job results: success, failure, cancelled,
skipped), BUILD_WANTED and PROMOTE_WANTED (plan outputs). Exit 0 = pass.
  plan skipped        the triggering run is not one dx builds for (a failed or cancelled
                      vanilla run): nothing to report, the job passes and posts no
                      commit status (see build-variant.yml)
  build wanted        build and sign must have succeeded
  promote wanted      promote and sign (which verifies the signature of the retagged
                      digest) must have succeeded
  DRY_RUN=true        plan only: build, promote and sign must all be skipped, always
                      passes then
  neither             legitimate skip (base and dx inputs unchanged): build, promote and
                      sign must all be skipped
"""

import os
import sys
from pathlib import Path

here = Path(__file__).resolve().parent
sys.path[:0] = [str(here.parent / "00-lib"), str(here)]
import ci  # noqa: E402

env = os.environ.get


def fail(message):
    """Log an error and fail the aggregate job.

    Receives the message; logs it as an error and exits 1 through SystemExit.
    """
    ci.log.error(message)
    raise SystemExit(1)


def main(argv=None):
    """Check that the jobs of a dx or gx build ended as the plan wanted.

    Reads PLAN, BUILD, PROMOTE and SIGN (the results of the other jobs) and
    BUILD_WANTED, PROMOTE_WANTED and DRY_RUN (what the plan decided) from the
    environment. Returns 0 when everything is consistent; any surprise (a failed
    job, a job that ran when it should have been skipped) logs an error and exits 1,
    so the required check goes red.
    """
    ci.arg_parser(__doc__).parse_args(argv)
    # the four job results are required: a missing one is a wiring mistake, so let it
    # raise
    plan, build, promote, sign = (
        os.environ[n] for n in ("PLAN", "BUILD", "PROMOTE", "SIGN")
    )
    build_wanted, promote_wanted = env("BUILD_WANTED", ""), env("PROMOTE_WANTED", "")
    ci.log.info(
        f"plan={plan} build wanted={build_wanted} build={build} promote wanted={promote_wanted} promote={promote} sign={sign}"
    )
    all_skipped = build == "skipped" and promote == "skipped" and sign == "skipped"

    # the plan itself was skipped: no later job may have run
    if plan == "skipped":
        # a later job ran although the plan was skipped
        if not all_skipped:
            fail("Plan skipped but later jobs ran")
        ci.log.info("Not a run the dx image is built for: nothing to do")
        return 0

    # any other plan result than success is a failure
    if plan != "success":
        fail(f"The plan job did not succeed ({plan})")
    # a dry run plans only: nothing may have been built, promoted or signed
    if env("DRY_RUN") == "true":
        # a dry run plans and reports only: nothing may have been built, promoted or
        # signed
        # a job that ran in a dry run is a failure
        if not all_skipped:
            fail(
                f"Dry run, but later jobs ran (build {build}, promote {promote}, sign {sign})"
            )
        ci.log.info(
            f"Dry run: planned build={build_wanted} promote={promote_wanted}; nothing was built, pushed or signed"
        )
        return 0

    # each case is one plan outcome: build, promote or do nothing
    match build_wanted, promote_wanted:
        case "true", _:
            # a build must succeed and be signed, with no promotion
            if not (build == "success" and promote == "skipped" and sign == "success"):
                fail(
                    f"The dx build did not succeed (build {build}, promote {promote}, sign {sign})"
                )
        case _, "true":
            # a promotion must succeed and be signed, with no build
            if not (promote == "success" and build == "skipped" and sign == "success"):
                fail(
                    f"The dx promotion did not succeed (promote {promote}, build {build}, sign {sign})"
                )
            ci.log.info("Promoted the tested dx image: no rebuild")
        case _:
            # nothing wanted means every job must have been skipped
            if not all_skipped:
                fail(
                    f"Unexpected results (build {build}, promote {promote}, sign {sign})"
                )
            ci.log.info("Base and dx inputs unchanged: nothing to build")
    ci.log.info("ok")
    return 0


# run as a script, not when imported by a test
if __name__ == "__main__":
    sys.exit(main())
