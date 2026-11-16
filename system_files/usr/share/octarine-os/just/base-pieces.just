# vim: set ft=make :

# Recipes of Universal Blue's `ublue-os-just` package (ublue-os/packages, packages/ublue-os-just, version 0.57, Apache-2.0, copyright
# the Universal Blue authors), copied here WITHOUT changes of their commands so that `ojust` works without that package: the files
# 00-default.just, 10-update.just and 20-clean.just of the package, which `ujust` imports from the package itself. Only ojust imports this
# file (ujust has the originals, so nothing is defined twice for it). A recipe or alias that the image's own files define (update,
# toggle-updates, toggle-motd) is not copied: the image's version is the one used. EXPERIMENTAL.

alias upgrade := update
alias changelog := changelogs
alias auto-update := toggle-updates

# Boot into this device's BIOS/UEFI screen
bios:
    #!/usr/bin/bash
    [ -r /usr/share/octarine-os/lib/emoji.sh ] && . /usr/share/octarine-os/lib/emoji.sh
    if [ -d /sys/firmware/efi ]; then
      systemctl reboot --firmware-setup
    else
      echo "Rebooting to legacy BIOS from OS is not supported."
    fi

# Show BIOS info
bios-info:
    #!/usr/bin/bash
    [ -r /usr/share/octarine-os/lib/emoji.sh ] && . /usr/share/octarine-os/lib/emoji.sh
    echo "Manufacturer: $(sudo dmidecode -s baseboard-manufacturer)"
    echo "Product Name: $(sudo dmidecode -s baseboard-product-name)"
    echo "Version: $(sudo dmidecode -s bios-version)"
    echo "Release Date: $(sudo dmidecode -s bios-release-date)"

# Show all messages from this boot
logs-this-boot:
    sudo journalctl --no-hostname -b 0

# Show all messages from last boot
logs-last-boot:
    sudo journalctl --no-hostname -b -1

# Enroll Nvidia driver & KMOD signing key for secure boot - Enter password "universalblue" if prompted
enroll-secure-boot-key:
    #!/usr/bin/bash
    [ -r /usr/share/octarine-os/lib/emoji.sh ] && . /usr/share/octarine-os/lib/emoji.sh
    ENROLLMENT_PASSWORD="universalblue"
    SECUREBOOT_KEY=/etc/pki/akmods/certs/akmods-ublue.der
    sudo mokutil --timeout -1
    echo -e "$ENROLLMENT_PASSWORD\n$ENROLLMENT_PASSWORD" | sudo mokutil --import "$SECUREBOOT_KEY"
    echo -e 'At next reboot, the mokutil UEFI menu UI will be displayed (*QWERTY* keyboard input and navigation).\nThen, select "Enroll MOK", and input "universalblue" as the password'

# Check for local overrides
check-local-overrides:
    #!/usr/bin/bash
    [ -r /usr/share/octarine-os/lib/emoji.sh ] && . /usr/share/octarine-os/lib/emoji.sh
    diff -r \
      --suppress-common-lines \
      --color="always" \
      --exclude "passwd*" \
      --exclude "group*" \
      --exclude="subgid*" \
      --exclude="subuid*" \
      --exclude="machine-id" \
      --exclude="adjtime" \
      --exclude="fstab" \
      --exclude="system-connections" \
      --exclude="shadow*" \
      --exclude="gshadow*" \
      --exclude="ssh_host*" \
      --exclude="cmdline" \
      --exclude="crypttab" \
      --exclude="hostname" \
      --exclude="localtime" \
      --exclude="locale*" \
      --exclude="*lock" \
      --exclude=".updated" \
      --exclude="*LOCK" \
      --exclude="vconsole*" \
      --exclude="00-keyboard.conf" \
      --exclude="grub" \
      --exclude="system.control*" \
      --exclude="cdi" \
      --exclude="default.target" \
      /usr/etc /etc 2>/dev/null | sed '/Binary\ files\ /d'

# Gather device info to a pastebin
device-info:
    #!/usr/bin/bash
    [ -r /usr/share/octarine-os/lib/emoji.sh ] && . /usr/share/octarine-os/lib/emoji.sh
    fpaste <(rpm-ostree status) <(fpaste --sysinfo --printonly) <(flatpak list --columns=application,version,options)

# Show the changelog
changelogs:
    rpm-ostree db diff --changelogs

# Update device firmware
[no-exit-message]
update-firmware:
    fwupdmgr refresh --force
    fwupdmgr get-updates
    fwupdmgr update

# Clean up old and unused podman images, volumes, flatpak packages and rpm-ostree content
clean-system:
    #!/usr/bin/bash
    [ -r /usr/share/octarine-os/lib/emoji.sh ] && . /usr/share/octarine-os/lib/emoji.sh
    podman image prune -af
    flatpak uninstall --unused
    rpm-ostree cleanup -bm
    if [ -x /home/linuxbrew/.linuxbrew/bin/brew ]; then
        brew autoremove
        brew cleanup
    fi
