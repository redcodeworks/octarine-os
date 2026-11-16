# Documentation

Longer reading that does not belong in the main README. For what the image contains, how to install it and how to fork it,
start with the [main README](../README.md).

- [`CONFIG-GUIDE.md`](CONFIG-GUIDE.md): a tour of the desktop setup that goes with the image, a list of ideas to borrow.

What each top-level directory is for:

- [`build-scripts.md`](build-scripts.md): `build_files/`, the scripts that build the image.
- [`system-files.md`](system-files.md): `system_files/`, the files copied into the image.
- [`image-variants.md`](image-variants.md): `variants/`, the developer and NVIDIA images.
- [`prebuilt-binaries.md`](prebuilt-binaries.md): `binaries/`, the programs built separately and shipped in the images.
- [`config-files.md`](config-files.md): `config/`, shared build settings.
- [`ci-workflows.md`](ci-workflows.md): `.github/`, the workflows and scripts, and how a change reaches `main`.
- [`git-hooks.md`](git-hooks.md): `githooks/`, optional hooks for a local clone.
- [`docs/signing-keys.md`](signing-keys.md): `keys/`, the vendored public keys and where each came from.

Before editing: pushes that touch only the documentation (this folder and the top-level Markdown files) do not trigger an
image build.
