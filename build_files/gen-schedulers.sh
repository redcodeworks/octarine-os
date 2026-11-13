#!/usr/bin/env bash
# Generates the scheduler registry and the per-instance unit drop-ins from the manifest of the prebuilt binaries. Run by build.sh
# after install-binaries.sh (DESTDIR only for tests/schedulers.sh).
#
#   input    /usr/share/octarine-os/schedulers.tsv   four tab-separated fields: name, path (bin/<name>), minimum kernel (EMPTY for
#            all seven today), description (up to 120 characters); no header. Read with awk -F'\t' and cut -f, never with
#            `IFS=$'\t' read`, which collapses an empty field.
#   output   /usr/share/octarine-os/schedulers.d/<instance>.conf       one file per scheduler (KEY=value lines)
#            /usr/lib/systemd/system/scx@<instance>.service.d/10-conflicts.conf   Conflicts= on every other instance
#            /usr/lib/systemd/system/scx@<instance>.service.d/20-kernel.conf      ConditionKernelVersion=>=<min>, only when the
#                                                                                 registry has a minimum kernel
#            /usr/share/polkit-1/rules.d/50-octarine-scx.rules   from usr/share/octarine-os/polkit/50-octarine-scx.rules.in with
#                                                                the exact alternation of the instance names
# The instance name is the scheduler name without the scx_ prefix (scx_rusty -> rusty): scx@rusty.service. Adding a scheduler is a
# line in binaries/scx/schedulers.tsv plus the next bump of the binaries; nothing here changes.
set -euo pipefail
dest=${DESTDIR:-}
tsv="${dest}/usr/share/octarine-os/schedulers.tsv"
reg="${dest}/usr/share/octarine-os/schedulers.d"
units="${dest}/usr/lib/systemd/system"

[[ -s "${tsv}" ]] || { echo "ERROR: ${tsv} is missing or empty" >&2; exit 1; }
rm -rf "${reg}"
mkdir -p "${reg}"

instances=()
while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    n=$(cut -f1 <<<"${line}")
    path=$(cut -f2 <<<"${line}")
    kernel=$(cut -f3 <<<"${line}")
    desc=$(cut -f4 <<<"${line}")
    fields=$(awk -F'\t' '{print NF}' <<<"${line}")
    [[ "${fields}" == 4 ]] || { echo "ERROR: '${line}' needs exactly four tab separated fields" >&2; exit 1; }
    [[ "${n}" =~ ^scx_[a-z0-9][a-z0-9_]*$ ]] || { echo "ERROR: bad scheduler name '${n}'" >&2; exit 1; }
    [[ "${path}" == "bin/${n}" ]] || { echo "ERROR: ${n}: path must be bin/${n}, got '${path}'" >&2; exit 1; }
    [[ -z "${kernel}" || "${kernel}" =~ ^[0-9]+\.[0-9]+$ ]] || { echo "ERROR: ${n}: minimum kernel must be MAJOR.MINOR or empty" >&2; exit 1; }
    [[ -n "${desc}" && ${#desc} -le 120 ]] || { echo "ERROR: ${n}: description missing or longer than 120 characters" >&2; exit 1; }
    [[ -x "${dest}/usr/bin/${n}" ]] || { echo "ERROR: /usr/bin/${n} is not installed" >&2; exit 1; }
    inst=${n#scx_}
    [[ " ${instances[*]:-} " != *" ${inst} "* ]] || { echo "ERROR: duplicate instance ${inst}" >&2; exit 1; }
    instances+=("${inst}")
    {
        echo "# Generated from /usr/share/octarine-os/schedulers.tsv at image build; do not edit."
        echo "NAME=${n}"
        echo "INSTANCE=${inst}"
        echo "BINARY=/usr/bin/${n}"
        echo "DESCRIPTION=${desc}"
        echo "MIN_KERNEL=${kernel}"
        echo "FLAGS="
    } > "${reg}/${inst}.conf"
done < <(grep -vE '^[[:space:]]*(#|$)' "${tsv}")

[[ ${#instances[@]} -gt 0 ]] || { echo "ERROR: no scheduler in ${tsv}" >&2; exit 1; }

for inst in "${instances[@]}"; do
    d="${units}/scx@${inst}.service.d"
    mkdir -p "${d}"
    others=()
    for o in "${instances[@]}"; do [[ "${o}" == "${inst}" ]] || others+=("scx@${o}.service"); done
    {
        echo "[Unit]"
        echo "# Generated at image build: only one sched_ext scheduler can be loaded, so starting this one stops the others."
        [[ ${#others[@]} -eq 0 ]] || echo "Conflicts=${others[*]}"
    } > "${d}/10-conflicts.conf"
    kernel=$(awk -F= '$1 == "MIN_KERNEL" { print $2 }' "${reg}/${inst}.conf")
    rm -f "${d}/20-kernel.conf"
    if [[ -n "${kernel}" ]]; then
        printf '[Unit]\nConditionKernelVersion=>=%s\n' "${kernel}" > "${d}/20-kernel.conf"
    fi
done
# The polkit rule: the template with the exact alternation of the instance names. The names were validated above
# (^[a-z0-9][a-z0-9_]*$), so nothing in them is special in a regular expression; they are escaped anyway.
# The rule must never exist without the template unit: StartTransientUnit under a name scx@x.service also matches the rule, and the
# only thing that stops a transient root unit with an arbitrary ExecStart is systemd's "already loaded or has a fragment file".
[[ -s "${units}/scx@.service" ]] || { echo "ERROR: ${units}/scx@.service is missing: not generating the polkit rule without the template unit" >&2; exit 1; }
tpl="${dest}/usr/share/octarine-os/polkit/50-octarine-scx.rules.in"
rule="${dest}/usr/share/polkit-1/rules.d/50-octarine-scx.rules"
[[ -s "${tpl}" ]] || { echo "ERROR: ${tpl} is missing" >&2; exit 1; }
grep -q '@INSTANCES@' "${tpl}" || { echo "ERROR: ${tpl} has no @INSTANCES@ placeholder" >&2; exit 1; }
alt=""
for inst in "${instances[@]}"; do
    esc=$(sed 's/[][\\.^$*+?(){}|\/-]/\\&/g' <<<"${inst}")
    alt+="${alt:+|}${esc}"
done
mkdir -p "$(dirname "${rule}")"
sed "s/@INSTANCES@/${alt}/" "${tpl}" > "${rule}"
if grep -q '@INSTANCES@' "${rule}"; then echo "ERROR: placeholder left in ${rule}" >&2; exit 1; fi
echo "Scheduler registry: ${instances[*]}"
