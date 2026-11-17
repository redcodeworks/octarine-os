#!/usr/bin/env bash
# Fails the image build when a package repository is enabled that this image does not expect (the idea of Bluefin's
# validate-repos.sh). Run late in every image build (build.sh, dx.sh, nvidia.sh), after the last package install and before
# final-cleanup.sh. Without it, a COPR or vendor repository that a package scriptlet or a `dnf5 config-manager` call left enabled
# would ship in the image and quietly change what `rpm-ostree install` and the update tooling can fetch.
#
# An ALLOW-LIST, not a deny-list: the repository ids the base image (ghcr.io/ublue-os/silverblue-main:45) enables today, read from
# `dnf5 repolist --enabled` in a container of the published image on 2026-11-14. Any other enabled id fails the build.
#   fedora, updates, updates-archive                 Fedora's own repositories (files in /usr/share/dnf5/repos.d on Fedora 45)
#   fedora-cisco-openh264                            Cisco's OpenH264 (Fedora's file)
#   fedora-multimedia                                negativo17 multimedia; its file says enabled=0 but the base enables it through
#                                                    /etc/dnf/repos.override.d/99-config_manager.repo (a `dnf config-manager setopt`)
#   copr:copr.fedorainfracloud.org:ublue-os:akmods   the base's akmods COPR
# No RPM Fusion repository is enabled (or even installed) in the base. A new base that enables another repository fails here
# with its id; add it below after checking that it is meant to be there.
#
# Two sources, because neither alone is complete: dnf5's own answer (it applies the override directory, which the .repo files do not
# show) and a scan of every section with enabled=1 in the repo directories (it also sees a file dnf5 would not load). A missing
# directory is fine. Env overrides exist for tests/image/validate-repos.sh: REPO_DIRS (colon separated), DNF5.
set -euo pipefail

ALLOWED=(
    fedora
    updates
    updates-archive
    fedora-cisco-openh264
    fedora-multimedia
    "copr:copr.fedorainfracloud.org:ublue-os:akmods"
)
REPO_DIRS=${REPO_DIRS:-/etc/yum.repos.d:/usr/share/dnf5/repos.d:/etc/dnf/repos.override.d}
DNF5=${DNF5:-dnf5}

echo "::group::validate-repos.sh"
trap 'rc=$?; echo "::endgroup::"; if (( rc != 0 )); then echo "::error::validate-repos.sh failed (exit ${rc})"; fi' EXIT

enabled=()
# 1. what dnf5 itself enables (header line "repo id ..." skipped)
if command -v "${DNF5}" >/dev/null 2>&1; then
    while read -r id _; do
        [[ -n "${id}" && "${id}" != "repo" ]] && enabled+=("${id}")
    done < <("${DNF5}" repolist --enabled)
else
    echo "NOTE: ${DNF5} not found, checking the repository files only"
fi
# 2. every [section] with enabled=1 (also "enabled = 1" and "enabled=True") in the repository directories
IFS=: read -r -a dirs <<< "${REPO_DIRS}"
for dir in "${dirs[@]}"; do
    [[ -d "${dir}" ]] || { echo "NOTE: ${dir} does not exist"; continue; }
    for f in "${dir}"/*.repo; do
        [[ -f "${f}" && -r "${f}" ]] || continue
        while read -r id; do
            enabled+=("${id}")
        done < <(awk '/^\[.*\]/ { s = substr($0, 2, length($0) - 2) }
                      tolower($0) ~ /^enabled[[:space:]]*=[[:space:]]*(1|true)[[:space:]]*$/ { print s }' "${f}")
    done
done

unexpected=()
declare -A seen=()
for id in "${enabled[@]}"; do
    [[ -z "${seen[${id}]:-}" ]] || continue
    seen[${id}]=1
    ok=0
    for a in "${ALLOWED[@]}"; do [[ "${id}" == "${a}" ]] && ok=1; done
    if (( ok )); then echo "enabled, expected: ${id}"; else echo "ENABLED, NOT EXPECTED: ${id}"; unexpected+=("${id}"); fi
done

if (( ${#unexpected[@]} > 0 )); then
    echo "::error::validate-repos.sh: repositories enabled that the image does not expect: ${unexpected[*]}" >&2
    echo "Disable them at the end of the step that added them (dnf5 config-manager setopt <id>.enabled=0), or, when the base" >&2
    echo "meant to enable them, add the id to ALLOWED in build_files/validate-repos.sh." >&2
    exit 1
fi
echo "validate-repos.sh: ${#seen[@]} enabled repositories, all expected"
