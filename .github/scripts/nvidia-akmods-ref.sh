#!/usr/bin/env bash
# Pick the akmods-nvidia image whose kernel is EXACTLY the kernel of the base image, and print its reference.
#
#   nvidia-akmods-ref.sh <kernel release with arch, e.g. 7.2.15-300.fc45.x86_64> <fedora version, e.g. 45>
#
# Prints three lines: tag=<tag>, digest=sha256:<64 hex>, ref=<image>@<digest>. Exits 1, printing why, when the kernel
# is malformed, does not belong to the Fedora version, or no kernel-specific tag exists. It NEVER falls back to the
# moving `main-<fedora>` tag: a mismatched kernel module would not load. The kernel-specific tag has the form
# `main-<fedora>-<kernel release>` with or without the architecture suffix (the form is UNVERIFIED, so both are tried).
#
# Environment: AKMODS_IMAGE (default ghcr.io/ublue-os/akmods-nvidia-lts), SKOPEO (default skopeo; tests use a stub).
set -uo pipefail

kernel="${1:?kernel release}"
fedora="${2:?fedora version}"
image="${AKMODS_IMAGE:-ghcr.io/ublue-os/akmods-nvidia-lts}"
skopeo="${SKOPEO:-skopeo}"

fail() { echo "ERROR: $*" >&2; exit 1; }

[[ "${kernel}" =~ ^[0-9]+\.[0-9]+\.[0-9]+-[0-9]+\.fc([0-9]+)\.x86_64$ ]] || fail "'${kernel}' is not a kernel release like 7.2.15-300.fc45.x86_64"
[[ "${BASH_REMATCH[1]}" == "${fedora}" ]] || fail "kernel ${kernel} belongs to Fedora ${BASH_REMATCH[1]}, not ${fedora}"

tried=()
for tag in "main-${fedora}-${kernel}" "main-${fedora}-${kernel%.x86_64}"; do
    tried+=("${tag}")
    raw=$("${skopeo}" inspect --raw "docker://${image}:${tag}" 2>/dev/null) || continue
    [[ -n "${raw}" ]] || continue
    digest="sha256:$(printf '%s' "${raw}" | sha256sum | sed 's/ .*//')"
    echo "tag=${tag}"
    echo "digest=${digest}"
    echo "ref=${image}@${digest}"
    exit 0
done
fail "no ${image} tag for kernel ${kernel} (tried: ${tried[*]}). The akmods image may not be built for this kernel yet, or its tag form differs; nothing is published."
