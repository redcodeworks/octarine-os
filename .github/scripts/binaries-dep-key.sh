#!/usr/bin/env bash
# Key of the DOWNLOADED-dependency cache of a component (an optimisation only, never trusted: see binaries/ghostty/build.sh).
#
#   binaries-dep-key.sh <component>     prints 40 hex, or nothing (exit 0) for a component without a dependency cache
#
# ghostty: sha1 over the pin files that decide WHICH packages are needed and HOW they are unpacked: upstream.env (tag and peeled commit), zig.env
# (the Zig version and sha256) and build.sh (the fetch, unpack and flatten recipe), so a changed pin or recipe starts a fresh cache. scx and extest have
# none: their cargo download phase is under 1 percent of the job (profile of 2026-11-15).
set -euo pipefail
root=${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}
c=${1:?component}
case "${c}" in
    ghostty)
        cd "${root}/binaries/ghostty"
        cat upstream.env zig.env build.sh | sha1sum | cut -c1-40 ;;
    *) ;;
esac
