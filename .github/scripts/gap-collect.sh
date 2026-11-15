#!/usr/bin/env bash
# Writes the facts the Fedora-base gap analysis compares into a directory, one sorted text file per category. Runs INSIDE an image
# (the workflow mounts this script and the output directory); reads nothing outside the image and changes nothing in it.
#
#   gap-collect.sh <output directory>
#
# Files: packages.txt (rpm names), repos.txt (<repo file>:<id>:enabled=<0|1>), units-system.txt and units-user.txt (enabled unit files, system
# and global user), ublue-paths.txt (files under /usr/share/ublue-os, /etc/ublue-os and /usr/lib/ujust), dconf.txt (dconf files and the key lines of
# the distro databases), flatpak.txt (files under /usr/share/flatpak and /etc/flatpak, and the remotes).
set -uo pipefail
out=${1:?output directory}
mkdir -p "${out}"
rpm -qa --qf '%{NAME}\n' 2> /dev/null | sort -u > "${out}/packages.txt"
{
    for f in /etc/yum.repos.d/*.repo; do
        [[ -e "${f}" ]] || continue
        awk -v file="$(basename "${f}")" '
            /^\[/ { if (id != "") print file ":" id ":enabled=" en; id = substr($0, 2, length($0) - 2); en = 1; next }
            /^enabled[[:space:]]*=/ { sub(/^enabled[[:space:]]*=[[:space:]]*/, ""); en = $0 }
            END { if (id != "") print file ":" id ":enabled=" en }' "${f}"
    done
} | sort -u > "${out}/repos.txt"
systemctl list-unit-files --state=enabled --no-legend --no-pager 2> /dev/null | awk 'NF {print $1}' | sort -u > "${out}/units-system.txt"
systemctl --global list-unit-files --state=enabled --no-legend --no-pager 2> /dev/null | awk 'NF {print $1}' | sort -u > "${out}/units-user.txt"
find /usr/share/ublue-os /etc/ublue-os /usr/lib/ujust \( -type f -o -type l \) 2> /dev/null | sort -u > "${out}/ublue-paths.txt"
{
    find /etc/dconf -type f 2> /dev/null | sort -u
    for d in /etc/dconf/db/*.d; do
        [[ -d "${d}" ]] || continue
        grep -rhv -e '^[[:space:]]*#' -e '^[[:space:]]*$' "${d}" 2> /dev/null | sed "s|^|$(basename "${d}"): |"
    done
} | sort -u > "${out}/dconf.txt"
{
    find /usr/share/flatpak /etc/flatpak \( -type f -o -type l \) 2> /dev/null | sort -u
    cat /etc/flatpak/remotes.d/*.flatpakrepo 2> /dev/null | grep -E '^(Title|Url)=' | sort -u
} | sort -u > "${out}/flatpak.txt"
exit 0
