#!/usr/bin/env bash
# Secure Boot check of the kernel in a built image: the kernel image (vmlinuz) must verify with sbverify against the certificate pinned in the repository, so a
# base image with an unsigned or differently signed kernel fails the build instead of failing to boot on a Secure Boot machine.
#
#   secureboot-check.sh <image> [<pinned certificate PEM>]       env: KERNEL_FILE (a vmlinuz to check instead of extracting one from the image; tests)
#
# 1. the image must hold exactly one kernel under /usr/lib/modules; its vmlinuz is copied out (podman create and cp, nothing is run),
# 2. `sbverify --list` is printed (the signature chain of the REAL kernel: this is how the pinned certificate is derived and how a changed signer shows),
# 3. the signing certificate chain is also printed as PEM with its fingerprint (sbattach --detach, openssl pkcs7), the discovery output for a pin,
# 4. `sbverify --cert <pinned certificate>` decides: exit 0 verified; exit 1 when it does not verify or when no certificate is pinned (the discovery
#    output above then names the signer; the message says what to do).
# Tools: podman (unless KERNEL_FILE), sbverify and sbattach (sbsigntool/sbsigntools), openssl.
set -euo pipefail
image=${1:?image}
cert=${2:-keys/fedora-kernel-signer.pem}
work=$(mktemp -d)
trap 'rm -rf "${work}"; [[ -z "${cid:-}" ]] || podman rm "${cid}" > /dev/null 2>&1 || true' EXIT
cid=""
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
if [[ -z "${KERNEL_FILE:-}" ]]; then
    echo "== Secure Boot certificates and packages in the image (discovery for a pin)"
    podman run --rm --entrypoint sh "${image}" -c 'ls -l /usr/share/pki/sb-certs/ 2>&1; for f in /usr/share/pki/sb-certs/*; do [ -f "$f" ] && echo "$f" && openssl x509 -inform DER -in "$f" -noout -subject -issuer -fingerprint -sha256 2>&1; done; rpm -qa | grep -i -E "shim|sb-certs|secureboot|uefi-ca" | sort; ls /usr/lib/modules/*/ | head -20' || true
fi
echo "== kernel ${kver} of ${image}: sbverify --list"
sbverify --list "${kernel}" || true
echo "== signing certificates of the kernel (PEM, for a pin)"
if sbattach --detach "${work}/sig" "${kernel}" 2> /dev/null && [[ -s "${work}/sig" ]]; then
    openssl pkcs7 -inform DER -in "${work}/sig" -print_certs 2> /dev/null || true
    openssl pkcs7 -inform DER -in "${work}/sig" -print_certs 2> /dev/null | awk '/BEGIN CERT/{n++} n{print > "'"${work}"'/c" n ".pem"}' || true
    for c in "${work}"/c*.pem; do [[ -e "${c}" ]] && openssl x509 -in "${c}" -noout -subject -fingerprint -sha256 2> /dev/null | tr '\n' ' ' && echo; done
else
    echo "(the kernel carries no signature)"
fi
if [[ ! -s "${cert}" ]]; then
    echo "::error::no certificate is pinned (${cert} missing): the kernel signer of ${image} is printed above; pin the chain's CA there with its source and fingerprint (see keys/README.md)" >&2
    exit 1
fi
if sbverify --cert "${cert}" "${kernel}"; then
    fp=$(openssl x509 -in "${cert}" -noout -fingerprint -sha256 2> /dev/null || echo "fingerprint unreadable")
    echo "Secure Boot: the kernel ${kver} of ${image} verifies against ${cert} (${fp})"
else
    echo "::error::the kernel ${kver} of ${image} does NOT verify against ${cert}: it would not boot on a Secure Boot machine (the base image changed its kernel signer or ships an unsigned kernel; the signer is printed above)" >&2
    exit 1
fi
