#!/usr/bin/env bash
# Smoke test of the default octarine-os image, run INSIDE the freshly built image (build.yml mounts this
# file and runs it with bash; the dx variants have .github/scripts/dx-smoke.sh).
#
# Environment: REF (registry path of the image, for the signature policy), BASE_TAG (the base tag the build resolved).
# `check "<description>" "<command>"`: the command runs under eval, so quote it as ONE string (tests/check-call-shape.sh
# guards joined strings, which would pass vacuously). Run order matters nowhere; every failure is listed, exit 1 at the end.
fail=0
check() { if (eval "$2") >/dev/null 2>&1; then echo "PASS $1"; else echo "FAIL $1"; fail=1; fi; }

echo "== os-release (the Fedora release the base tag resolved to)"
cat /etc/os-release
echo "== enabled system units"
systemctl list-unit-files --state=enabled --no-legend --no-pager || true
echo "== enabled user units (global)"
systemctl --global list-unit-files --state=enabled --no-legend --no-pager || true
echo "== checks"

check "no flatpak-preinstall.service enabled (the recipe replaces it)" "! systemctl is-enabled flatpak-preinstall.service 2>/dev/null"
# prebuilt binaries (the pinned octarine-bins image: scx, extest, ghostty): installed only; whether a scheduler loads is for a real machine to say
check "schedulers.tsv manifest shipped and not empty" "test -s /usr/share/octarine-os/schedulers.tsv"
for n in $(cut -f1 /usr/share/octarine-os/schedulers.tsv); do
    check "scheduler $n is executable and runs --version" "test -x /usr/bin/$n && /usr/bin/$n --version"
    check "scheduler $n resolves every shared library (ldd shows no not found)" "out=\$(ldd /usr/bin/$n) && ! grep -q \"not found\" <<<\"\$out\""
    check "scheduler $n has no undefined symbol against this image (ldd -r)" "out=\$(ldd -r /usr/bin/$n 2>&1) && ! grep -qi \"undefined symbol\" <<<\"\$out\""
done
check "ghostty: no undefined symbol against this image (ldd -r)" "out=\$(ldd -r /usr/bin/ghostty 2>&1) && ! grep -qi \"undefined symbol\" <<<\"\$out\""
echo "== libraries the shipped binaries link: the builder (BUILDINFO of the binaries image) next to this image"
for p in glibc gtk4 libadwaita gtk4-layer-shell; do echo "  image: $p $(rpm -q --qf %{VERSION}-%{RELEASE} $p 2>/dev/null || echo not installed)"; done
grep -hiE "^(glibc|gtk4|libadwaita|gtk4-layer-shell)" /usr/share/licenses/octarine-binaries/*/BUILDINFO 2>/dev/null | sed "s/^/  builder: /" || true
check "extest 32-bit library is a 32-bit ELF" "file -L /usr/lib/extest/lib/libextest.so | grep -q \"ELF 32-bit\""
check "extest 64-bit library is a 64-bit ELF" "file -L /usr/lib/extest/lib64/libextest.so | grep -q \"ELF 64-bit\""
check "extest libraries are executable files" "test -x /usr/lib/extest/lib/libextest.so && test -x /usr/lib/extest/lib64/libextest.so"
check "GPL-2.0 text ships with the schedulers" "grep -rqF \"GNU GENERAL PUBLIC LICENSE\" /usr/share/licenses/octarine-binaries/scx"
check "MIT text ships with extest" "grep -rqF \"MIT License\" /usr/share/licenses/octarine-binaries/extest"
check "scheduler units: the template and the polkit rule ship, the helpers and the GameMode hooks are executable" "test -f /usr/lib/systemd/system/scx@.service && test -f /usr/share/polkit-1/rules.d/50-octarine-scx.rules && for f in scx-preflight scx-wait-idle scx-run scx-verify gamemode-start gamemode-end; do test -x /usr/libexec/octarine-os/\$f || exit 1; done"
check "polkit rule: generated from the registry (every instance in the unit regex, no generic character class) and the scx@ template it depends on exists" "test -f /usr/lib/systemd/system/scx@.service && ! grep -q A-Za-z0-9 /usr/share/polkit-1/rules.d/50-octarine-scx.rules && for c in /usr/share/octarine-os/schedulers.d/*.conf; do i=\$(basename \$c .conf); grep -Eq \"scx@.*[(|]\$i[|)]\" /usr/share/polkit-1/rules.d/50-octarine-scx.rules || exit 1; done"
check "scheduler registry: one file per manifest line, every instance has a conflicts drop-in" "test \"\$(ls /usr/share/octarine-os/schedulers.d | wc -l)\" = \"\$(wc -l < /usr/share/octarine-os/schedulers.tsv)\" && for c in /usr/share/octarine-os/schedulers.d/*.conf; do i=\$(basename \$c .conf); test -s /usr/lib/systemd/system/scx@\$i.service.d/10-conflicts.conf || exit 1; done"
check "no scheduler is enabled or started by the image (preset disables, no wants link)" "grep -qx \"disable scx@\\*.service\" /usr/lib/systemd/system-preset/00-octarine-scx.preset && ! ls /etc/systemd/system/*.wants/ 2>/dev/null | grep -q ^scx@"
check "ghostty: installed with its desktop file, an icon the hicolor cache lists, a working --version and its libraries resolved" "test -x /usr/bin/ghostty && test -f /usr/share/applications/com.mitchellh.ghostty.desktop && test -f /usr/share/icons/hicolor/256x256/apps/com.mitchellh.ghostty.png && grep -aq com.mitchellh.ghostty /usr/share/icons/hicolor/icon-theme.cache && /usr/bin/ghostty --version >/dev/null && out=\$(ldd /usr/bin/ghostty) && ! grep -q \"not found\" <<<\"\$out\""
check "source and build records ship for every binary component" "for i in scx extest ghostty; do test -s /usr/share/licenses/octarine-binaries/\$i/SOURCE && test -s /usr/share/licenses/octarine-binaries/\$i/BUILDINFO || exit 1; done"
# pcp is an optional package: its units are enabled only when it is installed
check "pcp units enabled when pcp is installed" "! rpm -q pcp || (systemctl is-enabled pmcd.service && systemctl is-enabled pmlogger.service)"
check "enabled brew-setup.service" "systemctl is-enabled brew-setup.service"
check "enabled brew-update.timer" "systemctl is-enabled brew-update.timer"
check "brew-upgrade.timer stays disabled" "! systemctl is-enabled brew-upgrade.timer"
check "brew tarball present" "test -s /usr/share/homebrew.tar.zst"
check "brew profile script present" "test -f /etc/profile.d/brew.sh"
check "enabled (global) podman.socket" "systemctl --global is-enabled podman.socket"

# CRITICAL packages (build.sh, first dnf5 transaction): a missing one fails the build
CRITICAL="pam-u2f snapper fuse-libs tailscale gnome-shell-extension-user-theme borgbackup steam-devices zsh jq skopeo solaar-udev gcc gcc-c++ make binutils"
for p in $CRITICAL; do
  check "package $p" "rpm -q $p"
  # standing policy: critical packages come from Fedora itself (outside repos only in optional groups)
  check "critical package $p has vendor Fedora Project" "test \"\$(rpm -q --qf %{VENDOR} $p)\" = \"Fedora Project\""
done
# Solaar is not in the image; solaar-udev keeps the Logitech device permissions (including uinput) for a Solaar Flatpak the user installs
check "the Solaar GUI package is NOT installed" "! rpm -q solaar"
check "solaar-udev rules are present and carry the uinput line" "grep -q uinput /usr/lib/udev/rules.d/42-logitech-unify-permissions.rules"
# The VM-hosting set lives in the dx variant only: the meta packages must be absent here (the libguestfs tools stay)
for p in libvirt qemu-kvm cockpit-machines virt-manager virt-viewer libvirt-nss; do
  check "VM-hosting package $p is NOT installed (dx only)" "! rpm -q $p"
done
check "libguestfs tools stay (guestfish)" "rpm -q guestfs-tools"
# OPTIONAL packages: informational only, never fail (the missing list is reported below)
for p in gstreamer1-plugins-bad gstreamer1-plugins-ugly fish gum niri noctalia btrfs-assistant nautilus-python wtype socat gnome-shell-extension-gsconnect gnome-shell-extension-appindicator gnome-shell-extension-auto-move-windows \
         gnome-shell-extension-caffeine gnome-shell-extension-dash-to-dock gpaste gnome-shell-extension-gpaste \
         nautilus-gsconnect cockpit cockpit-podman cockpit-storaged cockpit-networkmanager \
         cockpit-ostree cockpit-selinux cockpit-files cockpit-packagekit cockpit-sosreport cockpit-kdump \
         pcp python3-pcp powertop iotop-c lm_sensors usbip podman-compose kind podman-docker podman-tui \
         restic rclone guestfs-tools libguestfs \
         libguestfs-xfs virt-v2v; do
  if rpm -q $p >/dev/null 2>&1; then echo "INFO optional package $p installed"; else echo "INFO optional package $p NOT installed"; fi
done
# GPaste (optional, shipped but not enabled): when installed, the extension directory, its UUID and the compiled schema must be there
if rpm -q gnome-shell-extension-gpaste >/dev/null 2>&1; then
  check "GPaste extension directory and UUID" "grep -qF GPaste@gnome-shell-extensions.gnome.org /usr/share/gnome-shell/extensions/GPaste@gnome-shell-extensions.gnome.org/metadata.json"
  check "GPaste schema compiled" "GSETTINGS_BACKEND=memory gsettings --schemadir /usr/share/glib-2.0/schemas get org.gnome.GPaste show-history | grep -q Alt"
  check "GPaste daemon is D-Bus activated" "test -f /usr/share/dbus-1/services/org.gnome.GPaste.service"
else
  echo "INFO GPaste not installed (listed in optional-packages-missing)"
fi
# removed from the image (2026-11-13): the owner installs these as user extensions; they must not be shipped
check "Just Perfection, ddterm and Freon are not shipped (packages and extension directories)" "! rpm -q gnome-shell-extension-just-perfection gnome-shell-extension-ddterm gnome-shell-extension-freon >/dev/null 2>&1 && ! ls -d /usr/share/gnome-shell/extensions/just-perfection-desktop@just-perfection /usr/share/gnome-shell/extensions/ddterm@amezin.github.com /usr/share/gnome-shell/extensions/freon@UshakovVasilii_Github.yahoo.com >/dev/null 2>&1"
echo "== optional packages missing (written by build.sh, empty is good)"
cat /usr/share/octarine-os/optional-packages-missing 2>/dev/null || true
check "optional-packages-missing file exists" "test -f /usr/share/octarine-os/optional-packages-missing"
check "zsh login files source /etc/profile (brew.sh relies on it)" "grep -q /etc/profile /etc/zprofile"
check "skel zshrc" "test -s /etc/skel/.zshrc"
check "sudo keeps a wheel rule" "grep -qE \"^%wheel[[:space:]]\" /etc/sudoers"
check "sudo PAM keeps the password fallback" "grep -qE \"^auth[[:space:]]+include[[:space:]]+system-auth\" /etc/pam.d/sudo"
check "polkit PAM keeps the password fallback" "grep -qE \"^auth[[:space:]]+include[[:space:]]+system-auth\" /etc/pam.d/polkit-1"
check "pam_u2f module present" "test -e /usr/lib64/security/pam_u2f.so"
check "firefox removed" "! rpm -q firefox"
check "toolbox removed" "! rpm -q toolbox"
check "distrobox present" "rpm -q distrobox"
check "gnome-software removed" "! rpm -q gnome-software"
for p in fwupd flatpak gnome-shell; do check "package $p still installed" "rpm -q $p"; done
check "Bazaar in the preinstall list" "grep -qF \"[Flatpak Preinstall io.github.kolunmi.Bazaar]\" /usr/share/flatpak/preinstall.d/tools.preinstall"
check "image version format" "grep -qE '^IMAGE_VERSION=\"[0-9]{8}-[0-9a-f]{7,}\"\$' /etc/os-release"

check "signature policy parses" "python3 -m json.tool /etc/containers/policy.json"
check "signature policy covers this image" "grep -q $REF /etc/containers/policy.json"
check "signature policy also covers the NVIDIA variant repository" "grep -q $REF-nvidia /etc/containers/policy.json"
check "signature policy also covers the dx variant repository" "grep -q $REF-dx /etc/containers/policy.json"
check "signature policy also covers the NVIDIA dx repository" "grep -q $REF-nvidia-dx /etc/containers/policy.json"
check "signature policy also covers the gx variant repository (not published yet)" "grep -q $REF-gx /etc/containers/policy.json"
check "signature policy also covers the NVIDIA gx repository" "grep -q $REF-nvidia-gx /etc/containers/policy.json"
check "release is Fedora" "grep -qx ID=fedora /etc/os-release"
check "release matches a numeric base tag ($BASE_TAG)" "case \"$BASE_TAG\" in [0-9]*) grep -qx \"VERSION_ID=$BASE_TAG\" /etc/os-release;; esac"
check "sudoers valid" "visudo -c"
check "sudoers fragment valid" "visudo -c -f /etc/sudoers.d/10-timestamp-timeout"
check "firewalld config valid" "firewall-offline-cmd --check-config"
check "no image ships an iommu kernel argument (it is opt-in: ujust virthost-setup; any kargs.d file mentioning iommu fails)" "! grep -rqs iommu /usr/lib/bootc/kargs.d"
check "dev-toolbox definition" "grep -q \"^\\[dev-toolbox\\]\" /usr/share/ublue-os/distrobox/dev-toolbox.ini"
check "dev-toolbox definition has no per-user keys" "! grep -qE \"^(exported_bins|home)\" /usr/share/ublue-os/distrobox/dev-toolbox.ini"
check "rocm toolbox definition and the box-export helper" "grep -q \"^\\[rocm\\]\" /usr/share/ublue-os/distrobox/rocm.ini && grep -q additional_packages /usr/share/ublue-os/distrobox/rocm.ini && test -s /usr/share/octarine-os/lib/box-export.sh"
check "gaming toolbox definition" "grep -q \"^\\[gaming\\]\" /usr/share/ublue-os/distrobox/gaming.ini"
check "gaming toolbox isolates its home" "grep -qx ISOLATED_HOME=true /usr/share/ublue-os/distrobox/gaming.conf"
check "dev-toolbox settings" "grep -q ^TOOLS= /usr/share/ublue-os/distrobox/dev-toolbox.conf"
check "GDM logo override compiled" "GSETTINGS_BACKEND=memory gsettings --schemadir /usr/share/glib-2.0/schemas get org.gnome.login-screen logo | grep -qF octarine-logo.png"
check "plymouth watermark is ours" "cmp /usr/share/plymouth/themes/octarine/watermark.png /usr/share/octarine-os/logo/octarine-logo.png"
check "initramfs holds the watermark" "lsinitrd /usr/lib/modules/*/initramfs.img | grep -qF usr/share/plymouth/themes/octarine/watermark.png"
check "dconf profile lists the distro database" "grep -qx system-db:distro /etc/dconf/profile/user"
check "dconf distro database holds the enabled extensions (dconf update ran over our keyfile)" "grep -aq enabled-extensions /etc/dconf/db/distro"
check "every extension enabled by default is shipped (directory in the image), or the build recorded a missing optional package" "for u in \$(grep ^enabled-extensions= /etc/dconf/db/distro.d/90-octarine-os | grep -o \"[A-Za-z0-9._-]*@[A-Za-z0-9._-]*\"); do test -d /usr/share/gnome-shell/extensions/\$u || test -s /usr/share/octarine-os/optional-packages-missing || exit 1; done"
check "dconf distro database holds our hot corner default" "grep -aq enable-hot-corners /etc/dconf/db/distro"
check "dconf distro database holds our button-layout default" "grep -aq button-layout /etc/dconf/db/distro"
check "the fastfetch default configuration parses as JSON once the full-line // comments are removed" "grep -vE '^[[:space:]]*//' /etc/xdg/fastfetch/config.jsonc | jq -e ."
for f in /usr/share/fish/vendor_conf.d/octarine-os-*.fish /usr/share/fish/vendor_functions.d/y.fish; do
  check "fish accepts $f" "fish --no-execute $f"
done
check "niri config parts shipped (/etc/niri)" "test -s /etc/niri/config.kdl && test -s /etc/niri/40-binds.kdl && test -s /etc/niri/50-noctalia.kdl && test -s /etc/niri/35-gestures.kdl && test -s /etc/niri/45-workspaces.kdl && test -s /etc/niri/60-window-rules.kdl"
check "niri-setup source files shipped" "test -s /usr/share/octarine-os/niri-setup/niri-portals.conf && test -s /usr/share/octarine-os/niri-setup/10-octarine-os.toml && test -s /usr/share/octarine-os/niri-setup/keybinds/standard.kdl.in && test -s /usr/share/octarine-os/niri-setup/keybinds/compact.kdl.in && test -s /usr/share/octarine-os/niri-setup/keybinds/hhkb.kdl.in"
check "niri accepts the shipped config when niri is installed" "! command -v niri || niri validate -c /etc/niri/config.kdl"

# ujust recipes added with switch-image, toggle-updates, update and luks-tpm-unlock (jq and skopeo are in CRITICAL above)
for u in rpm-ostreed-automatic.timer flatpak-system-update.timer brew-update.timer brew-upgrade.timer; do
  check "update unit $u exists" "systemctl cat $u"
done
for u in flatpak-user-update.timer octarine-distrobox-upgrade.timer octarine-distrobox-upgrade.service; do
  check "user update unit $u exists" "test -f /usr/lib/systemd/user/$u"
done
check "jq and skopeo run" "jq --version && skopeo --version"
check "staged automatic image updates are on by default (ujust toggle-updates is the user switch)" "systemctl is-enabled rpm-ostreed-automatic.timer && grep -qx AutomaticUpdatePolicy=stage /etc/rpm-ostreed.conf"
check "mcelog is not masked and has the Intel-only drop-in" "! systemctl is-enabled mcelog.service 2>&1 | grep -qx masked && grep -q GenuineIntel /usr/lib/systemd/system/mcelog.service.d/50-octarine-intel-only.conf"
check "automatic update retry drop-in: bounded on-failure restart" "grep -qx Restart=on-failure /usr/lib/systemd/system/rpm-ostreed-automatic.service.d/50-octarine-retry.conf && grep -qx RestartSec=60 /usr/lib/systemd/system/rpm-ostreed-automatic.service.d/50-octarine-retry.conf && grep -qx StartLimitBurst=5 /usr/lib/systemd/system/rpm-ostreed-automatic.service.d/50-octarine-retry.conf"
check "automatic update service waits for the network (base drop-in) and NetworkManager-wait-online is enabled" "grep -q After=network-online.target /usr/lib/systemd/system/rpm-ostreed-automatic.service.d/override.conf && systemctl is-enabled NetworkManager-wait-online.service"
summary=$(just --justfile /usr/share/ublue-os/justfile --summary 2>&1)
check "the assembled justfile parses (just --summary)" "just --justfile /usr/share/ublue-os/justfile --summary"
check "the experimental second launcher runs and lists the image own recipes without a base file import" "test -x /usr/bin/ojust && /usr/bin/ojust --list | grep -q toggle-motd && /usr/bin/ojust --list | grep -q niri-setup && ! grep -E ^import /usr/share/octarine-os/justfile | grep -q -- -base.just"
has_recipe() { printf "%s\n" $summary | grep -qx -- "$1"; }
for r in switch-image toggle-updates update luks-tpm-unlock toggle-motd toggle-user-motd; do
  check "assembled justfile lists $r" "has_recipe $r"
done
count_recipe() { printf "%s\n" $summary | grep -cx -- "$1"; }
check "toggle-user-motd is listed exactly once (our wrapper of the base recipe)" "test \$(count_recipe toggle-user-motd) = 1"
check "the base 00-default.just is kept as 00-default-base.just and ours imports it" "test -s /usr/share/ublue-os/just/00-default-base.just && grep -qF 00-default-base.just /usr/share/ublue-os/just/00-default.just"
check "one motd script (executable) and the profile.d hook that calls it, interactive shells only" "test -x /usr/libexec/octarine-os/motd && grep -qF /usr/libexec/octarine-os/motd /etc/profile.d/user-motd.sh && grep -qF \"*i*)\" /etc/profile.d/user-motd.sh"
for r in toggle-nvk setup-luks-tpm-unlock remove-luks-tpm-unlock; do
  check "assembled justfile does not list the base recipe $r" "! has_recipe $r"
done
check "flatpak preinstall list" "test -s /usr/share/flatpak/preinstall.d/gnome.preinstall"
exit $fail
