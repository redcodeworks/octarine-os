# Turn this machine into a KVM/libvirt host: daemons, IOMMU, bridge, images (--help)
[group('Setup')]
[positional-arguments]
virthost-setup *args:
    #!/usr/bin/env bash
    set -uo pipefail
    menu_lib="${OCTARINE_MENU_LIB:-/usr/share/octarine-os/lib/menu.sh}"
    # shellcheck source=/dev/null
    if [ -r "$menu_lib" ]; then . "$menu_lib"; fi
    if ! declare -F menu_multi >/dev/null; then menu_multi() { return 3; }; menu_ready() { return 1; }; menu_confirm() { return 1; }; menu_title() { printf '%s\n' "$1"; }; fi
    kargs_lib="${OCTARINE_KARGS_LIB:-/usr/share/octarine-os/lib/kargs.sh}"
    # shellcheck source=/dev/null
    if [ -r "$kargs_lib" ]; then . "$kargs_lib"; fi
    if ! declare -F kargs_notice >/dev/null; then kargs_notice() { :; }; kargs_pending_arg() { return 1; }; kargs_pending_change() { return 1; }; kargs_confirm_update() { return 0; }; fi
    all_steps="check daemons iommu connection image-dir virtio bridge libvirt-network"
    usage="Usage: ujust virthost-setup [--yes|--no] [--only STEP[,STEP...]] [--list] [--image-dir DIR] [--nic IFACE] [--bridge NAME] [--virtio stable|latest] [--pool NAME] [--force] [--yes-remote] [-h]"
    mode=ask
    only=""
    list=0
    image_dir="${VIRTHOST_IMAGE_DIR:-/var/lib/libvirt/images}"
    image_dir_given=0
    nic_want=""
    br="br0"
    virtio_kind=stable
    pool_name=""
    force=0
    yes_remote=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --yes) mode=yes ;;
            --no) mode=no ;;
            --list) list=1 ;;
            --force) force=1 ;;
            --yes-remote) yes_remote=1 ;;
            --only) shift; if [ "$#" -eq 0 ]; then echo "--only needs STEP[,STEP]" >&2; exit 2; fi; only=$1 ;;
            --only=*) only=${1#--only=} ;;
            --image-dir) shift; if [ "$#" -eq 0 ]; then echo "--image-dir needs a directory" >&2; exit 2; fi; image_dir=$1; image_dir_given=1 ;;
            --image-dir=*) image_dir=${1#--image-dir=}; image_dir_given=1 ;;
            --nic) shift; if [ "$#" -eq 0 ]; then echo "--nic needs an interface" >&2; exit 2; fi; nic_want=$1 ;;
            --nic=*) nic_want=${1#--nic=} ;;
            --bridge) shift; if [ "$#" -eq 0 ]; then echo "--bridge needs a name" >&2; exit 2; fi; br=$1 ;;
            --bridge=*) br=${1#--bridge=} ;;
            --virtio) shift; if [ "$#" -eq 0 ]; then echo "--virtio needs stable or latest" >&2; exit 2; fi; virtio_kind=$1 ;;
            --virtio=*) virtio_kind=${1#--virtio=} ;;
            --pool) shift; if [ "$#" -eq 0 ]; then echo "--pool needs a name" >&2; exit 2; fi; pool_name=$1 ;;
            --pool=*) pool_name=${1#--pool=} ;;
            help | --help | -h) printf '%s\n' 'Turn a dx machine into a KVM/libvirt host, one checklist (the VM tooling is in the dx image). `ujust virthost-setup [--yes|--no] [--only STEP[,STEP...]] [--list] [--image-dir DIR] [--nic IFACE] [--bridge NAME] [--virtio stable|latest] [--pool NAME] [--force] [--yes-remote]`. Steps in order: check (no sudo: virtualization flag, /dev/kvm, kernel modules, virt-host-validate summarized), daemons (verify the modular libvirt sockets virtqemud, virtnetworkd, virtstoraged, virtnodedevd, virtsecretd, virtnwfilterd are enabled and libvirtd is NOT; sudo), iommu (kernel arguments through rpm-ostree kargs: AMD iommu=pt, Intel intel_iommu=on iommu=pt; only matters for device passthrough; sudo, reboot), connection (join the libvirt group and set uri_default = "qemu:///system" in ~/.config/libvirt/libvirt.conf; sudo once, log in again afterwards), image-dir (the VM image directory, default /var/lib/libvirt/images, or --image-dir DIR: an ACL for your user, search access for qemu on the parents, the SELinux type virt_image_t, optionally a libvirt storage pool with --pool NAME; sudo), virtio (download the virtio-win driver ISO into the image directory: no checksum or signature is published, the sha256 you get is recorded next to the file; --virtio latest takes the latest-virtio build; --force downloads again), bridge (a NetworkManager bridge br0 on the wired NIC so VMs appear on the LAN; shows the plan and asks first; the network can drop for a moment; refused over SSH without --yes-remote and over Wi-Fi), libvirt-network (define the libvirt network nwbridge on that bridge; the default NAT network stays). Every step detects "already done", prints what it runs and its undo; sudo is used where named, once per command, never retried (a security-key touch), the exact command is printed when it fails. --yes runs check, daemons, connection, image-dir, virtio and libvirt-network (never iommu or bridge: name those with --only), --no only prints the plan. Not covered: a TuneD profile, Wi-Fi bridging, nested virtualization. Undo lines are printed per step. Not verified here: the bridge takeover on a live LAN, qemu opening an image in a custom directory with the SELinux label.'; exit 0 ;;
            *) echo "Unknown option: $1" >&2; echo "$usage" >&2; exit 2 ;;
        esac
        shift
    done
    if [ "$(id -u)" = 0 ]; then echo "Run this as your user, not as root: sudo is used where a step needs it." >&2; exit 1; fi
    for s in $(echo "$only" | tr ',' ' '); do case " $all_steps " in *" $s "*) ;; *) echo "Unknown step: $s. Known: $all_steps" >&2; exit 2 ;; esac; done
    case "$virtio_kind" in stable | latest) ;; *) echo "--virtio takes stable or latest" >&2; exit 2 ;; esac

    cpuinfo="${VIRTHOST_CPUINFO:-/proc/cpuinfo}"
    cmdline_file="${VIRTHOST_CMDLINE:-/proc/cmdline}"
    iommu_dir="${VIRTHOST_IOMMU_DIR:-/sys/class/iommu}"
    kvm_dev="${VIRTHOST_KVM:-/dev/kvm}"
    net_dir="${VIRTHOST_NET_DIR:-/sys/class/net}"
    conf="${XDG_CONFIG_HOME:-$HOME/.config}/libvirt/libvirt.conf"
    user=$(id -un)
    names=(); results=(); undos=(); failed=0
    record() { names+=("$1"); results+=("$2"); undos+=("${3:--}"); }
    fail_step() { failed=1; record "$1" FAILED "${2:-}"; }
    selected() { [ -z "$only" ] && return 0; case ",$only," in *",$1,"*) return 0 ;; esac; return 1; }
    explicit() { case ",$only," in *",$1,"*) return 0 ;; esac; return 1; }
    # run_sudo CMD...: print it, run it once with sudo, never retry; the exact command on failure
    run_sudo() {
        echo "  sudo $*"
        if sudo "$@"; then return 0; fi
        echo "  FAILED: sudo $*" >&2
        echo "  Run it yourself when ready; it was not retried." >&2
        return 1
    }
    vendor() { awk -F: '/^vendor_id/ { gsub(/[ \t]/, "", $2); print $2; exit }' "$cpuinfo" 2>/dev/null; }
    has_cpu_virt() { grep -Eqw 'vmx|svm' "$cpuinfo" 2>/dev/null; }
    iommu_present() { [ -n "$(ls -A "$iommu_dir" 2>/dev/null)" ] || { command -v dmesg >/dev/null 2>&1 && dmesg 2>/dev/null | grep -Eqi 'AMD-Vi|DMAR'; }; }
    in_cmdline() { grep -qw -- "$1" "$cmdline_file" 2>/dev/null || rpm-ostree kargs 2>/dev/null | grep -qw -- "$1"; }
    do_apply() { [ "$mode" != no ]; }
    confirm_or_default() { # question, default y|n
        if [ "$mode" = yes ]; then return 0; fi
        menu_confirm "$1" "$2"
    }

    # interactive: pick the steps on a terminal
    if [ "$mode" = ask ] && [ -z "$only" ] && [ "$list" = 0 ] && menu_ready; then
        menu_title "octarineOS virtualization host"
        menu_multi "Virtualization host: choose the steps" \
            "check^Check: virtualization flag, /dev/kvm, virt-host-validate^1" \
            "daemons^Verify the modular libvirt daemons (sudo)^1" \
            "iommu^IOMMU kernel arguments for device passthrough (optional; sudo, reboot)^0" \
            "connection^libvirt group and default URI (sudo)^1" \
            "image-dir^VM image directory: ACL and SELinux label (sudo)^1" \
            "virtio^Download the virtio-win driver ISO^1" \
            "bridge^NetworkManager bridge for the LAN (optional; sudo, network blip)^0" \
            "libvirt-network^libvirt network on the bridge^0"
        if [ "${#MENU_RESULT[@]}" -eq 0 ]; then echo "Nothing selected; nothing changed."; exit 0; fi
        only=$(IFS=,; echo "${MENU_RESULT[*]}")
    fi
    if [ "$mode" = yes ] && [ -z "$only" ]; then only="check,daemons,connection,image-dir,virtio,libvirt-network"; fi

    if [ "$list" = 1 ]; then
        echo "Steps: $all_steps"
        printf '  check: %s\n' "$(has_cpu_virt && echo 'CPU virtualization flag present' || echo 'no vmx/svm flag')"
        printf '  iommu: %s (vendor %s)\n' "$(iommu_present && echo 'IOMMU present' || echo 'no IOMMU found')" "$(vendor)"
        exit 0
    fi

    # ---- check
    if selected check; then
        echo; echo "== check"
        v=$(vendor)
        if has_cpu_virt; then echo "  CPU virtualization flag: present ($v)"; else echo "  CPU virtualization flag: MISSING. Enable VT-x (Intel) or SVM (AMD) in the UEFI firmware."; fi
        if [ -e "$kvm_dev" ]; then
            if [ -r "$kvm_dev" ] && [ -w "$kvm_dev" ]; then echo "  $kvm_dev: present and accessible"; else echo "  $kvm_dev: present, not accessible for you (the libvirt group or the kvm group grants it: step connection)"; fi
        else echo "  $kvm_dev: missing (virtualization off in the firmware, or this is a VM without nested virtualization)"; fi
        if command -v lsmod >/dev/null 2>&1; then lsmod 2>/dev/null | grep -E '^kvm(_intel|_amd)? ' | awk '{print "  kernel module " $1}'; fi
        if command -v virt-host-validate >/dev/null 2>&1; then
            vout=$(virt-host-validate qemu 2>&1)
            echo "$vout" | sed 's/^/  /'
            if grep -Eqi 'IOMMU.*(WARN|FAIL)|DMAR' <<<"$vout"; then echo "  note: the IOMMU warning only matters for device passthrough: see the iommu step."; fi
            if grep -qi 'Secure Guest support' <<<"$vout"; then echo "  note: the AMD Secure Guest line is informational."; fi
        else echo "  virt-host-validate is not installed: skipped"; fi
        record check "checked" -
    fi

    # ---- daemons
    if selected daemons; then
        echo; echo "== daemons"
        socks=""; for d in virtqemud virtnetworkd virtstoraged virtnodedevd virtsecretd virtnwfilterd; do socks="$socks $d.socket $d-ro.socket $d-admin.socket"; done
        miss=(); for u in $socks; do [ "$(systemctl is-enabled "$u" 2>/dev/null)" = enabled ] || miss+=("$u"); done
        bad_legacy=(); for u in libvirtd.socket libvirtd.service; do [ "$(systemctl is-enabled "$u" 2>/dev/null)" = enabled ] && bad_legacy+=("$u"); done
        if [ "${#miss[@]}" -eq 0 ] && [ "${#bad_legacy[@]}" -eq 0 ]; then
            echo "  All modular sockets are enabled and libvirtd is not: already done."
            record daemons "already done"
        else
            [ "${#miss[@]}" -gt 0 ] && echo "  Not enabled: ${miss[*]}"
            [ "${#bad_legacy[@]}" -gt 0 ] && echo "  libvirtd is enabled but excludes the modular sockets (never enabled here): ${bad_legacy[*]}"
            echo "  Uses sudo (a security-key touch), once per command, never retried."
            if ! do_apply; then record daemons "plan only"
            elif ! confirm_or_default "Apply?" y; then record daemons "skipped"
            else
                ok=1
                [ "${#bad_legacy[@]}" -gt 0 ] && { run_sudo systemctl disable --now "${bad_legacy[@]}" || ok=0; }
                [ "${#miss[@]}" -gt 0 ] && [ "$ok" = 1 ] && { run_sudo systemctl enable --now "${miss[@]}" || ok=0; }
                if [ "$ok" = 1 ]; then record daemons applied "sudo systemctl disable --now ${miss[*]}"; else fail_step daemons "re-run: ujust virthost-setup --only daemons"; fi
            fi
        fi
    fi

    # ---- iommu
    if selected iommu; then
        echo; echo "== iommu"
        v=$(vendor)
        case "$v" in
            GenuineIntel) args=(intel_iommu=on iommu=pt) ;;
            AuthenticAMD) args=(iommu=pt) ;;
            *) args=() ;;
        esac
        if [ "${#args[@]}" -eq 0 ]; then echo "  Unknown CPU vendor '$v': nothing to set."; record iommu "skipped (unknown CPU)"
        elif ! iommu_present; then echo "  No IOMMU found: enable VT-d (Intel) or AMD-Vi/IOMMU in the UEFI firmware first."; record iommu "skipped (no IOMMU)"
        else
            echo "  iommu=pt matters only for passing devices through to VMs; on an Intel CPU intel_iommu=on is required as well (the Fedora kernel does not enable it by default). AMD's IOMMU is on by default."
            todo=(); for a in "${args[@]}"; do in_cmdline "$a" || todo+=("$a"); done
            if [ "${#todo[@]}" -eq 0 ]; then
                if OCTARINE_CMDLINE="$cmdline_file" kargs_pending_arg iommu=pt; then echo "  ${args[*]} already set, but pending a reboot: do not update the image before rebooting."; record iommu "already done (pending reboot)"
                else echo "  ${args[*]} already set."; record iommu "already done"; fi
            else
                cmd=(rpm-ostree kargs); for a in "${todo[@]}"; do cmd+=("--append-if-missing=$a"); done
                undo="sudo rpm-ostree kargs"; for a in "${args[@]}"; do undo="$undo --delete-if-present=$a"; done
                echo "  Needs a reboot. Undo: $undo"
                if ! do_apply; then echo "  Plan: sudo ${cmd[*]}"; record iommu "plan only"
                elif ! confirm_or_default "Apply?" n; then record iommu "skipped"
                else
                    if run_sudo "${cmd[@]}"; then kargs_notice "${todo[@]}"; record iommu "applied (reboot to take effect)" "$undo, then reboot"; else fail_step iommu "run the command above"; fi
                fi
            fi
        fi
    fi

    # ---- connection
    if selected connection; then
        echo; echo "== connection"
        grp_ok=0; id -nG "$user" 2>/dev/null | tr ' ' '\n' | grep -qx libvirt && grp_ok=1
        case ",$(getent group libvirt 2>/dev/null | cut -d: -f4)," in *",$user,"*) grp_ok=1 ;; esac
        conf_ok=0; grep -Eq '^uri_default *= *"qemu:///system"' "$conf" 2>/dev/null && conf_ok=1
        if [ "$grp_ok" = 1 ] && [ "$conf_ok" = 1 ]; then echo "  Group libvirt and the default URI are set: already done."; record connection "already done"
        else
            echo "  Joins the libvirt group (sudo, once) and sets uri_default = \"qemu:///system\" in $conf (so virsh and virt-manager see the same VMs). Log in again for the group."
            if ! do_apply; then record connection "plan only"
            elif ! confirm_or_default "Apply?" y; then record connection "skipped"
            else
                ok=1
                if [ "$grp_ok" = 0 ]; then run_sudo usermod -aG libvirt "$user" || ok=0; fi
                if [ "$ok" = 1 ] && [ "$conf_ok" = 0 ]; then
                    mkdir -p "$(dirname "$conf")" && { [ -f "$conf" ] && cp -p -- "$conf" "$conf.bak-$(date +%Y%m%d-%H%M%S)"; grep -v '^uri_default' "$conf" 2>/dev/null; printf 'uri_default = "qemu:///system"\n'; } >"$conf.new" && mv -f -- "$conf.new" "$conf" || ok=0
                fi
                if [ "$ok" = 1 ]; then record connection "applied (log in again)" "sudo gpasswd -d $user libvirt; remove the uri_default line from $conf"; else fail_step connection "re-run: ujust virthost-setup --only connection"; fi
            fi
        fi
    fi

    # ---- image-dir
    if selected image-dir; then
        echo; echo "== image-dir ($image_dir)"
        default_dir=0; [ "$image_dir" = /var/lib/libvirt/images ] && default_dir=1
        acl_ok=0
        if command -v getfacl >/dev/null 2>&1 && [ -d "$image_dir" ]; then
            gout=$(getfacl -p "$image_dir" 2>/dev/null)
            grep -qx "user:$user:rwx" <<<"$gout" && grep -qx "default:user:$user:rwx" <<<"$gout" && acl_ok=1
        fi
        ctx_ok=0; if [ -d "$image_dir" ] && command -v ls >/dev/null 2>&1 && ls -Zd "$image_dir" 2>/dev/null | grep -q virt_image_t; then ctx_ok=1; fi
        if [ "$acl_ok" = 1 ] && [ "$ctx_ok" = 1 ]; then echo "  ACL and SELinux type are already right: already done."; record image-dir "already done"
        else
            echo "  Plan: ${default_dir:+default directory: }ACL for $user (and default ACL for new files)$([ "$default_dir" = 0 ] && echo ', search access for qemu on every parent, SELinux type virt_image_t'); sudo, once per command."
            if ! do_apply; then record image-dir "plan only"
            elif ! confirm_or_default "Apply?" y; then record image-dir "skipped"
            else
                ok=1
                [ -d "$image_dir" ] || { run_sudo mkdir -p "$image_dir" || ok=0; }
                if [ "$ok" = 1 ] && [ "$acl_ok" = 0 ]; then
                    run_sudo setfacl -m "u:$user:rwx" "$image_dir" || ok=0
                    [ "$ok" = 1 ] && { run_sudo setfacl -d -m "u:$user:rwx" "$image_dir" || ok=0; }
                fi
                if [ "$ok" = 1 ] && [ "$default_dir" = 0 ]; then
                    p=$(dirname "$image_dir")
                    while [ "$p" != / ] && [ -n "$p" ]; do
                        if ! getfacl -p "$p" 2>/dev/null | grep -q '^user:qemu:..x'; then run_sudo setfacl -m u:qemu:x "$p" || { ok=0; break; }; fi
                        p=$(dirname "$p")
                    done
                    if [ "$ok" = 1 ] && [ "$ctx_ok" = 0 ]; then
                        if command -v semanage >/dev/null 2>&1; then
                            run_sudo semanage fcontext -a -t virt_image_t "$image_dir(/.*)?" && run_sudo restorecon -R "$image_dir" || ok=0
                        else
                            echo "  semanage is not installed: using chcon, which is NOT persistent across relabels."
                            run_sudo chcon -R -t virt_image_t "$image_dir" || ok=0
                        fi
                    fi
                    if [ "$ok" = 1 ] && [ -n "$pool_name" ] && command -v virsh >/dev/null 2>&1; then
                        if virsh -c qemu:///system pool-info "$pool_name" >/dev/null 2>&1; then echo "  storage pool $pool_name exists."
                        else
                            echo "  virsh -c qemu:///system pool-define-as --name $pool_name --type dir --target $image_dir (then pool-build, pool-start, pool-autostart)"
                            virsh -c qemu:///system pool-define-as --name "$pool_name" --type dir --target "$image_dir" && virsh -c qemu:///system pool-build "$pool_name" && virsh -c qemu:///system pool-start "$pool_name" && virsh -c qemu:///system pool-autostart "$pool_name" || ok=0
                        fi
                    fi
                fi
                if [ "$ok" = 1 ]; then record image-dir applied "sudo setfacl -x u:$user $image_dir; sudo setfacl -k $image_dir (defaults); a custom directory: sudo semanage fcontext -d '$image_dir(/.*)?'"; else fail_step image-dir "re-run: ujust virthost-setup --only image-dir --image-dir $image_dir"; fi
            fi
        fi
    fi

    # ---- virtio
    if selected virtio; then
        echo; echo "== virtio (driver ISO for Windows guests)"
        if [ ! -d "$image_dir" ]; then echo "  $image_dir does not exist: run the image-dir step first."; record virtio "skipped (no image directory)"
        elif [ "$force" = 0 ] && ls "$image_dir"/virtio-win*.iso >/dev/null 2>&1; then echo "  A virtio-win ISO is already in $image_dir: already done (--force downloads again)."; record virtio "already done"
        else
            url="https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/${virtio_kind}-virtio/virtio-win.iso"
            echo "  Downloads $url (stable roughly tracks RHEL; latest-virtio may be a pre-release) into $image_dir. No checksum or signature is published: the sha256 computed here is recorded next to the file; it proves nothing about the source."
            if ! do_apply; then record virtio "plan only"
            elif ! confirm_or_default "Download (about 900 MB)?" y; then record virtio "skipped"
            else
                part="$image_dir/virtio-win.iso.part"
                if eff=$(curl -fL --proto '=https' --proto-redir '=https' --retry 3 -C - -o "$part" -w '%{url_effective}' "$url") && [ -s "$part" ] && [ "$(wc -c <"$part")" -gt "${VIRTHOST_VIRTIO_MIN:-100000000}" ]; then
                    fname=$(basename "${eff%%\?*}"); case "$fname" in *.iso) ;; *) fname="virtio-win-$virtio_kind.iso" ;; esac
                    mv -f -- "$part" "$image_dir/$fname" && ln -sfn "$fname" "$image_dir/virtio-win.iso"
                    sum=$(sha256sum "$image_dir/$fname" | cut -d' ' -f1)
                    echo "$sum  $fname" >"$image_dir/$fname.sha256"
                    echo "  Saved $image_dir/$fname (sha256 $sum, recorded in $fname.sha256; not verified against anything)."
                    record virtio applied "rm $image_dir/$fname $image_dir/$fname.sha256 $image_dir/virtio-win.iso"
                else
                    rm -f -- "${part:?}"
                    echo "  FAILED to download (offline, interrupted, or the host blocks scripts). Fetch it by hand: $url" >&2
                    fail_step virtio "download $url into $image_dir"
                fi
            fi
        fi
    fi

    # ---- bridge
    if selected bridge; then
        echo; echo "== bridge ($br)"
        if ! command -v nmcli >/dev/null 2>&1; then echo "  nmcli is not available."; record bridge "skipped (no NetworkManager)"
        elif [ -n "${SSH_CONNECTION:-}" ] && [ "$yes_remote" = 0 ]; then echo "  Refused: this looks like an SSH session and the network will blip. Run it from the console, or pass --yes-remote."; record bridge "skipped (remote session)"
        else
            cons=$(nmcli -t -f NAME,TYPE connection show 2>/dev/null)
            if grep -qx "$br:bridge" <<<"$cons" && grep -q "^$br-[^:]*:" <<<"$cons"; then echo "  Bridge $br and a port profile already exist: already done."; record bridge "already done"
            else
                devs=$(nmcli -t -f DEVICE,TYPE device status 2>/dev/null)
                nic="$nic_want"
                if [ -z "$nic" ]; then
                    defdev=$(ip -o route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
                    cands=$(awk -F: '$2 == "ethernet" && $1 !~ /^(br|virbr|veth|docker|tailscale)/ { print $1 }' <<<"$devs")
                    if [ -n "$defdev" ] && grep -qx "$defdev" <<<"$cands"; then nic=$defdev
                    elif [ "$(echo "$cands" | grep -c .)" = 1 ]; then nic=$cands
                    elif [ -z "$cands" ] && grep -q ':wifi$' <<<"$devs"; then echo "  Refused: only Wi-Fi found; bridging does not work over Wi-Fi (station mode)."; record bridge "skipped (Wi-Fi only)"; nic="-"
                    else echo "  Could not pick the wired NIC. Candidates: $(echo $cands | tr '\n' ' '). Name it with --nic IFACE."; record bridge "skipped (NIC not chosen)"; nic="-"; fi
                fi
                if [ "$nic" != "-" ]; then
                    if grep -qx "$nic:wifi" <<<"$devs"; then echo "  Refused: $nic is Wi-Fi; bridging does not work over Wi-Fi (station mode)."; record bridge "skipped (Wi-Fi)"
                    else
                        old=$(nmcli -g GENERAL.CONNECTION device show "$nic" 2>/dev/null)
                        ip4=$(ip -o -4 addr show dev "$nic" 2>/dev/null | awk '{print $4}' | head -n1)
                        undo="sudo nmcli connection up '$old'; sudo nmcli connection modify '$old' connection.autoconnect yes; sudo nmcli connection delete $br-$nic; sudo nmcli connection delete $br"
                        echo "  Plan: NIC $nic (profile '${old:-none}', address ${ip4:-none}) becomes a port of the bridge $br with DHCP (IPv4 and IPv6 automatic). The old profile is kept with autoconnect off."
                        echo "  Undo: $undo"
                        if ! do_apply; then record bridge "plan only"
                        elif ! confirm_or_default "Change the network now (it can drop for a moment)?" n; then record bridge "skipped"
                        else
                            ok=1
                            run_sudo nmcli connection add type bridge con-name "$br" ifname "$br" bridge.stp no connection.autoconnect-ports yes ipv4.method auto ipv6.method auto || ok=0
                            [ "$ok" = 1 ] && { run_sudo nmcli connection add type ethernet con-name "$br-$nic" ifname "$nic" connection.port-type bridge connection.controller "$br" || ok=0; }
                            [ "$ok" = 1 ] && [ -n "$old" ] && { run_sudo nmcli connection modify "$old" connection.autoconnect no || ok=0; }
                            [ "$ok" = 1 ] && { run_sudo nmcli connection up "$br" && run_sudo nmcli connection up "$br-$nic" || ok=0; }
                            if [ "$ok" = 1 ]; then record bridge applied "$undo"; else fail_step bridge "undo: $undo"; fi
                        fi
                    fi
                fi
            fi
        fi
    fi

    # ---- libvirt-network
    if selected libvirt-network; then
        echo; echo "== libvirt-network (nwbridge on $br)"
        if ! command -v virsh >/dev/null 2>&1; then echo "  virsh is not installed."; record libvirt-network "skipped (no virsh)"
        elif virsh -c qemu:///system net-info nwbridge >/dev/null 2>&1; then echo "  The network nwbridge exists: already done."; record libvirt-network "already done"
        elif ! { nmcli -t -f NAME,TYPE connection show 2>/dev/null | grep -qx "$br:bridge" || [ -e "$net_dir/$br/bridge" ]; }; then echo "  The host bridge $br does not exist: run the bridge step first (or name one with --bridge)."; record libvirt-network "skipped (no bridge)"
        else
            echo "  Defines <network><name>nwbridge</name><forward mode='bridge'/><bridge name='$br'/></network>, starts it and sets autostart. The default NAT network stays. Undo: virsh -c qemu:///system net-destroy nwbridge; virsh -c qemu:///system net-undefine nwbridge"
            if ! do_apply; then record libvirt-network "plan only"
            elif ! confirm_or_default "Apply?" y; then record libvirt-network "skipped"
            else
                xml=$(mktemp)
                printf "<network><name>nwbridge</name><forward mode='bridge'/><bridge name='%s'/></network>\n" "$br" >"$xml"
                if virsh -c qemu:///system net-define "$xml" && virsh -c qemu:///system net-start nwbridge && virsh -c qemu:///system net-autostart nwbridge; then record libvirt-network applied "virsh -c qemu:///system net-destroy nwbridge; virsh -c qemu:///system net-undefine nwbridge"; else fail_step libvirt-network "re-run: ujust virthost-setup --only libvirt-network"; fi
                rm -f -- "${xml:?}"
            fi
        fi
    fi

    echo
    echo "== Summary"
    for k in "${!names[@]}"; do printf '  %-16s %s\n' "${names[$k]}" "${results[$k]}"; done
    echo "To undo (per step):"
    for k in "${!names[@]}"; do [ "${undos[$k]}" != - ] && echo "  ${names[$k]}: ${undos[$k]}"; done
    exit "$failed"

