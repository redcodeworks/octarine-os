#!/usr/bin/env bash
# Behavior checks of the developer image (octarine-os-dx) that no build shows early: the signature policy of all three repositories, the dx.sh bundle
# policy block, the in-image smoke script (stub tools) and `just dev-packages-bump` with fake skopeo and cosign. Workflow shape, Containerfile text and
# package lists are not asserted: a wrong one fails the build itself. Nothing here builds an image. Run: tests/dx-image.sh
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
keys_doc=$here/docs/signing-keys.md   # the one place that names the keys document
wf="$here/.github/workflows/build-dx.yml"
root=$(mktemp -d)
trap 'rm -rf -- "$root"' EXIT
pass=0
failn=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { failn=$((failn + 1)); echo "FAIL $1"; [ -f "$root/out" ] && sed 's/^/     /' "$root/out"; }
check() { local d=$1; shift; if "$@" >"$root/out" 2>&1; then ok "$d"; else bad "$d"; fi; }

# ---- Containerfile, scripts and package lists
cf="$here/variants/dx/Containerfile"
tag=$(sed -n 's/^ARG DEV_PACKAGES_TAG=//p' "$cf")
dig=$(sed -n 's/^ARG DEV_PACKAGES_DIGEST=//p' "$cf")

# ---- signature policy: all three repositories, from any image name
policy_run() { # image name
    local t="$root/pol-$1"
    mkdir -p "$t/etc/containers/registries.d" "$t/etc/pki/containers"
    echo '{"default":[{"type":"insecureAcceptAnything"}],"transports":{"docker":{"":[{"type":"insecureAcceptAnything"}]}}}' >"$t/etc/containers/policy.json"
    sed -n '/^# --- Container signature policy/,/^# --- end signature policy ---/p' "$here/build_files/build.sh" \
        | sed -e "s#/etc/#$t/etc/#g" -e "s#/ctx/cosign.pub#$here/cosign.pub#g" >"$t/block.sh"
    IMAGE_ORG=redcodeworks IMAGE_NAME="$1" bash -e "$t/block.sh" >"$root/out" 2>&1
}
for n in octarine-os octarine-os-nvidia octarine-os-dx octarine-os-nvidia-dx; do
    policy_run "$n"
    for r in octarine-os octarine-os-nvidia octarine-os-dx octarine-os-nvidia-dx; do
        check "policy ($n image): sigstoreSigned rule for ghcr.io/redcodeworks/$r" python3 -c "
import json
d = json.load(open('$root/pol-$n/etc/containers/policy.json'))['transports']['docker']['ghcr.io/redcodeworks/$r']
assert d[0]['type'] == 'sigstoreSigned' and d[0]['signedIdentity'] == {'type': 'matchRepository'} and d[0]['keyPath'].endswith('.pub')"
    done
    check "policy ($n image): the catch-all stays last" python3 -c "import json; d=json.load(open('$root/pol-$n/etc/containers/policy.json'))['transports']['docker']; assert list(d)[-1]==''"
    check "policy ($n image): sigstore attachments enabled for the namespace" grep -q 'use-sigstore-attachments: true' "$root"/pol-$n/etc/containers/registries.d/*.yaml
done
# the dx.sh block that adds the policy for the datastore bundle: run on a copy of the default policy
bt="$root/bundlepol"; mkdir -p "$bt/etc/containers/registries.d" "$bt/etc/pki/containers"
echo '{"default":[{"type":"insecureAcceptAnything"}],"transports":{"docker":{"ghcr.io/redcodeworks/octarine-os":[{"type":"sigstoreSigned","keyPath":"/k","signedIdentity":{"type":"matchRepository"}}],"":[{"type":"insecureAcceptAnything"}]}}}' >"$bt/etc/containers/policy.json"
sed -n '/^# --- datastore bundle signature policy ---/,/^# --- end datastore bundle signature policy ---/p' "$here/variants/dx/dx.sh" | sed -e "s#/etc/#$bt/etc/#g" -e "s#/ctx/toolbox-cosign.pub#$here/keys/redcodeworks-toolbox-cosign.pub#g" >"$bt/block.sh"
check "dx.sh bundle policy: the block runs" bash -e "$bt/block.sh"
check "dx.sh bundle policy: a sigstoreSigned rule for the bundle repository with the toolbox key, the image's own rules and the catch-all kept, catch-all last" python3 -I - "$bt" "$here/keys/redcodeworks-toolbox-cosign.pub" <<'PY'
import json, sys
bt, pub = sys.argv[1:]
d = json.load(open(bt + "/etc/containers/policy.json"))["transports"]["docker"]
r = d["ghcr.io/redcodeworks/datastore-images"]
assert len(r) == 1 and r[0]["type"] == "sigstoreSigned" and r[0]["signedIdentity"] == {"type": "matchRepository"}
assert open(r[0]["keyPath"]).read() == open(pub).read()
assert "ghcr.io/redcodeworks/octarine-os" in d and list(d)[-1] == ""
PY
check "dx.sh bundle policy: registries.d reads the signature attachments of exactly the bundle repository" bash -c "grep -q 'ghcr.io/redcodeworks/datastore-images:' '$bt'/etc/containers/registries.d/*.yaml && grep -q 'use-sigstore-attachments: true' '$bt'/etc/containers/registries.d/*.yaml"

# ---- the in-image smoke script with stub tools
smoke="$here/.github/scripts/dx-smoke.sh"
check "smoke: bash syntax, no producer-pipe-into-grep -q (pipefail)" bash -c "bash -n '$smoke' && ! grep -v '^[[:space:]]*#' '$smoke' | grep -nE '\\|[[:space:]]*grep -q'"
sb="$root/sb"
mk_world() { # kernel dir name; rebuilds the stub world: a passing dx image
    rm -rf "$sb"; mkdir -p "$sb/bin" "$sb/sys" "$sb/modules/$1" "$sb/units" "$sb/pre" "$sb/share/ublue-os/just" "$sb/share/octarine-os/lib" "$sb/share/ublue-os/distrobox" "$sb/etc/profile.d" "$sb/etc/default" "$sb/lib/bootc/kargs.d" "$sb/usr-bin" "$sb/share/fish/vendor_conf.d"
    for c in bash sh grep sed ls basename tr sort head cat python3 dirname; do p=$(command -v "$c") && ln -sf "$p" "$sb/sys/$c"; done
    for c in gcc g++ clang cmake ninja meson gdb pkgconf uv rustup-init fish qemu-kvm virt-manager virt-viewer virt-install visudo; do printf '#!/bin/sh\nexit 0\n' >"$sb/bin/$c"; done
    printf '#!/bin/sh\necho "dev niri-setup user-setup"\n' >"$sb/bin/ujust"
    cat >"$sb/bin/rpm" <<'F'
#!/usr/bin/env bash
# rpm -q NAME: ok when NAME is in $RPM_LIST; rpm -qa [glob]: print the list
if [[ "$1" == -qa ]]; then cat "$RPM_LIST"; exit 0; fi
shift
rc=0; for p in "$@"; do grep -qxF -- "$p" "$RPM_LIST" || rc=1; done; exit "$rc"
F
    cat >"$sb/bin/systemctl" <<'F'
#!/usr/bin/env bash
[[ -n "${SYSTEMCTL_FAIL:-}" && "$*" == *"${SYSTEMCTL_FAIL}"* ]] && exit 1
exit 0
F
    cat >"$sb/bin/pkgconf" <<'F'
#!/usr/bin/env bash
exit "${PKGCONF_RC:-0}"
F
    chmod +x "$sb/bin"/*
    echo initramfs >"$sb/modules/$1/initramfs.img"
    touch "$sb/units/libvirtd.service" "$sb/units/virtqemud.service" "$sb/units/virtnetworkd.service" "$sb/units/virtstoraged.service"
    printf '[Flatpak Preinstall io.github.kolunmi.Bazaar]\nBranch=stable\n' >"$sb/pre/tools.preinstall"
    printf '[Flatpak Preinstall org.gnome.Example]\nBranch=stable\n' >"$sb/pre/gnome.preinstall"
    echo x >"$sb/share/ublue-os/just/70-octarine-dev.just"; echo 'import? "/usr/share/ublue-os/just/70-octarine-dev.just"' >"$sb/share/ublue-os/justfile"
    printf '#!/bin/sh\nexit 0\n' >"$sb/usr-bin/sdk"; chmod +x "$sb/usr-bin/sdk"
    printf 'GROUP=100\nSHELL=/bin/bash\n' >"$sb/etc/default/useradd"
    echo x >"$sb/share/ublue-os/just/72-octarine-datastore.just"; echo x >"$sb/share/ublue-os/just/75-octarine-virthost.just"
    mkdir -p "$sb/etc/containers/registries.d" "$sb/etc/pki/containers"; cp "$here/keys/redcodeworks-toolbox-cosign.pub" "$sb/etc/pki/containers/redcodeworks-toolbox.pub"
    printf 'docker:\n  ghcr.io/redcodeworks/datastore-images:\n    use-sigstore-attachments: true\n' >"$sb/etc/containers/registries.d/redcodeworks-datastore-images.yaml"
    echo 'PATH="$PATH:$HOME/.cargo/bin"' >"$sb/etc/profile.d/octarine-dx-cargo.sh"; echo 'fish_add_path --append $HOME/.cargo/bin' >"$sb/share/fish/vendor_conf.d/octarine-os-30-rustup.fish"
    echo x >"$sb/share/ublue-os/just/60-custom.just"; echo x >"$sb/share/octarine-os/lib/menu.sh"; echo '[dev-toolbox]' >"$sb/share/ublue-os/distrobox/dev-toolbox.ini"
    printf 'ID=fedora\nPRETTY_NAME="octarineOS"\nIMAGE_ID="octarine-os-dx"\nIMAGE_VERSION="%s"\n' "${OS_IMAGE_VERSION:-20261110-abc1234}" >"$sb/os-release"
    echo '{"transports":{"docker":{"ghcr.io/redcodeworks/octarine-os":[],"ghcr.io/redcodeworks/octarine-os-nvidia":[],"ghcr.io/redcodeworks/octarine-os-dx":[],"ghcr.io/redcodeworks/octarine-os-nvidia-dx":[],"ghcr.io/redcodeworks/datastore-images":[{"type":"sigstoreSigned","keyPath":"/etc/pki/containers/redcodeworks-toolbox.pub","signedIdentity":{"type":"matchRepository"}}],"":[]}}}' >"$sb/policy.json"
    printf '%s\n' rustup libvirt qemu-kvm cockpit-machines virt-manager virt-viewer virtiofsd swtpm swtpm-tools edk2-ovmf libvirt-nss dnsmasq glib2-devel openssl-devel pam-u2f snapper tailscale borgbackup zsh distrobox fwupd flatpak gnome-shell bcc >"$sb/rpms"
}
smoke_run() { # BASE_KERNEL
    PATH="$sb/bin:$sb/sys" RPM_LIST="$sb/rpms" MODULES_DIR="$sb/modules" UNIT_DIR="$sb/units" PREINSTALL_DIR="$sb/pre" \
        POLICY_FILE="$sb/policy.json" OS_RELEASE="$sb/os-release" SHARE_DIR="$sb/share" ETC_DIR="$sb/etc" BIN_DIR="$sb/usr-bin" LIB_DIR="$sb/lib" BASE_KERNEL="$1" QUADLET_GENERATOR="$sb/no-generator" \
        bash "$smoke" >"$root/smoke.out" 2>&1
}
K=7.2.15-300.fc45.x86_64
mk_world "$K"; smoke_run "$K"; check "smoke: a complete dx image passes" test $? -eq 0
mk_world "$K"; rm "$sb/bin/clang"; smoke_run "$K"; rc=$?
check "smoke: a missing compiler fails and says which" bash -c "[ $rc -ne 0 ] && grep -q 'FAIL command clang' '$root/smoke.out'"
# a long package list with the match first: grep -q on a pipe must not turn SIGPIPE into a failure
mk_world "$K"; { cat "$sb/rpms"; for i in $(seq 1 20000); do echo "pkg-$i"; done; } >"$sb/r2"; mv "$sb/r2" "$sb/rpms"; smoke_run "$K"; check "smoke: a very long package list still passes" test $? -eq 0

# ---- just dev-packages-bump with fake skopeo and cosign
work="$root/work"; bin="$root/bin"
mkdir -p "$bin" "$work/keys" "$work/variants/dx"
cp "$here/Justfile" "$work/Justfile"; cp "$cf" "$work/variants/dx/Containerfile"
echo key >"$work/keys/redcodeworks-toolbox-cosign.pub"
mkdir -p "$work/config"; cp "$here/config/image.env" "$work/config/image.env"
[ -d "$here/githooks" ] && cp -r "$here/githooks" "$work/githooks"
cat >"$bin/skopeo" <<'F'
#!/usr/bin/env bash
echo "skopeo $*" >>"$LOG"
case "$1" in
    inspect) printf 'manifest of %s' "${@: -1}" ;;
    list-tags) echo '{"Tags":["latest","testing","latest-20261105-aaaaaaa","latest-20261109-0969783","latest-20261112-bbbbbbb","testing-20261112-ccccccc"]}' ;;
esac
F
cat >"$bin/cosign" <<'F'
#!/usr/bin/env bash
echo "cosign $*" >>"$LOG"
exit "${COSIGN_RC:-0}"
F
chmod +x "$bin"/*
export LOG="$root/log"
REAL_JUST=$(command -v just)
bump() { (cd "$work" && PATH="$bin:$PATH" "$REAL_JUST" --justfile Justfile --working-directory . dev-packages-bump "$@") >"$root/out" 2>&1; rc=$?; }
expect_digest() { printf 'manifest of docker://ghcr.io/redcodeworks/dev-packages:%s' "$1" | sha256sum | sed 's/ .*//'; }
: >"$LOG"; bump latest-20261105-aaaaaaa
check "bump with a dated tag: exit 0, digest from the raw manifest, tag written" bash -c "[ $rc = 0 ] && grep -qx 'ARG DEV_PACKAGES_DIGEST=sha256:$(expect_digest latest-20261105-aaaaaaa)' '$work/variants/dx/Containerfile' && grep -qx 'ARG DEV_PACKAGES_TAG=latest-20261105-aaaaaaa' '$work/variants/dx/Containerfile'"
check "bump: cosign verified the digest reference with the toolbox key first" grep -qF "cosign verify --key keys/redcodeworks-toolbox-cosign.pub ghcr.io/redcodeworks/dev-packages@sha256:$(expect_digest latest-20261105-aaaaaaa)" "$LOG"
check "bump: the rest of the Containerfile is untouched" bash -c "diff <(grep -vE '^ARG DEV_PACKAGES_(TAG|DIGEST)=' '$cf') <(grep -vE '^ARG DEV_PACKAGES_(TAG|DIGEST)=' '$work/variants/dx/Containerfile')"
cp "$cf" "$work/variants/dx/Containerfile"; COSIGN_RC=1 bump latest-20261109-0969783
check "bump: a verification failure exits 1 and leaves the Containerfile unchanged" bash -c "[ $rc = 1 ] && cmp -s '$cf' '$work/variants/dx/Containerfile'"
bump 'latest;rm'
check "bump: a bad tag is refused and changes nothing" bash -c "[ $rc = 1 ] && cmp -s '$cf' '$work/variants/dx/Containerfile'"
bump
check "bump with no tag resolves latest and records the dated tag that has the same digest" bash -c "[ $rc = 0 ] && grep -qx 'ARG DEV_PACKAGES_TAG=latest' '$work/variants/dx/Containerfile' && grep -qx 'ARG DEV_PACKAGES_DIGEST=sha256:$(expect_digest latest)' '$work/variants/dx/Containerfile'"
# with this fake registry every tag has its own manifest, so no dated tag matches latest and the tag stays latest (above);
# make latest-20261109-0969783 identical to latest to see the alias found
cat >"$bin/skopeo" <<'F'
#!/usr/bin/env bash
case "$1" in
    inspect) ref="${@: -1}"; [[ "${ref}" == *:latest-20261109-0969783 ]] && ref="${ref%:*}:latest"; printf 'manifest of %s' "${ref}" ;;
    list-tags) echo '{"Tags":["latest","testing","latest-20261105-aaaaaaa","latest-20261109-0969783","testing-20261112-ccccccc"]}' ;;
esac
F
cp "$cf" "$work/variants/dx/Containerfile"; bump
check "bump latest: the matching dated tag is written for humans, testing tags are ignored" bash -c "[ $rc = 0 ] && grep -qx 'ARG DEV_PACKAGES_TAG=latest-20261109-0969783' '$work/variants/dx/Containerfile'"

echo "passed: $pass, failed: $failn"
[ "$failn" = 0 ]
