# shellcheck shell=bash
# Shared helpers of `ujust datastore` and `ujust datastore-setup` (dx image only). Sourced, never run. Rootless only: it needs no
# privileges, and the recipes refuse root. Paths can be moved with DATASTORE_* variables for the tests.

DS_QUADLET_DIR=${DATASTORE_QUADLET_DIR:-/usr/share/containers/systemd/users}
DS_USER_DIR=${DATASTORE_USER_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/containers/systemd}
DS_SERVICES="postgresql valkey seaweedfs kafka"
DS_VOLUMES="postgresql-data valkey-data seaweed-data kafka-data"
DS_SECRETS_DATASTORE="postgresql-password valkey-password seaweedfs-s3-config"

ds_known_service() { case " ${DS_SERVICES} " in *" $1 "*) return 0 ;; esac; return 1; }
# the container name and the systemd unit of a service, and the pod unit it belongs to
ds_container() { case "$1" in postgresql) echo pgsql ;; *) echo "$1" ;; esac; }
ds_unit() { echo "$1.service"; }
ds_pod_unit() { case "$1" in kafka) echo kafka-pod.service ;; *) echo datastore-pod.service ;; esac; }
ds_dropin() { echo "${DS_USER_DIR}/$1.container.d/10-image.conf"; }

# ds_shipped_image <service>: the Image= of the shipped Quadlet (tag and digest included)
ds_shipped_image() { sed -n 's/^Image=//p' "${DS_QUADLET_DIR}/$1.container" 2> /dev/null | head -n1; }
# ds_override_image <service>: the Image= of the user's drop-in, empty when there is none
ds_override_image() { local f; f=$(ds_dropin "$1"); if [[ -f "${f}" ]]; then sed -n 's/^Image=//p' "${f}" | tail -n1; fi; }
ds_effective_image() { local o; o=$(ds_override_image "$1"); echo "${o:-$(ds_shipped_image "$1")}"; }
# the registry path without tag and digest, and the major version of the tag (17.12-alpine -> 17)
ds_image_path() { local i=${1%%@*}; echo "${i%:*}"; }
ds_image_tag() { local i=${1%%@*}; echo "${i##*:}"; }
ds_image_major() { local t; t=$(ds_image_tag "$1"); echo "${t%%.*}"; }

ds_secret_exists() { podman secret inspect "$1" > /dev/null 2>&1; }
ds_missing_secrets() { local s; for s in ${DS_SECRETS_DATASTORE}; do ds_secret_exists "${s}" || echo "${s}"; done; }

# ds_pg_data_major: the PG_VERSION of the data volume (read in podman's user namespace, where the files of the container user are
# readable); empty when the volume does not exist or holds no cluster yet
ds_pg_data_major() {
    local mp
    podman volume exists postgresql-data 2> /dev/null || return 0
    mp=$(podman volume inspect postgresql-data --format '{{.Mountpoint}}' 2> /dev/null) || return 0
    [[ -n "${mp}" ]] || return 0
    podman unshare cat "${mp}/pgdata/PG_VERSION" 2> /dev/null | head -n1 | tr -d '[:space:]'
}
# ds_pg_guard: refuse (1) when the data's major differs from the image's major, with the dump and restore message
ds_pg_guard() {
    local data image_major
    data=$(ds_pg_data_major)
    [[ -n "${data}" ]] || return 0
    image_major=$(ds_image_major "$(ds_effective_image postgresql)")
    if [[ "${data%%.*}" != "${image_major}" ]]; then
        echo "Refusing to start PostgreSQL: the data volume is PostgreSQL ${data%%.*}, the image is ${image_major}." >&2
        echo "A major version needs a dump and restore (pg_dumpall with the old version, then restore into a new volume) or pg_upgrade;" >&2
        echo "starting the new server on old data would fail. Pin the old tag instead: ujust datastore-setup --pin postgresql=<${data%%.*}.x tag>" >&2
        return 1
    fi
    return 0
}
