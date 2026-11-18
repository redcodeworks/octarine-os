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

`redcodeworks-toolbox-cosign.pub` is the cosign public key of the octarine-images repository (the owner's own project, renamed from fedora-toolbox on 2026-11-16,
`cosign.pub` at https://github.com/redcodeworks/octarine-images, copied 2026-11-09, identical to the key printed in the
README of `ghcr.io/redcodeworks/dev-packages`). Since 2026-11-16 it no longer verifies the package list images of the dx and gx variants (the lists are text files in this repository since 2026-11-18). It signs `ghcr.io/redcodeworks/datastore-images`, the opt-in datastore bundle: the dx image installs
the key as `/etc/pki/containers/redcodeworks-toolbox.pub` and a container policy rule for that repository, so `ujust datastore-install` pulls only a bundle signed with it. The same key signs the datastore box image `ghcr.io/redcodeworks/datastore`, which gets its own rule and registries.d entry next to the bundle's (`ujust datastore-box-create`). Not this image's own signing key.

Secure Boot of the kernel (no file here): `.github/scripts/secureboot-check.sh` is Bluefin's and Aurora's `secureboot` recipe. It copies `vmlinuz` out of the built image and runs
`sbverify --cert` with Universal Blue's kernel signing key, downloaded on every run from
https://github.com/ublue-os/akmods/raw/main/certs/public_key.der (DER, converted to PEM; subject `O=Universal Blue, OU=kernel signing, CN=ublue kernel`, valid until 2124,
SHA-256 fingerprint `4E:5C:68:47:4C:B1:33:FD:89:84:D9:59:97:62:CE:CE:91:00:C3:E6:CD:8A:97:09:AE:AA:BD:85:DD:9E:70:D1`). On 2026-11-14 this file was byte-identical to
`/etc/pki/akmods/certs/akmods-ublue.der` of the built image. TRUST: the key is read live from the `main` branch of a third-party repository, so whoever controls that branch
decides what passes; it is not pinned here on purpose (a pin would break at the first key rotation, and the check exists to prove the kernel matches what Universal Blue publishes).
The Fedora signature (`kernel-signer`, Fedora Secure Boot CA) is printed by `sbverify --list` but never checked. The check proves the kernel boots on machines with the Universal Blue
MOK enrolled, not on a stock Secure Boot machine. The NVIDIA kernel modules are checked differently: their `sig_key` must equal the subject key identifier of
`/etc/pki/akmods/certs/akmods-ublue.der` of the image (the key the MOK enrollment of `ujust hardware-setup` imports), see `nvidia-smoke.sh`.
