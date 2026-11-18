#!/usr/bin/bash
# Our own step (Bluefin has no file for it): PRETTY_NAME, the GDM login logo and the Plymouth theme. Before 19-initramfs.sh: the initramfs
# carries the Plymouth theme.

echo "::group:: ===$(basename "$0")==="

set -eoux pipefail

# Name shown by the OS (GRUB, login screen, About). Only PRETTY_NAME changes: ID, NAME and
# VERSION_ID stay as they are, because update tooling and third-party software read them.
sed -i 's/^PRETTY_NAME=.*/PRETTY_NAME="octarineOS"/' /usr/lib/os-release
grep -qx 'PRETTY_NAME="octarineOS"' /usr/lib/os-release

# --- Branding: logo on the GDM login screen and the Plymouth boot screen ---
# GDM: system_files ships zz-octarine-login-screen.gschema.override; compile the schemas so it takes effect.
# glib-compile-schemas exits non-zero on a bad override (set -e fails the build).
glib-compile-schemas /usr/share/glib-2.0/schemas
test "$(GSETTINGS_BACKEND=memory gsettings --schemadir /usr/share/glib-2.0/schemas get org.gnome.login-screen logo)" \
	= "'/usr/share/octarine-os/logo/octarine-logo.png'"

# Plymouth: own theme "octarine" = bgrt (firmware logo plus spinner) with our watermark. The spinner assets are
# copied from the installed spinner theme (not vendored); the fedora-logos package file stays untouched.
theme=/usr/share/plymouth/themes/octarine
rm -rf "${theme}"
mkdir -p "${theme}"
cp -a /usr/share/plymouth/themes/spinner/. "${theme}/"
rm -f "${theme}/spinner.plymouth"
install -m644 /usr/share/octarine-os/logo/octarine-logo.png "${theme}/watermark.png"
sed -e '/^Name\[/d' -e 's/^Name=.*/Name=Octarine/' \
	-e "s#^ImageDir=.*#ImageDir=${theme}#" \
	/usr/share/plymouth/themes/bgrt/bgrt.plymouth >"${theme}/octarine.plymouth"
grep -qx "ImageDir=${theme}" "${theme}/octarine.plymouth"
grep -qx 'ModuleName=two-step' "${theme}/octarine.plymouth"
grep -qx 'Theme=octarine' /etc/plymouth/plymouthd.conf

echo "::endgroup::"
