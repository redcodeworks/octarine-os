#!/usr/bin/env bash
# Checks run INSIDE the built octarine-os-dx image (build-dx.yml mounts this file and runs it with bash):
# the developer toolchain, the VM tooling, the kernel of the base image, the dx-only Flatpak list, and the checks of the
# default image's smoke test (build.yml) that still apply to a layer on top of it.
#
# Environment: BASE_KERNEL (the kernel release of the base image: the dx image must carry exactly that one kernel).
# IMAGE_CHANNEL (latest or beta, default latest: beta images carry a `beta-` IMAGE_VERSION).
# EXPECT_IMAGE_ID (default octarine-os-dx; octarine-os-nvidia-dx for the same layer on the NVIDIA variant).
# For tests only: MODULES_DIR, UNIT_DIR, PREINSTALL_DIR, POLICY_FILE, OS_RELEASE, SHARE_DIR, ETC_DIR, BIN_DIR, LIB_DIR.
#
# Under pipefail never write `producer | grep -q` (grep quits at the first match, the producer dies of SIGPIPE and the
# pipeline fails: the NVIDIA initramfs check was red for that reason). Output goes to a variable or a file first.
set -uo pipefail

modules_dir="${MODULES_DIR:-/usr/lib/modules}"
unit_dir="${UNIT_DIR:-/usr/lib/systemd/system}"
preinstall_dir="${PREINSTALL_DIR:-/usr/share/flatpak/preinstall.d}"
policy_file="${POLICY_FILE:-/etc/containers/policy.json}"
os_release="${OS_RELEASE:-/etc/os-release}"
share_dir="${SHARE_DIR:-/usr/share}"
etc_dir="${ETC_DIR:-/etc}"
bin_dir="${BIN_DIR:-/usr/bin}"
lib_dir="${LIB_DIR:-/usr/lib}"
case "${IMAGE_CHANNEL:-latest}" in
    beta) version_re='beta-[0-9]{8}-[0-9a-f]{7,}' ;;
    *) version_re='[0-9]{8}-[0-9a-f]{7,}' ;;
esac
fail=0
check() { if eval "$2" >/dev/null 2>&1; then echo "PASS $1"; else echo "FAIL $1"; fail=1; fi; }
have() { command -v "$1" >/dev/null 2>&1; }
# the module directories of the image, one per line (empty when there are none)
kernels() { local d; for d in "${modules_dir}"/*/; do [ -d "${d}" ] && basename "${d}"; done; }
kernel_count() { local k; k=$(kernels); if [ -z "${k}" ]; then echo 0; else grep -c . <<<"${k}"; fi; }
one_kernel() { [ "$(kernel_count)" = 1 ]; }
kernel_is_base() { local k; k=$(kernels); [ -n "${BASE_KERNEL:-}" ] && [ "${k}" = "${BASE_KERNEL}" ]; }
# ujust --summary prints the recipe names on one line; capture first, never pipe into grep -q (pipefail)
lists_dev() { local o; o=$(ujust --summary 2>&1) || return 1; o=${o//$'\n'/ }; [[ " ${o} " == *" dev "* ]]; }
has_text() { # file, fixed text
    [ -r "$1" ] && grep -qF -- "$2" "$1"
}

echo "== developer toolchain (the shared list from the dev-packages image)"
for c in gcc g++ clang cmake ninja meson gdb pkgconf uv fish; do
    check "command ${c}" "have ${c}"
done
# Fedora's rustup RPM ships rustup-init only; the `rustup` command appears after a user runs rustup-init
check "package rustup" "rpm -q rustup"
check "command rustup-init" "have rustup-init"
for p in glib2-devel openssl-devel; do
    check "package ${p}" "rpm -q ${p}"
done
check "pkgconf finds glib-2.0 and openssl" "pkgconf --exists glib-2.0 openssl"

echo "== virtualization (extras.txt)"
for p in rocminfo rocm-smi rocm-hip rocm-opencl hipcc; do
    check "ROCm package ${p} is NOT installed (ujust hardware-setup provides ROCm in a distrobox)" "! rpm -q ${p}"
done
check "package qemu-kvm" "rpm -q qemu-kvm"
check "qemu-kvm binary" "have qemu-kvm || test -x /usr/libexec/qemu-kvm"
for c in virt-manager virt-viewer virt-install; do
    check "command ${c}" "have ${c}"
done
check "libvirtd.service present" "test -e ${unit_dir}/libvirtd.service"
check "virtqemud.service present" "test -e ${unit_dir}/virtqemud.service"
for p in libvirt cockpit-machines virtiofsd swtpm edk2-ovmf; do
    check "package ${p}" "rpm -q ${p}"
done

echo "== developer menu (ujust dev) and its files"
check "ujust lists the dev recipe" "lists_dev"
check "the dev recipe file is shipped" "test -s ${share_dir}/ublue-os/just/70-octarine-dev.just"
check "the ujust main justfile imports the dev recipe file" "has_text ${share_dir}/ublue-os/justfile '70-octarine-dev.just'"
check "the sdk wrapper is executable" "test -x ${bin_dir}/sdk"
check "the cargo PATH snippet for sh exists and parses" "test -s ${etc_dir}/profile.d/octarine-dx-cargo.sh && sh -n ${etc_dir}/profile.d/octarine-dx-cargo.sh"
check "the fish rustup snippet adds ~/.cargo/bin" "has_text ${share_dir}/fish/vendor_conf.d/octarine-os-30-rustup.fish 'fish_add_path'"

echo "== tracing and developer extras (informational)"
for p in bcc bpftrace trace-cmd numactl git-subtree git-svn ydotool cascadia-code-fonts; do
    if rpm -q "${p}" >/dev/null 2>&1; then echo "INFO extra package ${p} installed"; else echo "INFO extra package ${p} NOT installed"; fi
done

echo "== kernel argument (dx only)"
check "iommu=pt karg file is shipped" "has_text ${lib_dir}/bootc/kargs.d/10-iommu.toml 'iommu=pt'"

echo "== services and Flatpak"
check "podman.socket enabled" "systemctl is-enabled podman.socket"
check "no VS Code and no virt-manager Flatpak in any preinstall list (ujust dev installs VS Code on request; virt-manager is the RPM)" "! grep -rqE 'visualstudio|virt_manager' ${preinstall_dir}"
check "the default Flatpak lists are still there" "test -s ${preinstall_dir}/gnome.preinstall && has_text ${preinstall_dir}/tools.preinstall '[Flatpak Preinstall io.github.kolunmi.Bazaar]'"

echo "== kernel"
kver=$(kernels); kver=${kver%%$'\n'*}
check "exactly one kernel is installed" "one_kernel"
check "the kernel is the one of the base image (${BASE_KERNEL:-unset})" "kernel_is_base"
check "the initramfs for the kernel exists" "test -s ${modules_dir}/${kver}/initramfs.img"

echo "== checks of the default image that still apply"
check "release is Fedora" "grep -qx ID=fedora ${os_release}"
check "pretty name" "grep -qx 'PRETTY_NAME=\"octarineOS\"' ${os_release}"
check "image id" "grep -qx 'IMAGE_ID=\"${EXPECT_IMAGE_ID:-octarine-os-dx}\"' ${os_release}"
check "image version has the build's version format (${IMAGE_CHANNEL:-latest})" "grep -qE '^IMAGE_VERSION=\"${version_re}\"\$' ${os_release}"
check "signature policy parses" "python3 -m json.tool ${policy_file}"
for r in octarine-os octarine-os-nvidia octarine-os-dx octarine-os-nvidia-dx; do
    check "signature policy has a rule for ghcr.io/redcodeworks/${r}" "has_text ${policy_file} '\"ghcr.io/redcodeworks/${r}\"'"
done
check "sudoers valid" "visudo -c"
check "new users do not default to zsh" "! has_text ${etc_dir}/default/useradd SHELL=/usr/bin/zsh"
check "enabled brew-setup.service" "systemctl is-enabled brew-setup.service"
check "enabled (global) podman.socket" "systemctl --global is-enabled podman.socket"
check "ujust custom recipes" "test -f ${share_dir}/ublue-os/just/60-custom.just"
check "menu helper library shipped" "test -s ${share_dir}/octarine-os/lib/menu.sh"
check "dev-toolbox definition" "has_text ${share_dir}/ublue-os/distrobox/dev-toolbox.ini '[dev-toolbox]'"
for p in pam-u2f snapper tailscale borgbackup zsh distrobox; do
    check "package ${p}" "rpm -q ${p}"
done
check "firefox removed" "! rpm -q firefox"
check "toolbox removed" "! rpm -q toolbox"
check "gnome-software removed" "! rpm -q gnome-software"
for p in fwupd flatpak gnome-shell; do check "package ${p} still installed" "rpm -q ${p}"; done

if [ "${fail}" != 0 ]; then
    echo "== DIAGNOSTICS (a check failed)"
    echo "DIAG kernels found (${modules_dir}): $(kernels | tr '\n' ' ')"
    echo "DIAG BASE_KERNEL: ${BASE_KERNEL:-unset}"
    echo "DIAG kernel packages: $(rpm -qa 'kernel*' 2>&1 | sort | tr '\n' ' ')"
    missing=""
    for p in gcc gcc-c++ clang cmake ninja-build meson gdb pkgconf uv rustup fish glib2-devel openssl-devel qemu-kvm virt-manager virt-viewer virt-install libvirt; do
        rpm -q "${p}" >/dev/null 2>&1 || missing="${missing} ${p}"
    done
    echo "DIAG developer and VM packages not installed:${missing:- none}"
    echo "DIAG package count: $(rpm -qa 2>/dev/null | grep -c . || true)"
    echo "DIAG libvirt and podman units in ${unit_dir}:"; ls "${unit_dir}" 2>&1 | grep -E 'libvirtd|virtqemud|podman.socket' | sed 's/^/DIAG   /' || true
    echo "DIAG preinstall lists:"; ls -l "${preinstall_dir}" 2>&1 | sed 's/^/DIAG   /'
    echo "DIAG os-release:"; sed 's/^/DIAG   /' "${os_release}" 2>&1
    echo "DIAG policy scopes:"; grep -o '"ghcr.io/[^"]*"' "${policy_file}" 2>&1 | sed 's/^/DIAG   /' || true
fi
exit "${fail}"
