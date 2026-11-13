#!/usr/bin/env bash
# Installs the prebuilt binaries into the image tree. Run by build.sh; the Containerfile bind-mounts the published
# octarine-os-binaries image (built from binaries/, see binaries/Containerfile) at /binaries (BINARIES_ROOT overrides the
# source, DESTDIR the target; both only for tests/binary-images.sh).
#   scx     bin/scx_*, schedulers.tsv (name, path, minimum kernel, description; tab separated, no header),
#           LICENSES/, SOURCE, BUILDINFO  ->  /usr/bin, /usr/share/octarine-os/schedulers.tsv
#   extest  lib/libextest.so (32-bit), lib64/libextest.so (64-bit), LICENSES/, SOURCE, BUILDINFO  ->  /usr/lib/extest
# The license texts, source and build records go to /usr/share/licenses/octarine-os-binaries/<image>/ (the GPL-2.0 and MIT
# texts must ship with the binaries). Nothing is enabled or started.
set -euo pipefail
root=${BINARIES_ROOT:-/binaries}
dest=${DESTDIR:-}
scx=${root}/scx
ext=${root}/extest

test -s "${scx}/schedulers.tsv" || { echo "ERROR: ${scx}/schedulers.tsv is missing or empty" >&2; exit 1; }
# The manifest and the files must agree both ways: every line has four fields and a path of bin/<name>, every listed
# scheduler exists, every file under bin/ is listed. awk and cut, not `read` with a tab IFS: the minimum-kernel field is
# empty today and `read` would collapse it.
awk -F'\t' 'NF != 4 || $1 == "" || $2 != "bin/" $1 { bad = 1 } END { exit bad }' "${scx}/schedulers.tsv" \
    || { echo "ERROR: schedulers.tsv lines must be name, bin/name, minimum kernel, description (tab separated)" >&2; exit 1; }
listed=$(cut -f1 "${scx}/schedulers.tsv")
for n in ${listed}; do
    test -f "${scx}/bin/${n}" || { echo "ERROR: ${n} is listed in schedulers.tsv but missing from bin/" >&2; exit 1; }
    install -Dm0755 "${scx}/bin/${n}" "${dest}/usr/bin/${n}"
done
for f in "${scx}"/bin/*; do
    grep -qxF "$(basename "${f}")" <<<"${listed}" || { echo "ERROR: ${f} is not listed in schedulers.tsv" >&2; exit 1; }
done
install -Dm0644 "${scx}/schedulers.tsv" "${dest}/usr/share/octarine-os/schedulers.tsv"

test -f "${ext}/lib/libextest.so" && test -f "${ext}/lib64/libextest.so" || { echo "ERROR: extest lacks lib/ or lib64/ libextest.so" >&2; exit 1; }
install -Dm0755 "${ext}/lib/libextest.so" "${dest}/usr/lib/extest/lib/libextest.so"
install -Dm0755 "${ext}/lib64/libextest.so" "${dest}/usr/lib/extest/lib64/libextest.so"

for img in scx extest; do
    lic=${dest}/usr/share/licenses/octarine-os-binaries/${img}
    install -d "${lic}"
    cp -a "${root}/${img}/LICENSES/." "${lic}/"
    install -m0644 "${root}/${img}/SOURCE" "${root}/${img}/BUILDINFO" "${lic}/"
done
grep -rqF 'GNU GENERAL PUBLIC LICENSE' "${dest}/usr/share/licenses/octarine-os-binaries/scx" || { echo "ERROR: no GPL text shipped with scx" >&2; exit 1; }
grep -rqF 'MIT License' "${dest}/usr/share/licenses/octarine-os-binaries/extest" || { echo "ERROR: no MIT text shipped with extest" >&2; exit 1; }
echo "Installed the prebuilt binaries: $(tr '\n' ' ' <<<"${listed}")"
