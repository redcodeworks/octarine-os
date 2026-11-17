# Image variants (`variants/`)

Build recipes for the images that sit on top of the default `octarine-os` image.

- `dx/` is the developer image: the developer toolchain, the virtual machine hosting set and thin `ujust`
  recipes that fetch the opt-in datastore bundle on demand (`ujust datastore-install`).
- `gx/` is the gamer image: the default image plus the package lists of one pinned image (`octarine-bins-gx`, from the octarine-bins
  repository, pinned by digest and split by source: Fedora, negativo17 for Steam, and the LizardByte COPR for Sunshine at an exact
  version) and a few gx-only steps. Steam is the negativo17 package (no Flatpak Steam in the image, `ujust gaming-setup` skips its
  Flatpak steps), Sunshine is installed with its user unit but not started (`systemctl --user enable --now app-dev.lizardbyte.app.Sunshine`).
  The build leaves no third-party repository enabled (negativo17 is enabled only for the install call).
- `nvidia/` adds the NVIDIA driver build.

Each has its own `Containerfile` and a setup script (`dx.sh`, `gx.sh`, `nvidia.sh`); `dx/` also carries its own `system_files/`, (the package lists of dx and gx are in the octarine-bins repository, one pinned image per variant; gx has no `system_files/`: its packages bring everything). The `build-dx.yml`, `build-gx.yml`, `build-nvidia.yml`, `build-nvidia-dx.yml` and `build-nvidia-gx.yml` workflows build them from the published
default image; dx and gx are built by the same reusable workflow and are dispatched in parallel after the default image.

Before editing: a variant only adds to the default image, so anything every user needs belongs in `build_files/` and
`system_files/`, not here. The [main README](../README.md) describes what each variant is for.
