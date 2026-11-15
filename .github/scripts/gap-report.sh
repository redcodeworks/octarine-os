#!/usr/bin/env bash
# Assembles the Fedora-base gap report from the facts directories that gap-collect.sh wrote.
#
#   gap-report.sh --out DIR --ublue DIR --official DIR --reference DIR [--built DIR] --outcome built|failed [--log FILE] [--meta KEY=VALUE]...
#
# --ublue: the Universal Blue base the daily image is built on; --official: the official Fedora base; --reference: the published default image
# (the Universal Blue based result); --built: the same Containerfile built on the official base (absent when that build failed); --log: the build log.
# Writes DIR/report.md (compact: counts and the first GAP_LINES (50) lines of each diff, safe for an issue body) and DIR/diffs/*.diff (complete).
# A diff line starts with "-" (only on the left side of the comparison) or "+" (only on the right). Exits 0 when the report was written, whatever
# the facts say: a gap is the expected result, not a failure of this script.
set -uo pipefail
lines=${GAP_LINES:-50}
out="" ublue="" official="" reference="" built="" outcome="" log=""
meta=()
while (($#)); do
    case $1 in
        --out) out=$2; shift 2 ;;
        --ublue) ublue=$2; shift 2 ;;
        --official) official=$2; shift 2 ;;
        --reference) reference=$2; shift 2 ;;
        --built) built=$2; shift 2 ;;
        --outcome) outcome=$2; shift 2 ;;
        --log) log=$2; shift 2 ;;
        --meta) meta+=("$2"); shift 2 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done
[[ -n "${out}" && -d "${ublue}" && -d "${official}" && -d "${reference}" ]] || { echo "usage: gap-report.sh --out DIR --ublue DIR --official DIR --reference DIR [--built DIR] --outcome built|failed" >&2; exit 2; }
[[ "${outcome}" == built || "${outcome}" == failed ]] || { echo "--outcome must be built or failed" >&2; exit 2; }
mkdir -p "${out}/diffs"
cats="packages repos units-system units-user ublue-paths dconf flatpak"
label() {
    case $1 in
        packages) echo "Packages (rpm names)" ;;
        repos) echo "Enabled and disabled repositories" ;;
        units-system) echo "Enabled system units" ;;
        units-user) echo "Enabled global user units" ;;
        ublue-paths) echo "Files under /usr/share/ublue-os, /etc/ublue-os, /usr/lib/ujust" ;;
        dconf) echo "dconf files and distro database keys" ;;
        flatpak) echo "Flatpak defaults (files and remotes)" ;;
    esac
}
# diff_pair <name> <left dir> <right dir> <category>: writes diffs/<name>-<category>.diff
diff_pair() {
    local f=${out}/diffs/$1-$4.diff
    { comm -23 "$2/$4.txt" "$3/$4.txt" | sed 's/^/- /'; comm -13 "$2/$4.txt" "$3/$4.txt" | sed 's/^/+ /'; } > "${f}"
}
# section <name> <title> <left words> <right words>: a table of counts, then the first lines of each non-empty diff
section() {
    local name=$1 title=$2 c f nm np
    echo "### ${title}"
    echo
    echo "| Category | Only left (-) | Only right (+) |"
    echo "|---|---|---|"
    for c in ${cats}; do
        f=${out}/diffs/${name}-${c}.diff
        nm=$(grep -c '^- ' "${f}"); np=$(grep -c '^+ ' "${f}")
        echo "| $(label "${c}") | ${nm} | ${np} |"
    done
    echo
    for c in ${cats}; do
        f=${out}/diffs/${name}-${c}.diff
        [[ -s "${f}" ]] || continue
        echo "<details><summary>$(label "${c}"): first ${lines} lines of $(wc -l < "${f}")</summary>"
        echo
        echo '```diff'
        head -n "${lines}" "${f}"
        echo '```'
        echo
        echo "</details>"
        echo
    done
}
for c in ${cats}; do
    diff_pair ublue-to-official "${ublue}" "${official}" "${c}"
    [[ "${outcome}" == built && -d "${built}" ]] && diff_pair reference-to-built "${reference}" "${built}" "${c}"
done
{
    echo "# Official Fedora base gap analysis"
    echo
    for m in "${meta[@]+"${meta[@]}"}"; do echo "- ${m%%=*}: ${m#*=}"; done
    echo
    if [[ "${outcome}" == built ]]; then
        echo "**The image builds on the official base.** The comparison of the result with the published default image is below; read each table as a to-do list of what the move would change."
    else
        echo "**The build on the official base failed (a gap found, the expected result of an early run).**"
        if [[ -n "${log}" && -r "${log}" ]]; then
            echo
            awk '
                /STEP [0-9]+\/[0-9]+:/ { step = $0 }
                !done && tolower($0) ~ /(^|[^a-z])(error|fatal|failed)([^a-z]|$)/ { err = $0; errstep = step; done = 1 }
                END {
                    printf "- First error line: `%s`\n", (err == "" ? "(none found, see the log tail)" : err)
                    printf "- Containerfile step it happened in: `%s`\n", (errstep == "" ? "(no STEP line before it)" : errstep)
                }' "${log}"
            echo
            echo "<details><summary>Last 40 lines of the build log</summary>"
            echo
            echo '```'
            tail -n 40 "${log}"
            echo '```'
            echo
            echo "</details>"
        fi
        echo
        echo "The comparison of the result with the default image is not possible; the two bases are compared on their own instead (always done)."
    fi
    echo
    section ublue-to-official "Universal Blue base (left) against the official base (right)"
    if [[ "${outcome}" == built && -d "${built}" ]]; then
        section reference-to-built "Published default image (left) against the build on the official base (right)"
    fi
    echo "Complete diffs are in the workflow artifact (kept 90 days)."
} > "${out}/report.md"
exit 0
