# The datastore BOX (dx only): the newer way to run PostgreSQL 17, Valkey, SeaweedFS and Kafka, as ONE distrobox with its own systemd. It lives beside the
# older Quadlet recipes (`datastore-install`, `datastore`, `datastore-setup` in 72-octarine-datastore.just), which are not changed. Nothing here touches the
# Quadlet stack: the two must not run at the same time (same ports and network aliases).
# Cutover from the Quadlets, in this order (by hand, not automatic):
#   1. ujust datastore-setup --backup                  back up the old stack
#   2. stop the Quadlet pods (systemctl --user stop datastore-pod kafka-pod; the unit names are in the old bundle's README)
#   3. ujust datastore-box-create                      create the box (also makes the `lakehouse` network if it is missing)
#   4. ujust datastore-box setup                       once: directories, passwords, config, units
#   5. ujust datastore-box restore FILE                load the PostgreSQL dump
#   6. copy the old SeaweedFS, Kafka and Valkey directories into ~/.local/share/datastore (stop the service first: ujust datastore-box stop valkey)
#   7. ujust datastore-box secrets export --replace    re-create the host podman secrets under their old names
#   8. start the containers that depend on the datastore
# Undo of the box: distrobox rm --force datastore (the data stays in ~/.local/share/datastore and ~/.config/datastore).

# Create the datastore box (a distrobox; needs the lakehouse network, --help)
[group('Datastore box')]
[positional-arguments]
datastore-box-create *args:
    #!/usr/bin/env bash
    set -uo pipefail
    ini="${DATASTORE_BOX_INI:-/usr/share/octarine-os/datastore/datastore.ini}"
    box="${DATASTORE_BOX:-datastore}"
    case "${1:-}" in
        "") ;;
        -h | --help | help)
            echo "Usage: ujust datastore-box-create"
            echo "Creates the distrobox '$box' (image ghcr.io/redcodeworks/datastore:latest, checked by the container signature policy) from $ini."
            echo "First makes sure the podman network 'lakehouse' exists. The box runs its own systemd; PostgreSQL, Valkey, SeaweedFS and Kafka are units inside it."
            echo "Next: ujust datastore-box setup. This is separate from the older Quadlet recipes (ujust datastore-install); do not run both stacks at once."
            echo "Nothing is changed when the box already exists. Undo: distrobox rm --force $box (the data stays in your home)."
            exit 0 ;;
        *) echo "Usage: ujust datastore-box-create" >&2; exit 2 ;;
    esac
    if [ "$(id -u)" = 0 ]; then echo "Refused: run this as your user, not as root: the datastore box is rootless." >&2; exit 1; fi
    command -v podman >/dev/null 2>&1 || { echo "Failed: podman is not installed." >&2; exit 1; }
    command -v distrobox >/dev/null 2>&1 || { echo "Failed: distrobox is not installed." >&2; exit 1; }
    [ -r "$ini" ] || { echo "Failed: $ini is missing (this recipe is part of the dx image)." >&2; exit 1; }
    if podman container exists "$box"; then
        echo "The box '$box' already exists; nothing changed. Next: ujust datastore-box setup (undo: distrobox rm --force $box)."
        exit 0
    fi
    if ! podman network exists lakehouse; then
        echo "Creating the podman network 'lakehouse' (undo: podman network rm lakehouse)"
        podman network create lakehouse || { echo "Failed: could not create the lakehouse network." >&2; exit 1; }
    fi
    echo "Creating the box '$box' from $ini"
    distrobox assemble create --file "$ini" </dev/null || { echo "Failed: distrobox assemble failed (network, or the container signature policy rejected the image)." >&2; exit 1; }
    echo "Done: the box '$box' exists. Next: ujust datastore-box setup (undo: distrobox rm --force $box)"

# Run a datastore box command: setup, start, stop, status, psql, backup ... (--help)
[group('Datastore box')]
[positional-arguments]
datastore-box *args:
    #!/usr/bin/env bash
    set -uo pipefail
    box="${DATASTORE_BOX:-datastore}"
    usage() {
        echo "Usage: ujust datastore-box VERB [ARGS...]"
        echo "Runs 'datastore VERB ARGS' inside the datastore box '$box' (create it first: ujust datastore-box-create)."
        echo "Verbs: setup | start|stop|restart [postgres|valkey|seaweedfs|kafka|datastore|all] | enable|disable | status | logs NAME"
        echo "       psql | valkey-cli | secrets list|show|export [--replace] | backup DIR [--stop] | restore FILE | render DIR"
        echo "This is separate from the older Quadlet recipes (ujust datastore, datastore-setup); do not run both stacks at once."
    }
    case "${1:-}" in
        "" | -h | --help | help) usage; exit 0 ;;
        setup | start | stop | restart | enable | disable | status | logs | psql | valkey-cli | secrets | backup | restore | render) ;;
        *) echo "Unknown verb '$1'." >&2; usage >&2; exit 2 ;;
    esac
    if [ "$(id -u)" = 0 ]; then echo "Refused: run this as your user, not as root: the datastore box is rootless." >&2; exit 1; fi
    command -v podman >/dev/null 2>&1 || { echo "Failed: podman is not installed." >&2; exit 1; }
    command -v distrobox >/dev/null 2>&1 || { echo "Failed: distrobox is not installed." >&2; exit 1; }
    podman container exists "$box" || { echo "Needs: the datastore box '$box' does not exist yet. Run: ujust datastore-box-create" >&2; exit 1; }
    exec distrobox enter "$box" -- datastore "$@"
