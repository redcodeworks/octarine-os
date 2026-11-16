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

For a variant (the developer image `octarine-os-dx`, the NVIDIA images) or a channel (`beta`, `testing`), use
`ujust switch-image` once the image is running; `ujust switch-image --list` shows what exists, and
[image-variants.md](image-variants.md) says what each variant is for.

To go back to the previous deployment: `sudo bootc rollback`, then reboot.

## 2. Run some `ujust` recipes

After the first boot, in a terminal on the desktop. Each recipe explains itself with `--help`, and the checklists let you
skip any step:

- `ujust flatpak-preinstall`: installs the Flatpak apps the image lists.
- `ujust user-setup`: checklist for a new user (groups, login shell, Flatpak access, fonts, terminal profile).
- `ujust niri-setup`: sets up the niri session in your home directory.
- `ujust hardware-setup`: vendor and hardware steps; steps for hardware your machine lacks are hidden.
- `ujust gaming-setup`: checklist for Steam, Lutris, gamescope, MangoHud and GameMode tuning.
- `ujust toggle-updates`, then `ujust update`: choose which sources update automatically, and update them.
- `ujust dev` (dx image only): developer setup checklist.

`ujust --list` shows every recipe.
