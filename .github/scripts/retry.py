#!/usr/bin/env python3
"""Run a command up to N times with a growing pause, for calls to the network (registries, apt, cosign's lookups) that fail for a moment. Usage: retry.py [-n TRIES] [-d DELAY] [--] command [args...]

Defaults: RETRY_TRIES (3) and RETRY_DELAY (5 seconds; the pause before try k+1 is DELAY*k). stdout and stderr of the command pass through. Exit status: 0 when a try succeeded, else the
status of the last try. A permanent failure (a bad signature, a missing package) runs out the tries and fails with the command's own status. Not for commands that must not run twice.
"""

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ci  # noqa: E402


class Failed(ci.NetworkError):
    def __init__(self, cmd, code):
        super().__init__(f"{' '.join(cmd[:2])} failed (exit {code})")
        self.code = code


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.strip().splitlines()[0], usage="retry.py [-n TRIES] [-d DELAY] [--] command [args...]")
    ap.add_argument("-n", type=int, dest="tries", default=ci.int_env("RETRY_TRIES", 3))
    ap.add_argument("-d", type=int, dest="delay", default=ci.int_env("RETRY_DELAY", 5))
    ap.add_argument("command", nargs=argparse.REMAINDER)
    args = ap.parse_args(argv)
    cmd = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not cmd or args.tries < 1 or args.delay < 0:
        ap.error("a command, TRIES of at least 1 and a DELAY of 0 or more are required")

    @ci.retry(attempts=args.tries, delay=args.delay, on=(Failed,))
    def attempt():
        code = ci.run(cmd, stdin=None).returncode
        if code:
            raise Failed(cmd, code)

    try:
        attempt()
    except Failed as e:
        ci.log.error(f"{e}: a transient network error would have passed by now, so treat this as a real failure (bad signature, missing package or tag, or a longer outage)")
        return e.code
    return 0


if __name__ == "__main__":
    sys.exit(main())
