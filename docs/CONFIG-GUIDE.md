# Setup guide

Two steps from a stock Fedora Atomic desktop (Silverblue, the current release) to this image. The
[main README](../README.md) has the full install notes and the list of recipes.

## 1. Rebase to the image

Switch the machine to the image and reboot. Run the second command after the first reboot, so later updates are
signature-verified, then reboot again:

```
sudo bootc switch ghcr.io/redcodeworks/octarine-os:latest
sudo bootc switch --enforce-container-sigpolicy ghcr.io/redcodeworks/octarine-os:latest
```

For a variant (the developer image `octarine-os-dx`, the gamer image `octarine-os-gx`, the NVIDIA images) or a channel (`testing`), use
`ujust switch-image` once the image is running; `ujust switch-image --list` shows what exists, and
[image-variants.md](image-variants.md) says what each variant is for.

To go back to the previous deployment: `sudo bootc rollback`, then reboot.

The boot menu (GRUB) lists the five newest images you booted, each titled with its version and kernel, for example
`octarineOS 20261122-69cc88c (kernel 7.3.4-300.fc45.x86_64)`; pick an older one there to boot it. A small boot-time service
(`octarine-keep-deployments.service`) pins the running deployment and releases the pins beyond the fifth, so the set builds up
over the next updates (one new entry per update). To undo: `sudo systemctl disable octarine-keep-deployments.service`, and
`sudo ostree admin pin --unpin <n>` (the numbers are in `ostree admin status`) for entries you no longer want.

## 2. Run some `ujust` recipes

After the first boot, in a terminal on the desktop. Each recipe explains itself with `--help`, and the checklists let you
skip any step:

- `ujust flatpak-preinstall`: installs the Flatpak apps the image lists.
- `ujust user-setup`: checklist for a new user (groups, login shell, Flatpak access, fonts, terminal profile).
- `ujust niri-setup`: sets up the niri session in your home directory.
- `ujust hardware-setup`: vendor and hardware steps; steps for hardware your machine lacks are hidden.
- `ujust gaming-setup`: checklist for Steam, Lutris, gamescope, MangoHud and GameMode tuning (on the gx image Steam and the layers are installed already, those steps are skipped).
- `ujust toggle-updates`, then `ujust update`: choose which sources update automatically, and update them.
- `ujust dev` (dx image only): developer setup checklist.
- `ujust datastore-install` (dx image only): optional, downloads the signed datastore bundle (PostgreSQL, Valkey, SeaweedFS, Kafka as rootless containers).
- `ujust datastore-box-create` (dx image only): optional, the newer alternative: the same four services as units inside one distrobox (`ujust datastore-box setup`, then `start`). Pick one of the two; they use the same ports. Moving from the container recipes to the box is a manual cutover, see "Datastore box" in `docs/image-variants.md`.

`ujust --list` shows every recipe.
