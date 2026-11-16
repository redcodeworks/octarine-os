# Image variants (`variants/`)

Build recipes for the images that sit on top of the default `octarine-os` image.

- `dx/` is the developer image: the developer toolchain, the virtual machine hosting set and thin `ujust`
  recipes that fetch the opt-in datastore bundle on demand (`ujust datastore-install`).
- `nvidia/` adds the NVIDIA driver build.

Each has its own `Containerfile` and a setup script (`dx.sh`, `nvidia.sh`); `dx/` also carries its own `system_files/`
and `packages/` list. The `build-dx.yml`, `build-nvidia.yml` and `build-nvidia-dx.yml` workflows build them from the published default image.

Before editing: a variant only adds to the default image, so anything every user needs belongs in `build_files/` and
`system_files/`, not here. The [main README](../README.md) describes what each variant is for.
