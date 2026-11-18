# Build scripts (`build_files/`)

The shell scripts that turn the Universal Blue base into this image. They are not shipped in the image: the
`Containerfile` mounts them during the build only.

- `build.sh` is the orchestrator. It runs the numbered scripts in order, one concern and one log group each: `00-image-info.sh`,
  `01-signature-policy.sh`, `04-packages.sh` (package installs and removals), `06-selinux.sh`, `07-branding.sh`, `10-binaries.sh`,
  `17-cleanup.sh` (services), `18-workarounds.sh`, `19-initramfs.sh` and `21-image-identity.sh`, then the helper scripts below. The layout and
  several scripts are derived from Bluefin's `build_files` (Apache-2.0); each derived file says so in its header.
- `install-binaries.sh` and `gen-schedulers.sh` install the prebuilt programs from the pinned octarine-bins image and generate the scheduler
  registry from their manifest.
- `install-packages.sh` installs the package lists of one image kind (the text files in `packages/default`, `packages/dx` or `packages/gx`);
  to add a package, edit the text file under `packages/<kind>/`.
- `validate-repos.sh` fails the build if an unexpected package repository is left enabled, and `final-cleanup.sh` is the
  last step, leaving nothing that `bootc container lint` complains about. The variant builds in `variants/` reuse both.

Before editing: a failing script fails the whole image build, and any change here makes the image rebuild. System-level
packages belong in `04-packages.sh` (a line in the text files under `packages/`); files that land in the image belong in `system_files/`.
