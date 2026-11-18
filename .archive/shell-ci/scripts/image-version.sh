#!/usr/bin/env bash
# Print the version stamped on every image build, testing or main: <YYYYMMDD>-<short sha>, for example
# 20261108-b8a6aba. It names no channel on purpose: promotion retags a tested digest as `latest` without
# changing the image, so a channel in the version would be wrong after the retag.
# Environment overrides (tests): VERSION_DATE, VERSION_SHA.
set -euo pipefail
date="${VERSION_DATE:-$(date +%Y%m%d)}"
sha="${VERSION_SHA:-$(git rev-parse --short HEAD)}"
printf '%s-%s\n' "${date}" "${sha}"
