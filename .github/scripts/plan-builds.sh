#!/usr/bin/env bash
# Decide which images a workflow run builds and print the matrix as JSON (one line).
#
#   plan-builds.sh <event> <schedule> [<date>]
#
# <event> is github.event_name, <schedule> is github.event.schedule (only set for scheduled runs),
# <date> is the day to evaluate (default: today, UTC; the tests pass fixed dates).
#
#   schedule DAILY_CRON   -> octarine-os only (unchanged daily refresh of `latest`)
#   schedule WEEKLY_CRON  -> octarine-os-stable, but only on even ISO weeks. GitHub cron cannot say
#                            "every 14 days", so it fires weekly and this skips every other run
#   anything else (push, pull_request, workflow_dispatch) -> both images
#
# An empty list ({"include":[]}) means "build nothing"; the workflow then skips the build jobs.
# The cron strings must match build.yml (tests/plan-builds.sh checks that they do).
set -euo pipefail

DAILY_CRON='05 10 * * *'
WEEKLY_CRON='35 10 * * 1'

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
env_file="${ENV_FILE:-$here/../../image-template.env}"

event="${1:?event}"
schedule="${2-}"
day="${3:-$(date -u +%F)}"

read_var() { sed -n "s/^$1=//p" "${env_file}" | tr -d '"' | head -n1; }
main_image=$(read_var IMAGE_NAME)
stable_image=$(read_var IMAGE_NAME_STABLE)
stable_base=$(read_var STABLE_BASE_TAG)
[[ -n "${main_image}" && -n "${stable_image}" && -n "${stable_base}" ]] || { echo "image names or STABLE_BASE_TAG missing in ${env_file}" >&2; exit 1; }

# Even ISO week? %V is zero padded ("08", "09"), which bash arithmetic would read as octal, so force
# base 10. %V (not %U/%W) so that days around New Year belong to the ISO week they count in.
is_even_iso_week() {
    local week
    week=$(date -u -d "$1" +%V)
    (( 10#${week} % 2 == 0 ))
}

main_entry() { printf '{"image":"%s","base_tag":"45","main_tag":"latest"}' "${main_image}"; }
stable_entry() { printf '{"image":"%s","base_tag":"%s","main_tag":"stable"}' "${stable_image}" "${stable_base}"; }

entries=()
if [[ "${event}" == "schedule" ]]; then
    case "${schedule}" in
        "${DAILY_CRON}") entries+=("$(main_entry)") ;;
        "${WEEKLY_CRON}")
            if is_even_iso_week "${day}"; then
                entries+=("$(stable_entry)")
            else
                echo "ISO week $(date -u -d "${day}" +%V) is odd: skipping the stable build" >&2
            fi
            ;;
        *) echo "unknown schedule '${schedule}'" >&2; exit 1 ;;
    esac
else
    entries+=("$(main_entry)" "$(stable_entry)")
fi

joined=$(IFS=,; echo "${entries[*]-}")
printf '{"include":[%s]}\n' "${joined}"
