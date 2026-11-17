#!/usr/bin/env bash
# Checks run INSIDE the built octarine-os-gx image (dx-image.yml mounts this file and runs it with bash when the variant is gx):
# the REQUIRED gaming packages (Steam, gamescope, MangoHud, GameMode, Sunshine and friends: the required lists of the pinned octarine-bins-gx image), where they
# came from, that no third-party repository is left enabled, Sunshine's file capability, rules and units, the kernel of the base image, and the checks of the
# default image's smoke test that still apply to a layer on top of it. EVERY check here is mandatory, except the optional packages of the gx list, which are
# only reported (INFO; what could not be installed is also in /usr/share/octarine-os/optional-packages-missing).
#
# Environment: BASE_KERNEL (the kernel release of the base image: the gx image must carry exactly that one kernel). EXPECT_IMAGE_ID (default octarine-os-gx; octarine-os-nvidia-gx for the same layer on the NVIDIA variant, octarine-os-dx-gx on the dx image: there the dev-only recipe check below is skipped, because the dx layer below legitimately ships it).
# For tests only: LIBEXEC_DIR, MODULES_DIR, UNIT_DIR, PREINSTALL_DIR, POLICY_FILE, OS_RELEASE, SHARE_DIR, ETC_DIR, LIB_DIR.
#
# Under pipefail never write `producer | grep -q` (grep quits at the first match, the producer dies of SIGPIPE and the pipeline fails).
# Output goes to a variable or a file first.
set -uo pipefail

modules_dir="${MODULES_DIR:-/usr/lib/modules}"
unit_dir="${UNIT_DIR:-/usr/lib/systemd/user}"
preinstall_dir="${PREINSTALL_DIR:-/usr/share/flatpak/preinstall.d}"
policy_file="${POLICY_FILE:-/etc/containers/policy.json}"
os_release="${OS_RELEASE:-/etc/os-release}"
share_dir="${SHARE_DIR:-/usr/share}"
etc_dir="${ETC_DIR:-/etc}"
lib_dir="${LIB_DIR:-/usr/lib}"
version_re='[0-9]{8}-[0-9a-f]{7,}'
fail=0
check() { if eval "$2" >/dev/null 2>&1; then echo "PASS $1"; else echo "FAIL $1"; fail=1; fi; }
have() { command -v "$1" >/dev/null 2>&1; }
kernels() { local d; for d in "${modules_dir}"/*/; do [ -d "${d}" ] && basename "${d}"; done; }
kernel_count() { local k; k=$(kernels); if [ -z "${k}" ]; then echo 0; else grep -c . <<<"${k}"; fi; }
one_kernel() { [ "$(kernel_count)" = 1 ]; }
kernel_is_base() { local k; k=$(kernels); [ -n "${BASE_KERNEL:-}" ] && [ "${k}" = "${BASE_KERNEL}" ]; }
has_text() { [ -r "$1" ] && grep -qF -- "$2" "$1"; }
# the repository an installed package came from (dnf5 keeps it in its history)
from_repo() { dnf5 -q repoquery --installed "$1" --queryformat '%{from_repo}\n' 2>/dev/null | head -n1; }
# the version-release of an installed package for one architecture
evr_of() { rpm -q --queryformat '%{EPOCH}:%{VERSION}-%{RELEASE}\n' "$1" 2>/dev/null; }
same_mesa() { local a b; a=$(evr_of mesa-vulkan-drivers.x86_64); b=$(evr_of mesa-vulkan-drivers.i686); [ -n "${a}" ] && [ "${a}" = "${b}" ]; }
# the enabled repository ids, one per line (output to a variable: no pipe into grep -q)
enabled_repos() { dnf5 repolist --enabled 2>/dev/null | sed -n '2,$p' | sed 's/ .*//'; }
no_third_party_repo() { local r; r=$(enabled_repos); [ -n "${r}" ] && ! grep -qE '^(rpmfusion|copr:copr.fedorainfracloud.org:lizardbyte|google-chrome)' <<<"${r}"; }

echo "== required gaming packages (required-fedora, required-negativo17, required-copr of octarine-bins-gx): both architectures where a 32-bit game needs them"
for p in steam gamescope Sunshine steam-devices; do
    check "package ${p}" "rpm -q ${p}"
done
for p in mangohud gamemode libFAudio mesa-vulkan-drivers; do
    check "package ${p} for x86_64" "rpm -q ${p}.x86_64"
    check "package ${p} for i686" "rpm -q ${p}.i686"
done
check "x86_64 and i686 Mesa have the same version (one repository provides both)" "same_mesa"
echo "== optional gaming packages (informational)"
for p in joystick-support input-remapper protontricks winetricks vkBasalt vulkan-tools mesa-demos libva-utils obs-studio-plugin-vkcapture-hook-libs.x86_64 obs-studio-plugin-vkcapture-hook-libs.i686; do
    if rpm -q "${p}" >/dev/null 2>&1; then echo "INFO optional package ${p} installed"; else echo "INFO optional package ${p} NOT installed"; fi
done
for c in steam gamescope mangohud gamemoded sunshine; do
    check "command ${c}" "have ${c}"
done

echo "== where they came from"
check "steam comes from negativo17 (fedora-multimedia, required-negativo17.txt)" "[ \"\$(from_repo steam)\" = fedora-multimedia ]"
check "Sunshine comes from the LizardByte COPR" "[ \"\$(from_repo Sunshine)\" = copr:copr.fedorainfracloud.org:lizardbyte:stable ]"
check "no RPM Fusion, COPR (LizardByte) or vendor repository is enabled (only the base's repositories; negativo17 stays disabled)" "no_third_party_repo"
check "the repository package of the old RPM Fusion route and its boot service are not in the image" "! rpm -q fedora-workstation-repositories && ! rpm -q fedora-third-party && ! test -e ${etc_dir}/systemd/system/multi-user.target.wants/fedora-third-party-refresh.service"
check "Steam is not in any Flatpak preinstall list (the RPM is the Steam of this image)" "! grep -rqiE 'com.valvesoftware.Steam|MoonDeck' ${preinstall_dir}"
check "Moonlight and MoonDeck Buddy are not packages of the image" "! rpm -q moonlight-qt && ! rpm -q MoonDeckBuddy"

echo "== Sunshine: file capability, rules, units, firewall"
check "/usr/bin/sunshine has its file capabilities (cap_sys_admin, cap_sys_nice)" "[ -x /usr/bin/sunshine ] && c=\$(getcap /usr/bin/sunshine) && [[ \"\${c}\" == *cap_sys_admin* && \"\${c}\" == *cap_sys_nice* ]]"
check "rpm -V Sunshine reports nothing (files and capabilities as packaged)" "[ -z \"\$(rpm -V Sunshine)\" ]"
check "the uinput udev rule is shipped" "has_text ${lib_dir}/udev/rules.d/60-sunshine.rules uinput"
check "the uhid module is loaded at boot (modules-load.d; /dev/uinput gets its static node from the udev rule)" "has_text ${lib_dir}/modules-load.d/60-sunshine.conf uhid"
check "the Sunshine user unit is shipped" "test -s ${unit_dir}/app-dev.lizardbyte.app.Sunshine.service"
check "...and NOT enabled by default (the user runs: systemctl --user enable --now app-dev.lizardbyte.app.Sunshine)" "! systemctl --global is-enabled app-dev.lizardbyte.app.Sunshine.service"
check "firewalld has the sunshine and steam-streaming services" "{ test -s ${lib_dir}/firewalld/services/sunshine.xml || test -s ${etc_dir}/firewalld/services/sunshine.xml; } && { test -s ${lib_dir}/firewalld/services/steam-streaming.xml || test -s ${etc_dir}/firewalld/services/steam-streaming.xml; }"

echo "== Steam Big Picture gamescope session (GDM): session file, wrapper, documented defaults"
session_file="${share_dir}/wayland-sessions/steam-gamescope.desktop"
wrapper="${LIBEXEC_DIR:-/usr/libexec}/octarine-os/gamescope-session"
session_ok() { python3 -I - "${session_file}" <<'PY'
import configparser, sys
c = configparser.RawConfigParser(strict=True, interpolation=None)
c.optionxform = str
c.read(sys.argv[1], encoding="utf-8")
e = c["Desktop Entry"]
assert e["Type"] == "Application" and e["Name"] and e["DesktopNames"] == "gamescope"
assert e["Exec"] == "/usr/libexec/octarine-os/gamescope-session"
PY
}
check "the gamescope session file parses and names the wrapper under /usr/libexec" "session_ok"
check "the session wrapper is executable and parses (bash -n)" "[ -x ${wrapper} ] && bash -n ${wrapper}"
check "the documented defaults file is shipped" "test -s ${share_dir}/octarine-os/gamescope-session.conf"

echo "== kernel"
kver=$(kernels); kver=${kver%%$'\n'*}
check "exactly one kernel is installed" "one_kernel"
check "the kernel is the one of the base image (${BASE_KERNEL:-unset})" "kernel_is_base"
check "the initramfs for the kernel exists" "test -s ${modules_dir}/${kver}/initramfs.img"

echo "== checks of the default image that still apply"
check "release is Fedora" "grep -qx ID=fedora ${os_release}"
check "pretty name" "grep -qx 'PRETTY_NAME=\"octarineOS\"' ${os_release}"
check "image id" "grep -qx 'IMAGE_ID=\"${EXPECT_IMAGE_ID:-octarine-os-gx}\"' ${os_release}"
check "image version has the build's version format" "grep -qE '^IMAGE_VERSION=\"${version_re}\"\$' ${os_release}"
check "signature policy parses" "python3 -m json.tool ${policy_file}"
for r in octarine-os octarine-os-nvidia octarine-os-dx octarine-os-nvidia-dx octarine-os-gx octarine-os-nvidia-gx octarine-os-dx-gx; do
    check "signature policy has a rule for ghcr.io/redcodeworks/${r}" "has_text ${policy_file} '\"ghcr.io/redcodeworks/${r}\"'"
done
check "sudoers valid" "visudo -c"
check "new users do not default to zsh" "! has_text ${etc_dir}/default/useradd SHELL=/usr/bin/zsh"
check "enabled brew-setup.service" "systemctl is-enabled brew-setup.service"
check "enabled (global) podman.socket" "systemctl --global is-enabled podman.socket"
check "ujust custom recipes" "test -f ${share_dir}/ublue-os/just/60-custom.just"
check "menu helper library shipped" "test -s ${share_dir}/octarine-os/lib/menu.sh"
check "dev-toolbox definition" "has_text ${share_dir}/ublue-os/distrobox/dev-toolbox.ini '[dev-toolbox]'"
check "the gaming-setup recipe is listed" "o=\$(ujust --summary 2>&1) && [[ \" \${o//\$'\\n'/ } \" == *' gaming-setup '* ]]"
if [ "${EXPECT_IMAGE_ID:-}" = octarine-os-dx-gx ]; then
    check "the dev recipe of the dx layer below is still imported (octarine-os-dx-gx has both layers)" "grep -q 70-octarine-dev ${share_dir}/ublue-os/justfile"
else
    check "no dev-only recipe (ujust dev is dx only)" "! grep -q 70-octarine-dev ${share_dir}/ublue-os/justfile"
fi
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
    missing=""
    for p in steam gamescope mangohud gamemode vkBasalt libFAudio Sunshine mesa-vulkan-drivers steam-devices input-remapper; do
        rpm -q "${p}" >/dev/null 2>&1 || missing="${missing} ${p}"
    done
    echo "DIAG gaming packages not installed:${missing:- none}"
    echo "DIAG installed architectures: $(rpm -q --queryformat '%{NAME}.%{ARCH} ' mangohud libFAudio mesa-vulkan-drivers gamemode 2>&1)"
    echo "DIAG sources: steam=$(from_repo steam) Sunshine=$(from_repo Sunshine)"
    echo "DIAG enabled repositories:"; enabled_repos | sed 's/^/DIAG   /'
    echo "DIAG getcap sunshine: $(getcap /usr/bin/sunshine 2>&1)"
    echo "DIAG rpm -V Sunshine:"; rpm -V Sunshine 2>&1 | sed 's/^/DIAG   /'
    echo "DIAG os-release:"; sed 's/^/DIAG   /' "${os_release}" 2>&1
    echo "DIAG policy scopes:"; grep -o '"ghcr.io/[^"]*"' "${policy_file}" 2>&1 | sed 's/^/DIAG   /' || true
fi
exit "${fail}"
