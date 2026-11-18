#!/usr/bin/env python3
"""Print the version stamped on every image build, testing or main: <YYYYMMDD>-<short sha>, for example 20261108-b8a6aba.

It names no channel on purpose: promotion retags a tested digest as `latest` without changing the image, so a channel in the version would be wrong after the retag.
Environment overrides (tests): VERSION_DATE, VERSION_SHA.
"""

import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ci  # noqa: E402


def main(argv=None):
    ci.arg_parser(__doc__).parse_args(argv)
    date = os.environ.get("VERSION_DATE") or time.strftime("%Y%m%d")
    sha = os.environ.get("VERSION_SHA") or ci.git("rev-parse", "--short", "HEAD")
    print(f"{date}-{sha}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
