#!/usr/bin/env bash
# Build libextest.so from the pinned source (already checked out by lib/fetch-source.sh) for both targets and stage the
# image content:
#
#   build.sh <upstream.env> <source dir> <out dir>
#
# The 64-bit library (x86_64-unknown-linux-gnu) becomes lib64/libextest.so and the 32-bit one (i686-unknown-linux-gnu,
# Steam is a 32-bit application) becomes lib/libextest.so, so LD_PRELOAD=<dir>/$LIB/libextest.so picks the right one per
# process. Upstream's .cargo/config.toml defaults to i686, so both targets are named explicitly. cargo runs with --locked.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
envfile="${1:?upstream.env}"
srcdir="${2:?source dir}"
out="${3:?out dir}"
stage="${STAGE_SH:-${here}/../lib/stage.sh}"

(cd "${srcdir}" && cargo build --release --locked --target i686-unknown-linux-gnu)
(cd "${srcdir}" && cargo build --release --locked --target x86_64-unknown-linux-gnu)
"${stage}" --out "${out}" --env "${envfile}" --src "${srcdir}" \
    --bin target/x86_64-unknown-linux-gnu/release/libextest.so:lib64/libextest.so \
    --bin target/i686-unknown-linux-gnu/release/libextest.so:lib/libextest.so \
    --license LICENSE:extest-LICENSE \
    --elf-x86-64 lib64/libextest.so --elf-i386 lib/libextest.so \
    --info 'targets: x86_64-unknown-linux-gnu (lib64/libextest.so), i686-unknown-linux-gnu (lib/libextest.so)'
