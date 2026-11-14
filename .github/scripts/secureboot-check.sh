#!/usr/bin/env bash
# Secure Boot check of the kernel in a built image, the way Bluefin and Aurora do it (their `secureboot` recipe): the kernel image (vmlinuz) must verify
# with sbverify against Universal Blue's kernel signing key, downloaded from the akmods repository, so a base image with an unsigned or differently
# signed kernel fails the build instead of failing to boot on a machine that has the Universal Blue key (MOK) enrolled.
#
#   secureboot-check.sh <image>      env: KERNEL_FILE (a vmlinuz to check instead of extracting one from the image; tests),
#                                         UBLUE_KEY_URL (where the DER key comes from; default: the akmods repository, branch main)
#
# 1. the image must hold exactly one kernel under /usr/lib/modules; its vmlinuz is copied out (podman create and cp, nothing is run),
# 2. the key is downloaded (fetch_key, curl with retries; a failed download fails the check clearly) and converted from DER to PEM,
# 3. `sbverify --list` is printed for diagnosis (a base kernel normally carries two signatures: Fedora's kernel-signer and Universal Blue's "ublue kernel"),
# 4. `sbverify --cert <key>` decides: exit 0 verified; exit 1 otherwise ("Secureboot Signature Failed"). The Fedora signature is NOT checked.
# Trust: the key is fetched live from the main branch of github.com/ublue-os/akmods on every run (see keys/README.md).
# Tools: podman (unless KERNEL_FILE), sbverify (sbsigntool/sbsigntools), curl, openssl.
set -euo pipefail
image=${1:?image}
url=${UBLUE_KEY_URL:-https://github.com/ublue-os/akmods/raw/main/certs/public_key.der}

# Download helper: one place to stub in tests (the test puts its own fetch_key in a file named by FETCH_KEY_OVERRIDE).
fetch_key() { curl --fail --silent --show-error --retry 3 -L -o "$2" "$1"; }
if [[ -n "${FETCH_KEY_OVERRIDE:-}" ]]; then
    # shellcheck disable=SC1090
    source "${FETCH_KEY_OVERRIDE}"
fi

work=$(mktemp -d)
cid=""
trap 'rm -rf "${work}"; [[ -z "${cid}" ]] || podman rm "${cid}" > /dev/null 2>&1 || true' EXIT
if [[ -n "${KERNEL_FILE:-}" ]]; then
    kernel=${KERNEL_FILE}; kver=test
else
    cid=$(podman create "${image}" /nonexistent)
    kvers=$(podman run --rm --entrypoint ls "${image}" /usr/lib/modules)
    [[ "$(wc -w <<<"${kvers}")" == 1 ]] || { echo "::error::${image} holds not exactly one kernel under /usr/lib/modules: ${kvers}" >&2; exit 1; }
    kver=${kvers}
    podman cp "${cid}:/usr/lib/modules/${kver}/vmlinuz" "${work}/vmlinuz"
    kernel=${work}/vmlinuz
fi

if ! fetch_key "${url}" "${work}/kernel-sign.der" || [[ ! -s "${work}/kernel-sign.der" ]]; then
    echo "::error::could not download the Universal Blue kernel signing key from ${url}: the Secure Boot check cannot run (a network or upstream problem, not necessarily the kernel)" >&2
    exit 1
fi
if ! openssl x509 -inform DER -in "${work}/kernel-sign.der" -out "${work}/kernel-sign.crt" 2> /dev/null; then
    echo "::error::the file downloaded from ${url} is not a DER certificate" >&2
    exit 1
fi
fp=$(openssl x509 -in "${work}/kernel-sign.crt" -noout -fingerprint -sha256 2> /dev/null || echo "fingerprint unreadable")
echo "== signing key: ${url}"
openssl x509 -in "${work}/kernel-sign.crt" -noout -subject -enddate 2> /dev/null || true
echo "${fp}"

echo "== kernel ${kver} of ${image}: sbverify --list"
sbverify --list "${kernel}" || true
if sbverify --cert "${work}/kernel-sign.crt" "${kernel}"; then
    echo "Secure Boot: the kernel ${kver} of ${image} verifies against the Universal Blue kernel key (${fp})"
else
    echo "::error::Secureboot Signature Failed: the kernel ${kver} of ${image} does NOT verify against the Universal Blue kernel key (${fp}); it would not boot on a machine with that key enrolled (the signatures it does carry are listed above)" >&2
    exit 1
fi
