# Fetch the signed datastore bundle and install its user Quadlets (dx only)
[group('Setup')]
[positional-arguments]
datastore-install *args:
    #!/usr/bin/env bash
    set -uo pipefail
    case "${1:-}" in
        -h | --help | help) echo "Usage: ujust datastore-install [--digest sha256:<64 hex>]"; echo "Pulls ${DATASTORE_BUNDLE_REF:-ghcr.io/redcodeworks/datastore-images:latest} (signature checked by the container policy), unpacks it into ~/.local/share/octarine-os/datastore and runs its install step (user Quadlets in ~/.config/containers/systemd). Undo: ujust datastore uninstall"; exit 0 ;;
    esac
    if [ "$(id -u)" = 0 ]; then echo "Run this as your user, not as root: the datastore is rootless." >&2; exit 1; fi
    ref=${DATASTORE_BUNDLE_REF:-ghcr.io/redcodeworks/datastore-images:latest}
    case "${1:-}" in
        "") ;;
        --digest) [[ "${2:-}" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "Usage: ujust datastore-install [--digest sha256:<64 hex>]" >&2; exit 2; }
            repo=${ref%@*}; [[ "${repo##*/}" != *:* ]] || repo=${repo%:*}; ref="$repo@$2" ;;
        *) echo "Usage: ujust datastore-install [--digest sha256:<64 hex>]" >&2; exit 2 ;;
    esac
    command -v podman >/dev/null 2>&1 || { echo "podman is not installed." >&2; exit 1; }
    dir=${DATASTORE_BUNDLE_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/octarine-os/datastore}
    mkdir -p "$(dirname "$dir")" || exit 1
    tmp=$(mktemp -d "$dir.new.XXXXXX") || exit 1
    cid=
    cleanup() { [ -z "$cid" ] || podman rm "$cid" >/dev/null 2>&1; rm -rf "$tmp"; }
    trap cleanup EXIT
    echo "Pulling $ref"
    podman pull "$ref" || { echo "The pull failed (network, or the container signature policy rejected it)." >&2; exit 1; }
    cid=$(podman create "$ref" /images.txt) || { echo "podman create failed." >&2; exit 1; }
    podman export "$cid" | tar -x -C "$tmp" || { echo "Unpacking the bundle failed." >&2; exit 1; }
    if [ ! -x "$tmp/bin/datastore" ]; then
        echo "$ref is the old image list without bin/datastore: the bundle is not published under this tag yet. Try again after the fedora-toolbox release, or pick a newer one with --digest." >&2
        exit 1
    fi
    old=
    if [ -e "$dir" ]; then old="$dir.old.$$"; mv "$dir" "$old" || exit 1; fi
    if ! mv "$tmp" "$dir"; then [ -z "$old" ] || mv "$old" "$dir"; echo "Could not move the bundle into place." >&2; exit 1; fi
    [ -z "$old" ] || rm -rf "$old"
    echo "Bundle unpacked in $dir (undo: ujust datastore uninstall, then rm -rf $dir)"
    DATASTORE_UJUST=1 "$dir/bin/datastore" install

# Start, stop and inspect the datastore containers (bundle from datastore-install)
[group('Setup')]
[positional-arguments]
datastore *args:
    #!/usr/bin/env bash
    set -uo pipefail
    if [ "$(id -u)" = 0 ]; then echo "Run this as your user, not as root: the datastore is rootless." >&2; exit 1; fi
    bin=${DATASTORE_BUNDLE_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/octarine-os/datastore}/bin/datastore
    [ -x "$bin" ] || { echo "The datastore bundle is not installed yet. Run: ujust datastore-install" >&2; exit 1; }
    DATASTORE_UJUST=1 exec "$bin" "$@"

# Set up the datastore containers: secrets, pins, update, backup (--help)
[group('Setup')]
[positional-arguments]
datastore-setup *args:
    #!/usr/bin/env bash
    set -uo pipefail
    if [ "$(id -u)" = 0 ]; then echo "Run this as your user, not as root: the datastore is rootless." >&2; exit 1; fi
    bin=${DATASTORE_BUNDLE_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/octarine-os/datastore}/bin/datastore
    [ -x "$bin" ] || { echo "The datastore bundle is not installed yet. Run: ujust datastore-install" >&2; exit 1; }
    DATASTORE_UJUST=1 exec "$bin" setup "$@"
