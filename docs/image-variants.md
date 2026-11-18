# Image variants (`variants/`)

Build recipes for the images that sit on top of the default `octarine-os` image.

- `dx/` is the developer image: the developer toolchain, the virtual machine hosting set and thin `ujust`
  recipes that fetch the opt-in datastore bundle on demand (`ujust datastore-install`), and the recipes of the datastore box (below).
- `gx/` is the gamer image: the default image plus its package lists (`packages/gx`, text files split by source: Fedora,
  negativo17 for Steam, and the LizardByte COPR for Sunshine at an exact version) and a few gx-only steps. Steam is the negativo17 package (no Flatpak Steam in the image, `ujust gaming-setup` skips its
  Flatpak steps), Sunshine is installed with its user unit but not started (`systemctl --user enable --now app-dev.lizardbyte.app.Sunshine`).
  The build leaves no third-party repository enabled (negativo17 is enabled only for the install call).
- `nvidia/` adds the NVIDIA driver build.
- The experimental `octarine-os-dx-gx` (alias `fx`) has no directory of its own: it is the `gx/` layer built on `octarine-os-dx` instead of the default image (layering order: default, dx, gx). It is large (the sum of both layers) and only built on request.
  Known limitation: on such a machine the NVIDIA step of `ujust hardware-setup` moves to `octarine-os-nvidia-dx` and drops the gx layer, because `octarine-os-nvidia-dx-gx` does not exist. Undo: `sudo bootc rollback`, or `ujust switch-image dx-gx`.

Each has its own `Containerfile` and a setup script (`dx.sh`, `gx.sh`, `nvidia.sh`); `dx/` also carries its own `system_files/`, (the package lists of dx and gx are the text files in `packages/dx` and `packages/gx`; gx has no `system_files/`: its packages bring everything). The `build-dx.yml`, `build-gx.yml`, `build-nvidia.yml`, `build-nvidia-dx.yml`, `build-nvidia-gx.yml` and (experimental, dispatch only) `build-dx-gx.yml` workflows build them from the published
default image; dx and gx are built by the same reusable workflow and are dispatched in parallel after the default image.

Before editing: a variant only adds to the default image, so anything every user needs belongs in `build_files/` and
`system_files/`, not here. The [main README](../README.md) describes what each variant is for.

## Datastore box (dx image, opt-in)

The datastore box is ONE distrobox with its own systemd that runs PostgreSQL 17, Valkey, SeaweedFS and Kafka as ordinary units on the host's `lakehouse` podman network, under the
aliases `pgsql`, `postgresql`, `valkey`, `seaweedfs` and `kafka`. The dx image ships the recipe that creates it and the signature rule that lets the host pull its image
(`ghcr.io/redcodeworks/datastore`, built and signed in the octarine-images repository, which also documents the `datastore` command inside the box).

- `ujust datastore-box-create` makes sure the `lakehouse` network exists, then runs `distrobox assemble` on `/usr/share/octarine-os/datastore/datastore.ini`. Nothing changes if the box exists.
- `ujust datastore-box VERB ...` runs `datastore VERB ...` inside the box: `setup`, `start|stop|restart [NAME]`, `enable|disable`, `status`, `logs NAME`, `psql`, `valkey-cli`,
  `secrets list|show|export [--replace]`, `backup DIR [--stop]`, `restore FILE`, `render DIR`. `--help` lists them.
- It lives beside the older container recipes (`datastore-install`, `datastore`, `datastore-setup`), which are unchanged. The two stacks use the same ports and network aliases: run one.

Cutover from the container recipes (by hand, in this order; not tested against real data):

1. `ujust datastore-setup --backup`, to have a backup of the old stack.
2. Stop the old pods (`systemctl --user stop datastore-pod kafka-pod`).
3. `ujust datastore-box-create`, then `ujust datastore-box setup`, then `ujust datastore-box start`.
4. `ujust datastore-box restore FILE` with the PostgreSQL dump.
5. Stop the service (for example `ujust datastore-box stop valkey`) and copy the old SeaweedFS, Kafka and Valkey directories into `~/.local/share/datastore`, then start it again.
6. `ujust datastore-box secrets export --replace` re-creates the host podman secrets under their old names (without `--replace` a live secret is never overwritten).
7. Start the containers that depend on the datastore.

Undo: `distrobox rm --force datastore`; the data stays in `~/.local/share/datastore` and `~/.config/datastore`.
