# Disk image configuration (`disk_config/`)

Settings for [bootc-image-builder](https://github.com/osbuild/bootc-image-builder), the tool that turns the container image
into something you can boot or install from.

- `disk.toml` is for virtual or raw disk images (qcow2, raw): the partition layout.
- `iso.toml` is for the installer ISO: the installer modules to enable and a kickstart step that points the installed
  system at the published image.

Used by `just build-qcow2`, `just build-raw` and `just build-iso`, and by the `build-disk.yml` workflow that builds the same
images in CI. The daily image build does not read these files. The usual install is `bootc switch` from an existing
system (see the install section in the [main README](../README.md)).
