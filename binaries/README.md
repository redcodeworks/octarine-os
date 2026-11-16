# Prebuilt binaries

Sources and build recipes for the few programs the images carry that Fedora does not package: the sched_ext
schedulers (`scx`), the `extest` libraries for Steam Input on Wayland and, optionally, Ghostty. Each component has its own
folder with a `Containerfile`, a `build.sh` and an `upstream.env` that pins the upstream version.

`.github/workflows/binaries.yml` builds the components, publishes them as one small image, and the image build copies that
image's contents in (`build_files/install-binaries.sh`). `components.tsv` lists the components and whether each is required;
`builder.env` pins the Fedora builder image they all compile in; `lib/` holds the shared fetch, stage and assemble scripts.

Before editing: the upstream pins here are moved by the weekly bump workflow (`bump-pins.yml`), and a change inside a component, in `lib/` or in
`builder.env` rebuilds the affected components (a change in `lib/` or `builder.env` rebuilds all of them).
See the [main README](../README.md) for what the images ship.
