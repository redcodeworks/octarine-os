# Build configuration (`config/`)

Small `KEY=VALUE` files that name things the build needs in one place, so scripts and workflows do not repeat them.

- `image.env` holds the image name, repository, organization and description.
- `chunkah.env` pins (by digest) the tool that splits the built image into layers, so updates download less.

The `Justfile` and the build workflows (for example `build.yml`) read these files. Before editing: keep them to plain
assignments, they are parsed as text and never run as shell, and the digest in `chunkah.env` is moved by the weekly
bump workflow (`bump-pins.yml`), not by hand. The base image and Fedora release are not set here; the workflows choose them.
