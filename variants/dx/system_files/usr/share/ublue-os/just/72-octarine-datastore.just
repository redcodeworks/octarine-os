# Start, stop and inspect the opt-in datastore containers (rootless)
[group('Setup')]
[positional-arguments]
datastore *args:
    #!/usr/bin/env bash
    set -uo pipefail
    lib="${OCTARINE_DATASTORE_LIB:-/usr/share/octarine-os/lib/datastore.sh}"
    # shellcheck source=/dev/null
    if [ -r "$lib" ]; then . "$lib"; else echo "The datastore helpers are missing: $lib" >&2; exit 1; fi
    usage="Usage: ujust datastore start|stop [datastore|kafka|all] | status | logs SERVICE | -h"
    if [ "$#" -eq 0 ]; then echo "$usage" >&2; exit 2; fi
    case "$1" in
        help | --help | -h) printf '%s\n' 'The opt-in datastore containers of the dx image, rootless Podman Quadlets, stopped until you start them. `ujust datastore start [datastore|kafka|all]` (default: datastore = PostgreSQL, Valkey and SeaweedFS in one pod; kafka only when named or with all), `stop [datastore|kafka|all]`, `status` (pods, containers, loopback ports, the running image against the shipped pin), `logs SERVICE` (postgresql, valkey, seaweedfs, kafka; the last 200 lines of journalctl --user). Everything is `systemctl --user`: no privilege prompt. start first checks that the podman secrets exist (otherwise: run ujust datastore-setup first) and, for PostgreSQL, that the data volume major matches the image; it never pulls or updates an image (that is ujust datastore-setup --update). Starting a running pod is a no-op. stop only stops the pod unit: it never removes a volume or resets Podman. Undo of start: ujust datastore stop. Ports (127.0.0.1 only): 5432 PostgreSQL, 6379 Valkey, 8333 S3, 9333 SeaweedFS master, 8889 filer, 9092 Kafka.'; exit 0 ;;
    esac
    if [ "$(id -u)" = 0 ]; then echo "Run this as your user, not as root: the datastore is rootless." >&2; exit 1; fi
    command -v podman >/dev/null 2>&1 || { echo "podman is not installed." >&2; exit 1; }
    verb=$1
    shift
    target_pods() { # datastore|kafka|all -> pod units
        case "${1:-datastore}" in
            datastore) echo datastore-pod.service ;;
            kafka) echo kafka-pod.service ;;
            all) echo "datastore-pod.service kafka-pod.service" ;;
            *) return 1 ;;
        esac
    }
    case "$verb" in
        start)
            pods=$(target_pods "${1:-datastore}") || { echo "Unknown target '${1}'. Known: datastore kafka all" >&2; echo "$usage" >&2; exit 2; }
            rc=0
            for pod in $pods; do
                if [ "$pod" = datastore-pod.service ]; then
                    miss=$(ds_missing_secrets | tr '\n' ' ')
                    if [ -n "$miss" ]; then echo "Missing podman secrets: ${miss}. Run: ujust datastore-setup first." >&2; exit 1; fi
                    ds_pg_guard || exit 1
                fi
                if [ "$(systemctl --user is-active "$pod" 2>/dev/null)" = active ]; then echo "$pod is already running: nothing to do."; continue; fi
                echo "Starting $pod (undo: ujust datastore stop)"
                systemctl --user start "$pod" || { echo "Failed: systemctl --user start $pod (journalctl --user -u $pod)" >&2; rc=1; }
            done
            exit "$rc"
            ;;
        stop)
            pods=$(target_pods "${1:-datastore}") || { echo "Unknown target '${1}'. Known: datastore kafka all" >&2; echo "$usage" >&2; exit 2; }
            rc=0
            for pod in $pods; do
                if [ "$(systemctl --user is-active "$pod" 2>/dev/null)" != active ]; then echo "$pod is not running: nothing to do."; continue; fi
                echo "Stopping $pod (undo: ujust datastore start); volumes and data stay"
                systemctl --user stop "$pod" || { echo "Failed: systemctl --user stop $pod" >&2; rc=1; }
            done
            exit "$rc"
            ;;
        status)
            for pod in datastore-pod.service kafka-pod.service; do printf '%-22s %s\n' "$pod" "$(systemctl --user is-active "$pod" 2>/dev/null || true)"; done
            echo
            printf '%-12s %-10s %-9s %s\n' SERVICE CONTAINER STATE "IMAGE (running; shipped pin)"
            for s in $DS_SERVICES; do
                c=$(ds_container "$s")
                st=$(podman inspect "$c" --format '{{{{.State.Status}}' 2>/dev/null || echo "-")
                running=$(podman inspect "$c" --format '{{{{.ImageName}}' 2>/dev/null || echo "-")
                pin=$(ds_effective_image "$s")
                note=""
                if [ -n "$(ds_override_image "$s")" ]; then note=" (user override)"; fi
                printf '%-12s %-10s %-9s %s; pin %s%s\n' "$s" "$c" "$st" "$running" "$pin" "$note"
            done
            echo
            echo "Ports on 127.0.0.1: 5432 PostgreSQL, 6379 Valkey, 8333 S3, 9333 SeaweedFS master, 8889 filer, 9092 Kafka"
            miss=$(ds_missing_secrets | tr '\n' ' ')
            echo "Missing secrets: ${miss:-none}"
            exit 0
            ;;
        logs)
            svc=${1:-}
            if [ -z "$svc" ] || ! ds_known_service "$svc"; then echo "Unknown service '${svc}'. Known: ${DS_SERVICES}" >&2; exit 2; fi
            journalctl --user -u "$(ds_unit "$svc")" -n 200 --no-pager
            exit $?
            ;;
        *) echo "Unknown command: $verb" >&2; echo "$usage" >&2; exit 2 ;;
    esac

# Set up the opt-in datastore containers: secrets, pins, update, backup (--help)
[group('Setup')]
[positional-arguments]
datastore-setup *args:
    #!/usr/bin/env bash
    set -uo pipefail
    lib="${OCTARINE_DATASTORE_LIB:-/usr/share/octarine-os/lib/datastore.sh}"
    menu_lib="${OCTARINE_MENU_LIB:-/usr/share/octarine-os/lib/menu.sh}"
    # shellcheck source=/dev/null
    if [ -r "$lib" ]; then . "$lib"; else echo "The datastore helpers are missing: $lib" >&2; exit 1; fi
    # shellcheck source=/dev/null
    if [ -r "$menu_lib" ]; then . "$menu_lib"; fi
    if ! declare -F menu_confirm >/dev/null; then menu_confirm() { return 1; }; fi
    usage="Usage: ujust datastore-setup [--yes|--no] [--status] [--pin SERVICE=TAG] [--unpin SERVICE] [--update] [--backup DIR [--stop]] [-h]"
    mode=ask
    action=setup
    pin=""
    unpin=""
    backup_dir=""
    stop_ok=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --yes) mode=yes ;;
            --no) mode=no ;;
            --status) action=status ;;
            --update) action=update ;;
            --pin) shift; if [ "$#" -eq 0 ]; then echo "--pin needs SERVICE=TAG" >&2; exit 2; fi; action=pin; pin=$1 ;;
            --pin=*) action=pin; pin=${1#--pin=} ;;
            --unpin) shift; if [ "$#" -eq 0 ]; then echo "--unpin needs SERVICE" >&2; exit 2; fi; action=unpin; unpin=$1 ;;
            --unpin=*) action=unpin; unpin=${1#--unpin=} ;;
            --backup) shift; if [ "$#" -eq 0 ]; then echo "--backup needs a directory" >&2; exit 2; fi; action=backup; backup_dir=$1 ;;
            --backup=*) action=backup; backup_dir=${1#--backup=} ;;
            --stop) stop_ok=1 ;;
            help | --help | -h) printf '%s\n' 'Set up the opt-in datastore containers of the dx image (rootless Quadlets: PostgreSQL, Valkey and SeaweedFS in the datastore pod, Kafka in its own pod; nothing starts by itself, use ujust datastore start). `ujust datastore-setup [--yes|--no] [--status] [--pin SERVICE=TAG] [--unpin SERVICE] [--update] [--backup DIR [--stop]]`. Without options: creates the MISSING podman secrets with random values (postgresql-password, valkey-password and seaweedfs-s3-config, a generated S3 identities file); values are never printed or logged and an existing secret is never overwritten; and warns when Podman'\''s storage (where the data volumes live) is under your home. Undo: podman secret rm NAME. --status shows each shipped image pin, a user override, the running image, the PostgreSQL data major, the storage location and the volume sizes. Pins: the image ships exact tags with digests and never follows a floating tag; --pin SERVICE=TAG (postgresql, valkey, seaweedfs, kafka) writes a Quadlet drop-in ~/.config/containers/systemd/<service>.container.d/10-image.conf with that tag in the SAME major (a major change is a manual dump and restore, refused here), --unpin removes it. --update pulls the pinned tags after printing them and saying to back up first; it never restarts a running service. --backup DIR exports the volumes to DIR/<volume>-<date>.tar (PostgreSQL while running through pg_dumpall into DIR/postgresql-<date>.sql; Valkey, SeaweedFS and Kafka need their pod stopped: a running one is refused unless --stop, which stops the pod and starts it again afterwards). Restore is manual: podman volume import NAME FILE. These volumes are NOT covered by snapper or borg. Rootless only, no privilege prompt. Storage: with no storage.conf the volumes land in ~/.local/share/containers/storage; to move them put graphroot in ~/.config/containers/storage.conf (a documented step, not automated).'; exit 0 ;;
            *) echo "Unknown option: $1" >&2; echo "$usage" >&2; exit 2 ;;
        esac
        shift
    done
    if [ "$(id -u)" = 0 ]; then echo "Run this as your user, not as root: the datastore is rootless." >&2; exit 1; fi
    command -v podman >/dev/null 2>&1 || { echo "podman is not installed." >&2; exit 1; }
    graphroot() { podman info --format '{{{{.Store.GraphRoot}}' 2>/dev/null; }
    warn_graphroot() {
        local g; g=$(graphroot)
        if [ -n "$g" ] && case "$g" in "$HOME"/*) true ;; *) false ;; esac; then
            echo "Note: Podman stores volumes under $g (inside your home): the datastore data lives there, and neither snapper nor borg covers it."
            echo "      To move it, set graphroot in ~/.config/containers/storage.conf (see the Podman storage.conf documentation) before creating data."
        fi
    }

    if [ "$action" = status ]; then
        echo "Shipped pins and overrides:"
        for s in $DS_SERVICES; do
            o=$(ds_override_image "$s")
            printf '  %-11s shipped %s\n' "$s" "$(ds_shipped_image "$s")"
            if [ -n "$o" ]; then printf '  %-11s override %s (%s)\n' "" "$o" "$(ds_dropin "$s")"; fi
            printf '  %-11s running %s\n' "" "$(podman inspect "$(ds_container "$s")" --format '{{{{.ImageName}}' 2>/dev/null || echo not-created)"
        done
        pgm=$(ds_pg_data_major)
        echo "PostgreSQL data major: ${pgm:-none (no cluster yet)}; image major: $(ds_image_major "$(ds_effective_image postgresql)")"
        echo "Storage (graphroot): $(graphroot)"
        for v in $DS_VOLUMES; do
            if podman volume exists "$v" 2>/dev/null; then
                mp=$(podman volume inspect "$v" --format '{{{{.Mountpoint}}' 2>/dev/null)
                printf '  volume %-16s %s\n' "$v" "$(podman unshare du -sh "$mp" 2>/dev/null | cut -f1)"
            else
                printf '  volume %-16s not created yet\n' "$v"
            fi
        done
        miss=$(ds_missing_secrets | tr '\n' ' ')
        echo "Missing secrets: ${miss:-none}"
        warn_graphroot
        exit 0
    fi

    if [ "$action" = pin ]; then
        svc=${pin%%=*}
        tag=${pin#*=}
        if [ "$svc" = "$pin" ] || ! ds_known_service "$svc"; then echo "--pin needs SERVICE=TAG with SERVICE one of: ${DS_SERVICES}" >&2; exit 2; fi
        if ! [[ "$tag" =~ ^[0-9]+(\.[0-9]+)*(-[a-z0-9.]+)?$ ]]; then echo "'$tag' is not an exact version tag (no latest, no floating tag)." >&2; exit 2; fi
        shipped=$(ds_shipped_image "$svc")
        if [ -z "$shipped" ]; then echo "No shipped Quadlet for $svc in $DS_QUADLET_DIR." >&2; exit 1; fi
        if [ "${tag%%.*}" != "$(ds_image_major "$shipped")" ]; then
            echo "Refused: $tag is not in major $(ds_image_major "$shipped") (shipped $(ds_image_tag "$shipped")). A major version change needs a dump and restore: do it by hand." >&2
            exit 1
        fi
        f=$(ds_dropin "$svc")
        want="$(ds_image_path "$shipped"):$tag"
        echo "Pins $svc to $want (drop-in $f; no digest: a tag can move, the shipped pin cannot). Undo: ujust datastore-setup --unpin $svc"
        if [ "$mode" = no ]; then echo "Plan only."; exit 0; fi
        if [ -f "$f" ] && [ "$(sed -n 's/^Image=//p' "$f" | tail -n1)" = "$want" ]; then echo "Already done."; exit 0; fi
        mkdir -p "$(dirname "$f")" && printf '[Container]\nImage=%s\n' "$want" >"$f" || { echo "Failed to write $f" >&2; exit 1; }
        systemctl --user daemon-reload || echo "Run: systemctl --user daemon-reload"
        echo "Written. Running services keep their image until restarted (ujust datastore stop, then start). Pull it first: ujust datastore-setup --update"
        exit 0
    fi
    if [ "$action" = unpin ]; then
        if ! ds_known_service "$unpin"; then echo "--unpin needs one of: ${DS_SERVICES}" >&2; exit 2; fi
        f=$(ds_dropin "$unpin")
        if [ ! -f "$f" ]; then echo "No override for $unpin: already done."; exit 0; fi
        echo "Removes $f (back to the shipped pin). Undo: ujust datastore-setup --pin $unpin=<tag>"
        if [ "$mode" = no ]; then echo "Plan only."; exit 0; fi
        rm -f -- "${f:?}"
        rmdir "$(dirname "$f")" 2>/dev/null
        systemctl --user daemon-reload || echo "Run: systemctl --user daemon-reload"
        exit 0
    fi

    if [ "$action" = update ]; then
        echo "The images these pins resolve to (shipped pin, or your override):"
        for s in $DS_SERVICES; do echo "  $s: $(ds_effective_image "$s")"; done
        echo "Back up first: ujust datastore-setup --backup DIR. A pull changes nothing that runs; services keep their image until you restart them."
        if [ "$mode" = no ]; then echo "Plan only."; exit 0; fi
        if [ "$mode" != yes ] && ! menu_confirm "Pull these images now?" n; then echo "Nothing pulled."; exit 0; fi
        rc=0
        for s in $DS_SERVICES; do
            img=$(ds_effective_image "$s")
            echo "podman pull $img"
            podman pull "$img" >/dev/null || { echo "Failed: podman pull $img" >&2; rc=1; }
        done
        for s in $DS_SERVICES; do
            if [ "$(systemctl --user is-active "$(ds_pod_unit "$s")" 2>/dev/null)" = active ]; then echo "Note: $(ds_pod_unit "$s") is running and was NOT restarted; restart it yourself: ujust datastore stop && ujust datastore start"; break; fi
        done
        exit "$rc"
    fi

    if [ "$action" = backup ]; then
        stamp=$(date +%Y%m%d-%H%M%S)
        pods_running=""
        for p in datastore-pod.service kafka-pod.service; do if [ "$(systemctl --user is-active "$p" 2>/dev/null)" = active ]; then pods_running="$pods_running $p"; fi; done
        pg_running=0
        case " $pods_running " in *" datastore-pod.service "*) pg_running=1 ;; esac
        plan=()
        for v in $DS_VOLUMES; do
            podman volume exists "$v" 2>/dev/null || continue
            if [ "$v" = postgresql-data ] && [ "$pg_running" = 1 ]; then plan+=("postgresql-data: pg_dumpall (online, consistent) -> $backup_dir/postgresql-$stamp.sql (a name that exists is never overwritten: -2, -3 ...)"); continue; fi
            plan+=("$v: podman volume export -> $backup_dir/$v-$stamp.tar")
        done
        if [ "${#plan[@]}" -eq 0 ]; then echo "No datastore volumes exist yet: nothing to back up."; exit 0; fi
        echo "Backup plan:"
        printf '  %s\n' "${plan[@]}"
        need_stop=""
        for p in $pods_running; do
            if [ "$p" = datastore-pod.service ]; then
                # the Valkey and SeaweedFS volumes are only consistent while the pod is stopped; PostgreSQL goes through pg_dumpall
                if podman volume exists valkey-data 2>/dev/null || podman volume exists seaweed-data 2>/dev/null; then need_stop="$need_stop $p"; fi
            else
                need_stop="$need_stop $p"
            fi
        done
        if [ -n "$need_stop" ] && [ "$stop_ok" != 1 ]; then
            echo "Refused:${need_stop} running. Valkey, SeaweedFS and Kafka volumes are only consistent while their pod is stopped: stop it (ujust datastore stop) or pass --stop (the pod is stopped and started again afterwards)." >&2
            exit 1
        fi
        echo "These volumes are NOT covered by snapper or borg; keep the files somewhere safe. Restore by hand: podman volume import NAME FILE (into a new volume), or psql < the .sql file. Nothing runs on a timer."
        if [ "$mode" = no ]; then echo "Plan only."; exit 0; fi
        mkdir -p "$backup_dir" || { echo "Cannot create $backup_dir" >&2; exit 1; }
        umask 077
        rc=0
        stopped=""
        cur_part=""
        # A name that exists (a file or a leftover .part) is never reused: -2, -3 ... is appended.
        pick() { # base ext
            local n="${backup_dir:?}/$1-${stamp:?}" i=1 c
            c="$n.$2"
            while [ -e "$c" ] || [ -e "$c.part" ]; do i=$((i + 1)); c="$n-$i.$2"; done
            printf '%s' "$c"
        }
        # Pods this run stopped are started again on any exit, Ctrl-C and early failure included; only the .part file of an interrupted export is removed.
        restore_stopped() {
            [ -n "$cur_part" ] && rm -f -- "${cur_part:?}"
            cur_part=""
            local q
            for q in $stopped; do echo "Starting $q again"; systemctl --user start "$q" || { echo "Failed to restart $q: ujust datastore start" >&2; rc=1; }; done
            stopped=""
        }
        trap 'restore_stopped' EXIT
        trap 'exit 130' INT
        trap 'exit 143' TERM
        for p in $need_stop; do stopped="$stopped $p"; echo "Stopping $p"; systemctl --user stop "$p" || { echo "Failed to stop $p" >&2; exit 1; }; done
        for v in $DS_VOLUMES; do
            podman volume exists "$v" 2>/dev/null || continue
            if [ "$v" = postgresql-data ] && [ "$pg_running" = 1 ] && [ "${need_stop#*datastore-pod}" = "$need_stop" ]; then
                out=$(pick postgresql sql)
                cur_part="$out.part"
                if podman exec "$(ds_container postgresql)" pg_dumpall -U postgres >"$cur_part" && mv -- "$cur_part" "$out"; then echo "Wrote $out"; else echo "Failed: pg_dumpall (an earlier backup is untouched)" >&2; rm -f -- "${cur_part:?}"; rc=1; fi
                cur_part=""
                continue
            fi
            out=$(pick "${v:?}" tar)
            cur_part="$out.part"
            if podman volume export "$v" --output "$cur_part" && mv -- "$cur_part" "$out"; then echo "Wrote $out"; else echo "Failed: podman volume export $v (an earlier backup is untouched)" >&2; rm -f -- "${cur_part:?}"; rc=1; fi
            cur_part=""
        done
        restore_stopped
        trap - EXIT INT TERM
        exit "$rc"
    fi

    # default: the missing secrets
    echo "== secrets"
    miss=$(ds_missing_secrets | tr '\n' ' ')
    if [ -z "$miss" ]; then
        echo "All secrets exist already: nothing to do."
        warn_graphroot
        exit 0
    fi
    echo "Creates the missing podman secrets with random values (never printed): $miss"
    echo "Undo: podman secret rm $miss"
    if [ "$mode" = no ]; then echo "Plan only."; warn_graphroot; exit 0; fi
    if [ "$mode" != yes ] && ! menu_confirm "Create them?" y; then echo "Nothing created."; exit 0; fi
    rand() { head -c 96 /dev/urandom | base64 -w0 | tr -d '/+=' | cut -c1-"$1"; }
    failed=0
    for s in $miss; do
        ok=0
        case "$s" in
            seaweedfs-s3-config)
                ak=$(rand 20)
                sk=$(rand 40)
                printf '{"identities":[{"name":"admin","credentials":[{"accessKey":"%s","secretKey":"%s"}],"actions":["Admin","Read","Write","List","Tagging"]}]}\n' "$ak" "$sk" | podman secret create "$s" - >/dev/null && ok=1
                ak=""
                sk=""
                ;;
            *) rand 32 | podman secret create "$s" - >/dev/null && ok=1 ;;
        esac
        if [ "$ok" = 1 ]; then echo "Created $s"; else echo "Failed: podman secret create $s" >&2; failed=1; fi
    done
    warn_graphroot
    echo "Next: ujust datastore start"
    exit "$failed"

