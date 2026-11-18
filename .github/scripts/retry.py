#!/usr/bin/env python3
"""THE retry helper of the pipeline: run a command up to N times with a growing pause, for calls to the network (registries, apt, cosign's transparency and key lookups) that fail for a moment.
Usage: retry.py [-n TRIES] [-d DELAY] [--] command [args...]   (defaults: RETRY_TRIES=3, RETRY_DELAY=5 seconds; the pause before try k+1 is DELAY*k)

It changes nothing else: what is verified stays the same, a permanent failure (a bad signature, a missing package) runs out the tries and then fails with the command's own exit status and a
clear message. stdout and stderr of the command pass through; the notices go to stderr as ::warning:: (every failed try) and ::error:: (the last one). Exit status: 0 when a try succeeded, else
the status of the last try. Not for commands that must not run twice (a push that is not idempotent).
"""
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ci  # noqa: E402


def main(argv):
    tries = os.environ.get("RETRY_TRIES", "3")
    delay = os.environ.get("RETRY_DELAY", "5")
    while argv:
        if argv[0] == "-n" and len(argv) > 1:
            tries, argv = argv[1], argv[2:]
        elif argv[0] == "-d" and len(argv) > 1:
            delay, argv = argv[1], argv[2:]
        elif argv[0] == "--":
            argv = argv[1:]
            break
        else:
            break
    if not (tries.isdigit() and int(tries) >= 1):
        print(f"retry.py: bad tries '{tries}'", file=sys.stderr)
        return 2
    if not delay.isdigit():
        print(f"retry.py: bad delay '{delay}'", file=sys.stderr)
        return 2
    if not argv:
        print("usage: retry.py [-n TRIES] [-d DELAY] [--] command [args...]", file=sys.stderr)
        return 2
    return ci.retry_command(argv, int(tries), int(delay))


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
