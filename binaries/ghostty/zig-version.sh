#!/usr/bin/env bash
# Zig version rules of Ghostty. Source this file (the build and the weekly bump both use it):
#
#   zig_required_of <build.zig.zon>       prints minimum_zig_version
#   zig_satisfies <required> <have>       0 when MAJOR.MINOR are equal and the PATCH of <have> is at least the required one
#
# Ghostty's build.zig refuses a Zig whose major and minor differ from minimum_zig_version (and a lower patch), so the pinned
# toolchain has to satisfy the value in the pinned source: a bump that needs another Zig fails instead of building with the wrong one.

zig_required_of() {
    local v
    v=$(sed -n 's/^[[:space:]]*\.minimum_zig_version[[:space:]]*=[[:space:]]*"\([0-9][0-9.]*\)".*$/\1/p' "$1" | head -n1)
    [[ "${v}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "zig-version.sh: no minimum_zig_version (MAJOR.MINOR.PATCH) in $1" >&2; return 1; }
    echo "${v}"
}

zig_satisfies() {
    local req=$1 have=$2
    [[ "${req}" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || return 1
    local rmaj=${BASH_REMATCH[1]} rmin=${BASH_REMATCH[2]} rpat=${BASH_REMATCH[3]}
    [[ "${have}" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || return 1
    [[ "${BASH_REMATCH[1]}" == "${rmaj}" && "${BASH_REMATCH[2]}" == "${rmin}" ]] && (( BASH_REMATCH[3] >= rpat ))
}
