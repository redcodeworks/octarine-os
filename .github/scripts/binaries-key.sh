#!/usr/bin/env bash
# The key of the prebuilt binaries: the git tree id of binaries/ in HEAD (40 hex), so it changes with ANY file under binaries/ (a pin, a build script, the
# builder). The binaries workflow records it as the version label of octarine-binaries; the image build on testing and the promotion on main compare that label
# with the key of the commit they run on, which proves the image was built from exactly this binaries/ tree.
#
#   binaries-key.sh        print the key. Run from the repository root (or set REPO_ROOT); reads HEAD of the git checkout.
set -euo pipefail
cd "${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
git rev-parse HEAD:binaries
