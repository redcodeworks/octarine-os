# Prebuilt binaries (`binaries/`)

Sources and build recipes for the few programs the images carry that Fedora does not package: the sched_ext
schedulers (`scx`), the `extest` libraries for Steam Input on Wayland and Ghostty. Each component has its own
folder with a `Containerfile`, a `build.sh` and an `upstream.env` that pins the upstream version.

`.github/workflows/binaries.yml` builds the components on `testing` and publishes them as one small image, `ghcr.io/redcodeworks/octarine-binaries:testing`.
Merging `testing` into `main` retags that tested image to `latest` (no rebuild; it fails if `testing` does not hold the build of the same `binaries/` content), and the image build installs
whatever `latest` is when it runs (`build_files/install-binaries.sh`). `components.tsv` lists the components and whether each is required;
`builder.env` pins the Fedora builder image they all compile in; `lib/` holds the shared fetch, stage and assemble scripts.

If a component (`scx`, `extest` or `ghostty`) cannot be built, the run fails and nothing is promoted: `latest` keeps the previous binaries. If Ghostty becomes a blocker, pin a Ghostty tag that builds in `ghostty/upstream.env`, or remove the component from the image (its line in `components.tsv`, its directory and its entries in `build_files/install-binaries.sh`).

Before editing: the upstream pins here are moved by the weekly bump workflow (`bump-pins.yml`), and a change inside a component, in `lib/` or in
`builder.env` rebuilds the affected components (a change in `lib/` or `builder.env` rebuilds all of them).
See the [main README](../README.md) for what the images ship.
