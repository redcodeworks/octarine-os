#!/usr/bin/env bash
# Tests for the opt-in datastore Quadlets of the dx image and their recipes `ujust datastore` and `ujust datastore-setup`:
# the pin file and the rendered Quadlets (exact tags, digests, agreement with the file, no [Install], no AutoUpdate, loopback ports
# above 1023, no host paths, no secret values), the no-privilege-prompt rule, secrets, pins and drop-ins, status, the PostgreSQL data
# major guard, backups, start and stop, and the dx wiring. podman, systemctl and journalctl are fakes; nothing real is created.
# Needs: bash, just. Run: tests/datastore.sh
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
dsdir="$here/variants/dx/datastore"
rjust="$here/variants/dx/system_files/usr/share/ublue-os/just/72-octarine-datastore.just"
dslib="$here/variants/dx/system_files/usr/share/octarine-os/lib/datastore.sh"
root=$(mktemp -d)
trap 'rm -rf -- "${root:?}"' EXIT
pass=0
failn=0
rc=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { failn=$((failn + 1)); echo "FAIL $1"; sed 's/^/     /' "$root/out" 2>/dev/null; echo "     rc=$rc"; }
check() { local d=$1; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
has() { grep -qF -- "$1" "$root/out"; }
logged() { grep -qF -- "$1" "$root/log" 2>/dev/null; }
notlogged() { ! grep -qF -- "$1" "$root/log" 2>/dev/null; }

# ---- the pin file and the rendered Quadlets
rq="$root/quadlets"
"$dsdir/render.sh" "$rq" >"$root/out" 2>&1; rc=$?
check "render: runs on the real pin file" test "$rc" = 0
expected="datastore.pod kafka-data.volume kafka.container kafka.pod lakehouse.network postgresql-data.volume postgresql.container seaweed-data.volume seaweedfs.container valkey-data.volume valkey.container"  # C locale order
check "render: exactly the pods, containers, network and volumes of the brief (no airflow, connect, superset, trino, lakekeeper, dvdrental)" test "$(LC_ALL=C ls "$rq" | tr '\n' ' ')" = "$expected "
for svc in postgresql valkey seaweedfs kafka; do
    upper=$(echo "$svc" | tr a-z A-Z)
    image=$(sed -n "s/^${upper}_IMAGE=//p" "$dsdir/datastore.env"); tag=$(sed -n "s/^${upper}_TAG=//p" "$dsdir/datastore.env")
    digest=$(sed -n "s/^${upper}_DIGEST=//p" "$dsdir/datastore.env"); major=$(sed -n "s/^${upper}_MAJOR=//p" "$dsdir/datastore.env")
    check "pins: $svc Image= in the Quadlet is exactly <image>:<tag>@<digest> of datastore.env" grep -qx "Image=${image}:${tag}@${digest}" "$rq/$svc.container"
    check "pins: $svc tag '$tag' is exact (digits, dots, an optional -suffix), not latest, in major $major" bash -c "[[ '$tag' =~ ^[0-9]+(\\.[0-9]+)+(-[a-z0-9.]+)?\$ ]] && [ '$tag' != latest ] && [ \"\${tag%%.*}\" = '$major' ] || [ '${tag%%.*}' = '$major' ]"
    check "pins: $svc digest is sha256 plus 64 hex" bash -c "[[ '$digest' =~ ^sha256:[0-9a-f]{64}\$ ]]"
    check "pins: the shipped $svc.container has one Image= line and no other image reference" bash -c "[ \$(grep -c '^Image=' '$rq/$svc.container') = 1 ]"
done
check "pins: no Quadlet image is latest, unversioned or from a local registry" bash -c "! grep -hE '^Image=' '$rq'/*.container | grep -E ':latest|localhost/|^Image=[^:]*\$'"
check "no Quadlet has an [Install] section, so nothing starts by itself" bash -c "! grep -l '^\\[Install\\]' '$rq'/*"
check "no shipped stateful unit has AutoUpdate= (no unattended image changes)" bash -c "! grep -l '^AutoUpdate=' '$rq'/*"
check "no host-specific path or user specifier in the Quadlets (/home, %h, /var/home, .local/share)" bash -c "! grep -E '/home/|%h|/var/home|\\.local/share|kevin' '$rq'/*"
check "no secret value in the Quadlets: passwords come from Secret= and *_FILE only" bash -c "! grep -iE '(PASSWORD|SECRET|ACCESS_KEY)=[^/ ]' '$rq'/* | grep -v 'POSTGRES_PASSWORD_FILE=/run/secrets/'; grep -q '^Secret=postgresql-password' '$rq/postgresql.container' && grep -q '^Secret=valkey-password' '$rq/valkey.container' && grep -q '^Secret=seaweedfs-s3-config,type=mount' '$rq/seaweedfs.container'"
check "ports: every PublishPort is bound to 127.0.0.1 and the host port is above 1023" bash -c "grep -h '^PublishPort=' '$rq'/*.pod | awk -F'[=:]' '{ if (\$2 != \"127.0.0.1\" || \$3 < 1024) bad=1 } END { exit bad }' && [ \$(grep -h '^PublishPort=' '$rq'/*.pod | wc -l) = 6 ]"
check "ports: the datastore pod publishes 5432 6379 8333 9333 8889 and kafka 9092" bash -c "for p in 5432:5432 6379:6379 8333:8333 9333:9333 8889:8888; do grep -q \"PublishPort=127.0.0.1:\$p\" '$rq/datastore.pod' || exit 1; done; grep -q 'PublishPort=127.0.0.1:9092:9092' '$rq/kafka.pod'"
check "the pods and containers join the lakehouse network; the dvdrental network is not referenced" bash -c "grep -q '^Network=lakehouse.network' '$rq/datastore.pod' '$rq/kafka.pod' && ! grep -rq dvdrental '$rq'"
check "volumes are named podman volumes with the local driver" bash -c "for v in postgresql seaweed valkey kafka; do grep -qx \"VolumeName=\$v-data\" '$rq'/\$v-data.volume && grep -qx 'Driver=local' '$rq'/\$v-data.volume || exit 1; done"
check "no sudo, pkexec or run0 in any Quadlet, recipe file, helper, render script or in the CLAUDE.md datastore section" bash -c "! grep -E '(sudo|pkexec|run0)' '$rq'/* '$rjust' '$dslib' '$dsdir/render.sh' '$dsdir/datastore.env' && ! awk '/^## Datastore containers/{f=1;next} /^## /{f=0} f' '$here/CLAUDE.md' | grep -E '(sudo|pkexec|run0)'"
# render must refuse bad pins
mkdir -p "$root/bad"
bad_render() { # description, sed expression
    local d=$1 e=$2
    rm -rf "${root:?}/bad"; mkdir -p "$root/bad"; cp -r "$dsdir/quadlets" "$root/bad/quadlets"; sed "$e" "$dsdir/datastore.env" >"$root/bad/datastore.env"
    "$dsdir/render.sh" "$root/bad-out" "$root/bad" >"$root/out" 2>&1; rc=$?
    check "render refuses $d" test "$rc" != 0
}
bad_render "a latest tag" 's/^VALKEY_TAG=.*/VALKEY_TAG=latest/'
bad_render "a floating major tag" 's/^POSTGRESQL_TAG=.*/POSTGRESQL_TAG=17-alpine/'
bad_render "a bad digest" 's/^KAFKA_DIGEST=.*/KAFKA_DIGEST=sha256:abc/'
bad_render "a tag outside its major" 's/^SEAWEEDFS_TAG=.*/SEAWEEDFS_TAG=4.1/'
bad_render "a missing pin" '/^KAFKA_DIGEST=/d'
check "the dx image tree ships no kargs.d file (iommu=pt is opt-in now)" test ! -e "$here/variants/dx/system_files/usr/lib/bootc/kargs.d/10-iommu.toml"
check "dx.sh renders the Quadlets into /usr/share/containers/systemd/users, checks there is no [Install], imports the recipe file; the Containerfile copies the datastore directory" bash -c "grep -q 'render.sh /usr/share/containers/systemd/users /ctx/datastore' '$here/variants/dx/dx.sh' && grep -q 'grep -rq .^.\\[Install' '$here/variants/dx/dx.sh' && grep -q '72-octarine-datastore.just' '$here/variants/dx/dx.sh' && grep -q 'COPY variants/dx/datastore /datastore' '$here/variants/dx/Containerfile'"
check "the datastore recipes exist only in the dx tree: the default image's recipe files define neither" bash -c "! grep -E '^datastore' '$here/system_files/usr/share/ublue-os/just/'*.just"

# ---- stubs for the recipes
bin="$root/bin"; sysbin="$root/sysbin"; mkdir -p "$bin" "$sysbin" "$root/secrets" "$root/home"
for c in bash sh env cat grep awk sed cut tr date head sort dirname basename wc chmod printf mkdir mktemp mv rm ls touch base64 tee cmp id uname true tail rmdir stat; do
    p=$(command -v "$c") && ln -sf "$p" "$sysbin/$c"
done
rm -f "${sysbin:?}/id"
REAL_JUST=$(command -v just)
export LOG="$root/log" HOME="$root/home" OCTARINE_DATASTORE_LIB="$dslib" OCTARINE_MENU_LIB="$here/system_files/usr/share/octarine-os/lib/menu.sh"
export DATASTORE_QUADLET_DIR="$rq" DATASTORE_USER_DIR="$root/home/.config/containers/systemd" SECRETS="$root/secrets" VOLS="$root/vols"
unset XDG_CONFIG_HOME
cat >"$bin/podman" <<'F'
#!/usr/bin/env bash
echo "podman $*" >>"$LOG"
case "$1 $2" in
    "secret inspect") [ -f "$SECRETS/$3" ]; exit $? ;;
    "secret create")
        [ "${FAKE_SECRET_FAIL:-}" = "$3" ] && { cat >/dev/null; exit 1; }
        cat >"$SECRETS/$3"; exit 0 ;;
    "volume exists") [ -d "$VOLS/$3" ]; exit $? ;;
    "volume inspect") echo "$VOLS/$3/_data"; exit 0 ;;
    "volume export")
        [ "${FAKE_EXPORT_FAIL:-}" = "$3" ] && exit 1
        echo "tar of $3" >"${5}"; exit 0 ;;
    "info --format") echo "${FAKE_GRAPHROOT:-/mnt/data/containers/storage}"; exit 0 ;;
    "unshare cat") cat "$3" 2>/dev/null; exit $? ;;
    "unshare du") echo "12M	$4"; exit 0 ;;
    "exec pgsql") echo "-- pg_dumpall output"; exit 0 ;;
    "pull "*) [ "${FAKE_PULL_FAIL:-}" = 1 ] && exit 1; exit 0 ;;
esac
case "$1" in
    inspect)
        c=$2
        case "$*" in
            *State.Status*) for r in $RUNNING; do [ "$r" = "$c" ] && { echo running; exit 0; }; done; exit 1 ;;
            *ImageName*) for r in $RUNNING; do [ "$r" = "$c" ] && { echo "running-image-of-$c"; exit 0; }; done; exit 1 ;;
        esac ;;
esac
exit 0
F
cat >"$bin/systemctl" <<'F'
#!/usr/bin/env bash
echo "systemctl $*" >>"$LOG"
[ "$1" = --user ] || exit 99
case "$2" in
    is-active) for a in $ACTIVE; do [ "$a" = "$3" ] && { echo active; exit 0; }; done; echo inactive; exit 3 ;;
    start) [ "${FAKE_START_FAIL:-}" = 1 ] && exit 1; exit 0 ;;
    stop|daemon-reload) exit 0 ;;
esac
exit 0
F
cat >"$bin/journalctl" <<'F'
#!/usr/bin/env bash
echo "journalctl $*" >>"$LOG"
exit 0
F
cat >"$bin/id" <<'F'
#!/usr/bin/env bash
[ "$1" = -u ] && { echo "${FAKE_UID:-1000}"; exit 0; }
exit 0
F
chmod +x "$bin"/*
export RUNNING="" ACTIVE=""
reset() {
    rm -rf "${root:?}/secrets" "${root:?}/vols" "${root:?}/home/.config"; mkdir -p "$root/secrets" "$root/vols" "$root/home"
    : >"$LOG"; export RUNNING="" ACTIVE=""; unset FAKE_UID FAKE_SECRET_FAIL FAKE_EXPORT_FAIL FAKE_PULL_FAIL FAKE_START_FAIL FAKE_GRAPHROOT
}
run() { # recipe, args...
    local r=$1; shift
    PATH="$bin:$sysbin" "$REAL_JUST" --justfile "$rjust" --working-directory "$root" "$r" "$@" >"$root/out" 2>&1 </dev/null
    rc=$?
}
mkvol() { mkdir -p "$VOLS/$1/_data"; }
allsecrets() { for s in postgresql-password valkey-password seaweedfs-s3-config; do echo x >"$SECRETS/$s"; done; }

# ---- shape
reset; run datastore --help
check "datastore --help: usage, exit 0, names start stop status logs" bash -c "[ $rc = 0 ] && grep -q 'start' '$root/out' && grep -q 'status' '$root/out' && grep -q 'logs' '$root/out'"
reset; run datastore-setup --help
check "datastore-setup --help: usage, exit 0, names every flag" bash -c "[ $rc = 0 ] && for f in --pin --unpin --update --backup --status --yes --no; do grep -q -- \$f '$root/out' || exit 1; done"
check "recipes: group Setup, a one-line description, placed in the dx recipe file only" bash -c "[ \$(grep -c \"^\\[group('Setup')\\]\" '$rjust') = 2 ] && just --justfile '$rjust' --list | grep -q 'datastore-setup'"
reset; FAKE_UID=0 run datastore status
check "datastore: refuses root" bash -c "[ $rc = 1 ] && grep -q 'not as root' '$root/out'"
reset; FAKE_UID=0 run datastore-setup --yes
check "datastore-setup: refuses root, creates nothing" bash -c "[ $rc = 1 ] && [ -z \"\$(ls '$SECRETS')\" ]"
reset; run datastore nosuch
check "datastore: an unknown command exits 2" test "$rc" = 2

# ---- datastore-setup: secrets
reset; run datastore-setup --yes
check "secrets fresh: the three missing secrets are created through stdin, none printed" bash -c "[ $rc = 0 ] && for s in postgresql-password valkey-password seaweedfs-s3-config; do [ -s '$SECRETS'/\$s ] || exit 1; done && ! grep -q 'secret create postgresql-password -' /dev/null; grep -q 'podman secret create postgresql-password -' '$LOG'"
check "secrets fresh: no secret value appears in the output or the call log" bash -c "for s in postgresql-password valkey-password seaweedfs-s3-config; do while read -r v; do [ -z \"\$v\" ] || { grep -qF -- \"\$v\" '$root/out' '$LOG' && exit 1; }; done < '$SECRETS'/\$s; done; exit 0"
check "secrets fresh: the S3 config is a generated identities JSON with an admin and credentials, random each time" bash -c "grep -q '\"identities\"' '$SECRETS/seaweedfs-s3-config' && grep -q '\"accessKey\":\"[A-Za-z0-9]\\{20\\}\"' '$SECRETS/seaweedfs-s3-config' && grep -q '\"secretKey\":\"[A-Za-z0-9]\\{40\\}\"' '$SECRETS/seaweedfs-s3-config'"
check "secrets fresh: the generated passwords are 32 characters of letters and digits" bash -c "[ \"\$(tr -d '\\n' <'$SECRETS/postgresql-password' | wc -c)\" = 32 ] && ! grep -q '[^A-Za-z0-9]' <(tr -d '\\n' <'$SECRETS/valkey-password')"
check "secrets fresh: an undo line names podman secret rm" has "podman secret rm"
cp "$SECRETS/postgresql-password" "$root/pg.before"; : >"$LOG"; run datastore-setup --yes
check "secrets existing: all present means nothing to do, no create call, and nothing overwritten" bash -c "[ $rc = 0 ] && grep -q 'All secrets exist already' '$root/out' && ! grep -q 'secret create' '$LOG' && cmp -s '$root/pg.before' '$SECRETS/postgresql-password'"
reset; echo old >"$SECRETS/valkey-password"; run datastore-setup --yes
check "secrets partly existing: only the missing ones are created, the existing one is untouched" bash -c "[ \"\$(cat '$SECRETS/valkey-password')\" = old ] && [ -s '$SECRETS/postgresql-password' ] && ! grep -q 'secret create valkey-password' '$LOG'"
reset; FAKE_SECRET_FAIL=valkey-password run datastore-setup --yes
check "secrets failure: the failing one is reported, the others are still created, exit 1" bash -c "[ $rc = 1 ] && grep -q 'Failed: podman secret create valkey-password' '$root/out' && [ -s '$SECRETS/postgresql-password' ]"
reset; run datastore-setup --no
check "secrets --no: the plan only, nothing created" bash -c "[ $rc = 0 ] && grep -q 'Plan only' '$root/out' && [ -z \"\$(ls '$SECRETS')\" ]"
reset; FAKE_GRAPHROOT="$root/home/.local/share/containers/storage" run datastore-setup --no
check "storage: a graphroot under the home is warned about (not backed up, how to move it)" bash -c "grep -q 'inside your home' '$root/out' && grep -q 'storage.conf' '$root/out'"
reset; run datastore-setup --no
check "storage: a graphroot outside the home is not warned about" bash -c "! grep -q 'inside your home' '$root/out'"

# ---- pins and drop-ins
dropin="$root/home/.config/containers/systemd/postgresql.container.d/10-image.conf"
shipped_pg=$(sed -n 's/^Image=//p' "$rq/postgresql.container")
reset; run datastore-setup --pin postgresql=17.11-alpine
check "pin: writes the drop-in with [Container] Image=<path>:<tag> in the same major, reloads systemd, prints the undo" bash -c "[ $rc = 0 ] && grep -qx '\\[Container\\]' '$dropin' && grep -qx 'Image=docker.io/library/postgres:17.11-alpine' '$dropin' && grep -q -- '--unpin postgresql' '$root/out' && grep -q 'systemctl --user daemon-reload' '$LOG'"
: >"$LOG"; run datastore-setup --pin postgresql=17.11-alpine
check "pin again: already done, no reload" bash -c "grep -q 'Already done' '$root/out' && ! grep -q daemon-reload '$LOG'"
run datastore-setup --pin postgresql=18.1-alpine
check "pin: a different major is refused (dump and restore by hand), the drop-in keeps its old content" bash -c "[ $rc = 1 ] && grep -q 'major' '$root/out' && grep -qx 'Image=docker.io/library/postgres:17.11-alpine' '$dropin'"
run datastore-setup --pin postgresql=latest
check "pin: latest or a floating tag is refused (exit 2)" test "$rc" = 2
run datastore-setup --pin nosuch=1.2
check "pin: an unknown service exits 2" test "$rc" = 2
run datastore-setup --pin postgresql
check "pin: a missing =TAG exits 2" test "$rc" = 2
run datastore-setup --pin postgresql=17.10-alpine --no
check "pin --no: the plan only, the drop-in is unchanged" bash -c "grep -q 'Plan only' '$root/out' && grep -qx 'Image=docker.io/library/postgres:17.11-alpine' '$dropin'"
run datastore-setup --status
check "status: shows the shipped pin, the user override and the effective major" bash -c "grep -qF 'shipped $shipped_pg' '$root/out' && grep -q 'override docker.io/library/postgres:17.11-alpine' '$root/out' && grep -q 'image major: 17' '$root/out'"
run datastore-setup --unpin postgresql
check "unpin: removes the drop-in and its directory, reloads" bash -c "[ $rc = 0 ] && [ ! -e '$dropin' ] && [ ! -d '$(dirname "$dropin")' ]"
run datastore-setup --unpin postgresql
check "unpin again: already done" bash -c "[ $rc = 0 ] && grep -q 'already done' '$root/out'"
run datastore-setup --unpin nosuch
check "unpin: an unknown service exits 2" test "$rc" = 2

# ---- the data-version guard and status
reset; allsecrets; mkvol postgresql-data; mkdir -p "$VOLS/postgresql-data/_data/pgdata"; echo 16 >"$VOLS/postgresql-data/_data/pgdata/PG_VERSION"
run datastore start
check "guard: PostgreSQL data of major 16 and an image of major 17 refuse to start with the dump and restore message; nothing is started" bash -c "[ $rc = 1 ] && grep -q 'data volume is PostgreSQL 16' '$root/out' && grep -q 'dump and restore' '$root/out' && ! grep -q 'systemctl --user start' '$LOG'"
run datastore-setup --status
check "status: shows the data major 16 next to the image major 17" bash -c "grep -q 'PostgreSQL data major: 16; image major: 17' '$root/out'"
run datastore-setup --pin postgresql=16.9-alpine
check "guard: pinning the old major is refused too (the major of the shipped pin stays)" test "$rc" = 1
echo 17 >"$VOLS/postgresql-data/_data/pgdata/PG_VERSION"; run datastore start
check "guard: data of the same major starts" bash -c "[ $rc = 0 ] && grep -q 'systemctl --user start datastore-pod.service' '$LOG'"
reset; allsecrets; run datastore start
check "guard: a new volume without a cluster is no obstacle" bash -c "[ $rc = 0 ] && grep -q 'systemctl --user start datastore-pod.service' '$LOG'"

# ---- datastore start and stop
reset; run datastore start
check "start: missing secrets: 'run ujust datastore-setup first', exit 1, nothing started" bash -c "[ $rc = 1 ] && grep -q 'ujust datastore-setup first' '$root/out' && ! grep -q 'systemctl --user start' '$LOG'"
reset; allsecrets; run datastore start
check "start (default target datastore): systemctl --user start datastore-pod.service, no kafka, no pull, no sudo" bash -c "[ $rc = 0 ] && grep -qx 'systemctl --user start datastore-pod.service' '$LOG' && ! grep -q 'kafka-pod' '$LOG' && ! grep -q 'pull' '$LOG' && ! grep -q sudo '$LOG'"
: >"$LOG"; ACTIVE="datastore-pod.service" run datastore start
check "start: an already running pod is a no-op with a note" bash -c "[ $rc = 0 ] && grep -q 'already running' '$root/out' && ! grep -q 'systemctl --user start' '$LOG'"
reset; run datastore start kafka
check "start kafka: needs no secrets, starts only kafka-pod.service" bash -c "[ $rc = 0 ] && grep -qx 'systemctl --user start kafka-pod.service' '$LOG' && ! grep -q 'datastore-pod' '$LOG'"
reset; allsecrets; run datastore start all
check "start all: both pods" bash -c "grep -qx 'systemctl --user start datastore-pod.service' '$LOG' && grep -qx 'systemctl --user start kafka-pod.service' '$LOG'"
reset; run datastore start nosuch
check "start: an unknown target exits 2" test "$rc" = 2
reset; allsecrets; FAKE_START_FAIL=1 run datastore start
check "start: a failing systemctl is reported and exits 1, naming the journal" bash -c "[ $rc = 1 ] && grep -q 'journalctl --user -u datastore-pod.service' '$root/out'"
reset; ACTIVE="datastore-pod.service kafka-pod.service"; export ACTIVE; run datastore stop all
check "stop all: stops both pods, only systemctl --user stop, never a volume removal or reset" bash -c "[ $rc = 0 ] && grep -qx 'systemctl --user stop datastore-pod.service' '$LOG' && grep -qx 'systemctl --user stop kafka-pod.service' '$LOG' && ! grep -qE 'volume rm|system reset|podman rm' '$LOG'"
reset; run datastore stop
check "stop: a pod that is not running is a no-op with a note" bash -c "[ $rc = 0 ] && grep -q 'not running' '$root/out' && ! grep -q 'systemctl --user stop' '$LOG'"
reset; ACTIVE="kafka-pod.service"; export ACTIVE; run datastore stop kafka
check "stop kafka: only kafka-pod.service" bash -c "grep -qx 'systemctl --user stop kafka-pod.service' '$LOG' && ! grep -q datastore-pod '$LOG'"
reset; run datastore stop nosuch
check "stop: an unknown target exits 2" test "$rc" = 2
reset; run datastore logs postgresql
check "logs: journalctl --user -u postgresql.service, bounded to 200 lines" bash -c "[ $rc = 0 ] && grep -qx 'journalctl --user -u postgresql.service -n 200 --no-pager' '$LOG'"
reset; run datastore logs nosuch
check "logs: an unknown service exits 2" test "$rc" = 2
reset; run datastore logs
check "logs: no service exits 2" test "$rc" = 2
reset; ACTIVE="datastore-pod.service"; RUNNING="pgsql valkey"; export ACTIVE RUNNING; run datastore status
check "status: one screen with each pod, container, its state, the running image against the shipped pin, the ports and the secret state" bash -c "[ $rc = 0 ] && grep -q 'datastore-pod.service *active' '$root/out' && grep -q 'kafka-pod.service *inactive' '$root/out' && grep -q 'pgsql *running' '$root/out' && grep -q 'running-image-of-pgsql; pin $shipped_pg' '$root/out' && grep -q 'kafka *kafka *-' '$root/out' && grep -q '127.0.0.1: 5432' '$root/out' && grep -q 'Missing secrets: postgresql-password valkey-password seaweedfs-s3-config' '$root/out'"

# ---- update
reset; run datastore-setup --update --no
check "update --no: prints the pins and says back up first, pulls nothing" bash -c "[ $rc = 0 ] && grep -q 'Back up first' '$root/out' && grep -qF '$shipped_pg' '$root/out' && ! grep -q 'podman pull' '$LOG'"
reset; ACTIVE="datastore-pod.service"; export ACTIVE; run datastore-setup --update --yes
check "update --yes: pulls the four pinned images (digest included) and does NOT restart or stop a running pod, and says so" bash -c "[ $rc = 0 ] && [ \$(grep -c '^podman pull' '$LOG') = 4 ] && grep -qF 'podman pull $shipped_pg' '$LOG' && ! grep -qE 'systemctl --user (start|stop|restart)' '$LOG' && grep -q 'was NOT restarted' '$root/out'"
reset; FAKE_PULL_FAIL=1 run datastore-setup --update --yes
check "update: a failing pull exits 1" test "$rc" = 1
reset; run datastore-setup --update
check "update without --yes and no terminal: asks, default no, pulls nothing" bash -c "! grep -q 'podman pull' '$LOG'"

# ---- backup
bk="$root/backup"
reset; mkvol postgresql-data; mkvol valkey-data; mkvol seaweed-data; mkvol kafka-data
run datastore-setup --backup "$bk"
check "backup, everything stopped: one tar per existing volume with the date, files private, exit 0" bash -c "[ $rc = 0 ] && for v in postgresql-data valkey-data seaweed-data kafka-data; do ls '$bk'/\$v-[0-9]*.tar >/dev/null || exit 1; done && [ \$(stat -c %a '$bk'/postgresql-data-*.tar) = 600 ]"
check "backup: says the volumes are not covered by snapper or borg and how to restore" bash -c "grep -q 'NOT covered by snapper or borg' '$root/out' && grep -q 'podman volume import' '$root/out'"
check "backup: no timer, no pod started or stopped when nothing ran" bash -c "! grep -qE 'systemctl --user (start|stop)' '$LOG'"
reset; mkvol postgresql-data; mkvol valkey-data; ACTIVE="datastore-pod.service"; export ACTIVE; run datastore-setup --backup "$bk-2"
check "backup, pod running: refused without --stop (Valkey, SeaweedFS, Kafka need it stopped), nothing written" bash -c "[ $rc = 1 ] && grep -q 'Refused' '$root/out' && grep -q -- '--stop' '$root/out' && [ ! -d '$bk-2' ]"
: >"$LOG"; run datastore-setup --backup "$bk-2" --stop
check "backup --stop: stops the pod, exports, starts it again; PostgreSQL volume exported too while stopped" bash -c "[ $rc = 0 ] && grep -qx 'systemctl --user stop datastore-pod.service' '$LOG' && grep -qx 'systemctl --user start datastore-pod.service' '$LOG' && ls '$bk-2'/postgresql-data-*.tar '$bk-2'/valkey-data-*.tar >/dev/null"
reset; mkvol postgresql-data; ACTIVE="datastore-pod.service"; export ACTIVE; run datastore-setup --backup "$bk-3"
check "backup, only PostgreSQL exists and the pod runs: an online pg_dumpall into a .sql file, no pod stop needed" bash -c "[ $rc = 0 ] && ls '$bk-3'/postgresql-[0-9]*.sql >/dev/null && grep -q 'podman exec pgsql pg_dumpall -U postgres' '$LOG' && ! grep -q 'systemctl --user stop' '$LOG'"
reset; mkvol kafka-data; ACTIVE="kafka-pod.service"; export ACTIVE; run datastore-setup --backup "$bk-4"
check "backup: a running Kafka pod is refused without --stop" bash -c "[ $rc = 1 ] && grep -q 'kafka-pod.service' '$root/out'"
reset; mkvol valkey-data; FAKE_EXPORT_FAIL=valkey-data run datastore-setup --backup "$bk-5"
check "backup: a failing export is reported, the partial file removed, exit 1" bash -c "[ $rc = 1 ] && grep -q 'Failed: podman volume export valkey-data' '$root/out' && ! ls '$bk-5'/valkey-data-*.tar 2>/dev/null"
reset; run datastore-setup --backup "$bk-6"
check "backup with no volumes: nothing to do, exit 0, no directory created" bash -c "[ $rc = 0 ] && grep -q 'nothing to back up' '$root/out' && [ ! -d '$bk-6' ]"
reset; mkvol valkey-data; run datastore-setup --backup "$bk-7" --no
check "backup --no: the plan only, nothing written" bash -c "[ $rc = 0 ] && grep -q 'Plan only' '$root/out' && [ ! -d '$bk-7' ]"

echo
echo "passed: $pass, failed: $failn"
[ "$failn" = 0 ]
