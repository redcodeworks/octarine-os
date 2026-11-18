#!/usr/bin/env python3
"""Print the version stamped on every image build, testing or main: <YYYYMMDD>-<short
sha>, for example 20261108-b8a6aba.

It names no channel on purpose: promotion retags a tested digest as `latest` without
changing the image, so a channel in the version would be wrong after the retag.
Environment overrides (tests): VERSION_DATE, VERSION_SHA.
"""

import os
import sys
import time
from pathlib import Path

here = Path(__file__).resolve().parent
sys.path[:0] = [str(here.parent / "00-lib"), str(here)]
import ci  # noqa: E402


def main(argv=None):
    """Print the image version label, `<date>-<sha>`.

    Reads VERSION_DATE and VERSION_SHA (test hooks); by default the current date and
    the short sha of HEAD. Writes the version as the result and returns 0.
    """
    ci.arg_parser(__doc__).parse_args(argv)
    date = os.environ.get("VERSION_DATE") or time.strftime("%Y%m%d")
    sha = os.environ.get("VERSION_SHA") or ci.git("rev-parse", "--short", "HEAD")
    ci.result(f"{date}-{sha}")
    return 0


# run as a script, not when imported by a test
if __name__ == "__main__":
    sys.exit(main())
