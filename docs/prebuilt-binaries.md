# Prebuilt binaries (the octarine-bins image)

The few programs the images carry that Fedora does not package (the sched_ext schedulers `scx_*`, the `extest` libraries for Steam Input on
Wayland, and Ghostty) are built in the separate repository `redcodeworks/octarine-bins`, which publishes one small signed image,
`ghcr.io/redcodeworks/octarine-bins`, with its own signing key.

This repository pins that image by digest (`BINS_DIGEST` in the `Containerfile`, next to the Homebrew pin) and verifies the pinned digest
with `keys/octarine-bins.pub` on every build; `build_files/install-binaries.sh` installs the files under `/usr`. The pin changes only through a
pull request: the weekly bump (`bump-pins.yml`) proposes the digest of `octarine-bins:latest`, or run `just bins-bump` by hand. The testing
build of that pull request is the first image build with the new binaries.

If the binaries cannot be installed, the build fails and nothing new is published. Changes to the programs, their upstream versions and the
builder happen in the octarine-bins repository. See the [main README](../README.md) for what the images ship.
