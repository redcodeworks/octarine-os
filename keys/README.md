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
