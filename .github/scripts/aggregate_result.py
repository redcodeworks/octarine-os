#!/usr/bin/env python3
"""Decide the result of the aggregate job `Build and push image` from the results of the
jobs before it.

Environment: PLAN, BUILD, PROMOTE, SIGN (job results: success, failure, cancelled,
skipped), BUILD_WANTED, PROMOTE_WANTED (plan outputs), PUBLISH (build_push output
`publish`). Exit 0 = pass. It means: planned, built (or promoted, or docs-only skipped)
and, when anything was published, signed and verified. A skipped sign job is fine only
when nothing was published.
"""

import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ci  # noqa: E402

env = os.environ.get


def fail(message):
    """Log an error and fail the aggregate job.

    Receives the message; logs it as an error and exits 1 through SystemExit.
    """
    ci.log.error(message)
    raise SystemExit(1)


def expects_sign(build_wanted, promote_wanted, publish, build, promote) -> bool:
    """Check the build and promote results against what the plan wanted; whether a
    signature is expected.
    """
    # each case is one plan outcome: build, promote or do nothing
    match build_wanted, promote_wanted:
        case "true", _:
            # a build must succeed and promote must be skipped
            if not (build == "success" and promote == "skipped"):
                fail(f"The image build did not succeed ({build}, promote {promote})")
            return publish == "true"
        case _, "true":
            # a promotion must succeed and the build must be skipped
            if not (promote == "success" and build == "skipped"):
                fail(f"The promotion did not succeed ({promote}, build {build})")
            ci.log.info("Promoted a tested image: no rebuild")
            return True
        case _:
            # nothing wanted means both jobs must have been skipped
            if not (build == "skipped" and promote == "skipped"):
                fail(f"Unexpected results (build {build}, promote {promote})")
            ci.log.info(
                "Docs-only change or unchanged scheduled run: heavy build skipped"
            )
            return False


def main(argv=None):
    """Check that the jobs of the default-image build ended as the plan wanted.

    Reads PLAN, BUILD, PROMOTE and SIGN (the results of the other jobs) and
    BUILD_WANTED, PROMOTE_WANTED and PUBLISH (what the plan decided) from the
    environment. Returns 0 when everything is consistent; any surprise logs an error
    and exits 1, so the required check goes red.
    """
    ci.arg_parser(__doc__).parse_args(argv)
    # the four job results are required: a missing one is a wiring mistake, so let it
    # raise
    plan, build, promote, sign = (
        os.environ[n] for n in ("PLAN", "BUILD", "PROMOTE", "SIGN")
    )
    build_wanted, promote_wanted, publish = (
        env("BUILD_WANTED", ""),
        env("PROMOTE_WANTED", ""),
        env("PUBLISH", ""),
    )
    ci.log.info(
        f"plan={plan} build wanted={build_wanted} build={build} promote wanted={promote_wanted} promote={promote} publish={publish} sign={sign}"
    )
    # without a successful plan nothing else can be judged
    if plan != "success":
        fail("The plan job did not succeed")
    sign_expected = expects_sign(build_wanted, promote_wanted, publish, build, promote)
    # a signature is needed exactly when something was published or promoted
    if sign_expected:
        # signing is expected, so the sign job must have succeeded
        if sign != "success":
            fail(f"Signing and verification did not succeed ({sign})")
    elif sign != "skipped":
        fail(f"Unexpected sign result {sign} with nothing published")
    ci.log.info("ok")
    return 0


# run as a script, not when imported by a test
if __name__ == "__main__":
    sys.exit(main())
