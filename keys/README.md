# Vendored public keys

`ublue-os-brew-cosign.pub` is the cosign public key of `ghcr.io/ublue-os/brew` (Universal Blue's
files-only Homebrew image), copied from https://github.com/ublue-os/brew/blob/main/cosign.pub
(2026-11-08, long-lived key). CI verifies the digest pinned in the Containerfile against it before the
build. Not this image's own signing key (that is `cosign.pub` in the repo root). If upstream rotates
its key, verification fails: re-read the file from the URL above and compare before replacing it.

`ublue-os-main-cosign.pub` is the cosign public key of Universal Blue's `main` repository, read from
https://github.com/ublue-os/main/blob/main/cosign.pub (2026-11-09; the akmods repository carries the same key). The
NVIDIA variant build tries to verify the `akmods-nvidia-lts` image against it; it is the key the image template's
README uses in its example, and that it signs the nvidia akmods image is UNVERIFIED (a failed verification is logged
as a warning in the build, never skipped silently).

`redcodeworks-toolbox-cosign.pub` is the cosign public key of the fedora-toolbox repository (the owner's own project,
`cosign.pub` at https://github.com/redcodeworks/fedora-toolbox, copied 2026-11-09, identical to the key printed in the
README of `ghcr.io/redcodeworks/dev-packages`). It signs `ghcr.io/redcodeworks/dev-packages`, the developer package list
the `octarine-os-dx` image installs; `build-dx.yml` verifies the digest pinned in `variants/dx/Containerfile` against it
before every build and `just dev-packages-bump` verifies a new digest with it. Not this image's own signing key.

`fedora-kernel-signer.pem` is the certificate that signs the kernel of the default image for Secure Boot: Fedora's `kernel-signer` (subject
`/C=US/ST=Massachusetts/L=Cambridge/O=Red Hat, Inc./OU=Fedora Secure Boot Signer/OU=bkernel01 kernel/CN=kernel-signer`, issuer `Fedora Secure Boot CA 20200709`
(`CN=fedoraca`), valid until 2037-01-19, SHA-256 fingerprint
`01:BF:41:E5:46:87:72:FE:A3:5A:13:CC:D5:D6:E0:95:69:54:93:5F:60:4E:05:23:E6:72:C2:83:48:8B:37:8E`). Source: derived from the REAL kernel of the base image on
2026-11-14 (kernel 7.3.3-300.fc45, `/usr/lib/modules/<kver>/vmlinuz` of `octarine-os:testing` built on `silverblue-main:45`): `sbverify --list` showed two
signatures (Fedora's `kernel-signer` under the Fedora Secure Boot CA, which the shim of every Secure Boot machine trusts, and Universal Blue's own
`ublue kernel` key, which would need a MOK enrollment), and `sbattach --detach` plus `openssl pkcs7 -print_certs` printed the first certificate that was pinned
here. `.github/scripts/secureboot-check.sh` runs `sbverify --cert` with it on every built image and FAILS the build when the kernel does not verify. LIMIT: this is the
LEAF certificate of one Fedora signing builder (bkernel01); Fedora has signed kernels with other builder certificates, and if a future kernel comes with another
leaf under the same CA the check fails loudly: compare the signer printed by the script, then replace this file (the CA certificate itself, `Fedora Secure Boot CA
20200709`, is not in the image: `/usr/share/pki/sb-certs` does not exist there; pinning it from Fedora's shim package is an open item for the hub). The NVIDIA kernel
modules are checked differently: their `sig_key` must equal the subject key identifier of `/etc/pki/akmods/certs/akmods-ublue.der` of the image (the key the MOK
enrollment of `ujust hardware-setup` imports), see `nvidia-smoke.sh`.
