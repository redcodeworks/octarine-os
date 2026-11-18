#!/usr/bin/env python3
"""Read from a registry so that "the registry could not be read" is never mistaken for "it is not there". Usage: registry_read.py raw|config <image reference without docker://>

raw prints the raw manifest (skopeo inspect --raw), config the image config JSON. Exit status: 0 the answer is on stdout; 3 ABSENT (skopeo said explicitly that the tag or repository
does not exist; nothing is retried); 4 READ ERROR (anything else, retried RETRY_TRIES times, 3, with the pause RETRY_DELAY, 5, times the try number); 2 usage.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import registry  # noqa: E402


def main(argv):
    if len(argv) != 2 or argv[0] not in ("raw", "config"):
        print("registry_read.py: usage: registry_read.py raw|config <image reference>", file=sys.stderr)
        return 2
    try:
        data = registry.read(argv[0], argv[1])
    except registry.RegistryError as e:
        return e.code
    sys.stdout.buffer.write(data)
    sys.stdout.buffer.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
