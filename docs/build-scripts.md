# Build scripts (`build_files/`)

The shell scripts that turn the Universal Blue base into this image. They are not shipped in the image: the
`Containerfile` mounts them during the build only.

- `build.sh` is the main script: package installs and removals, enabling services, and the rest of the image setup.
- `install-binaries.sh` and `gen-schedulers.sh` install the prebuilt programs from `binaries/` and generate the scheduler
  registry from their manifest.
- `validate-repos.sh` fails the build if an unexpected package repository is left enabled, and `final-cleanup.sh` is the
  last step, leaving nothing that `bootc container lint` complains about. The variant builds in `variants/` reuse both.

Before editing: a failing script fails the whole image build, and any change here makes the image rebuild. System-level
packages belong in `build.sh`; files that land in the image belong in `system_files/`.
