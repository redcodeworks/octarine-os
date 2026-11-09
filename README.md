<p align="center"><picture><source media="(prefers-color-scheme: dark)" srcset="system_files/usr/share/octarine-os/logo/octarine-logo-dark-512.png"><source media="(prefers-color-scheme: light)" srcset="system_files/usr/share/octarine-os/logo/octarine-logo-light-512.png"><img src="system_files/usr/share/octarine-os/logo/octarine-logo-neutral-512.png" alt="octarineOS logo" width="560"></picture></p>

# octarine-os

A personal [bootc](https://github.com/bootc-dev/bootc) image: Fedora Silverblue on top of Universal Blue's
`silverblue-main`, with the niri compositor and Noctalia shell, libvirt, Cockpit, backup tools and a set of
hardening and tuning defaults. It is built daily and signed with [cosign](https://github.com/sigstore/cosign).
It makes one desktop reproducible and is shared in case parts of it are useful to you. It is one person's
configuration with no promises: read what it changes (the lists below) before you run it. The wider desktop setup is in
[`CONFIG-GUIDE.md`](CONFIG-GUIDE.md).

## What it adds to Fedora Silverblue

From the Universal Blue base (`ghcr.io/ublue-os/silverblue-main`), not added here: distrobox, ffmpeg and the
negativo17 multimedia stack, pam-u2f, `ujust` and its recipe framework, and automatic update staging.

Added by this image:

**Desktop and packages** (`build_files/build.sh`)
- niri compositor and Noctalia shell (optional)
- Packages in two tiers: critical (build fails, vendor checked in CI) and optional (CI warning when missing)
- zsh as the login shell for new users
- Backup tools: snapper, btrfs-assistant, borgbackup, restic, rclone
- Virtualisation: libvirt, qemu-kvm, libguestfs and virt-v2v
- Cockpit and its host modules (socket off by default)
- PCP metrics (`pmcd` and `pmlogger` on)
- Tailscale and `usbip` (services off by default)
- ROCm (HIP, OpenCL, `rocm-smi`), optional
- Podman extras: podman-compose, podman-tui, podman-docker, kind; rootless Podman socket on for every user
- steam-devices, GSConnect, GameMode config (`system_files/etc/gamemode.ini`), a Proton environment snippet
- Flatpak preinstall lists (GNOME apps, Firefox, Thunderbird, virt-manager, Vorta, Flatseal, Bazaar)

**Removed from the base** (`build.sh`)
- gnome-software (Bazaar is the software centre; fwupd and PackageKit stay)
- The Firefox RPM (the Flatpak replaces it) and `toolbox`
- Compilers and build tools stay out of the host; they live in the toolbox

**Homebrew** (`Containerfile`, `build.yml`)
- Files from Universal Blue's brew image, pinned to a dated tag and cosign-verified in CI
- Prefix is created on first boot; update timer on, upgrade timer off

**Toolboxes** (`system_files/usr/share/ublue-os/distrobox/`)
- `ujust toolbox dev-toolbox` and `ujust toolbox gaming`, built from separate images (`fedora-toolbox`, `fedora-gaming`)
- Optional IDE launchers and exported build tools

**Branding** (`build.sh`, `system_files`)
- `PRETTY_NAME` is `octarineOS`; ID, NAME and VERSION_ID are unchanged
- octarineOS logo on the GDM login screen and the Plymouth boot screen (own `octarine` theme, initramfs rebuilt)

**Hardening and defaults** (`system_files`)
- sshd: no root login, no X11 or TCP forwarding
- sysctl: ptrace scope, `kptr_restrict`, SysRq, BBR, inotify limits, a higher `vm.max_map_count`, zram swap tuning
- firewalld zone with named services (Sunshine, MoonDeckBuddy, Steam streaming, GSConnect, Tailscale port)
- pam-u2f for sudo and polkit, 30-minute sudo timeout, a higher memlock limit for `wheel`, kernel argument `iommu=pt`
- Container signature policy for this image's own registry path, so `bootc upgrade` rejects unsigned images
- Build guard that refuses security-key registrations and private keys in `system_files`

**Supply chain** (`.github/workflows/build.yml`)
- Daily build; images signed with cosign
- Smoke test of the image before it is pushed
- Maintainer details (channels, promotion, base image variables) are in `CLAUDE.md`

**`ujust` recipes** (`system_files/usr/share/ublue-os/just/60-custom.just`)
- `add-user-groups`, `toolbox`, `gnome-themes` (themes and icons live in their own repo), Flatpak helpers for games, Steam, VS Code, Podman Desktop, Chrome web apps and Gear Lever; the full list is under "Recipes"

## Use it

```
sudo bootc switch ghcr.io/redcodeworks/octarine-os:latest
```

Reboot, then run `ujust add-user-groups` to join the `gamemode`, `input` and `libvirt` groups.

To verify the signature yourself:

```
cosign verify --key cosign.pub ghcr.io/redcodeworks/octarine-os:latest
```

The image also installs a container signature policy for its registry path, so `bootc upgrade` rejects an
unsigned or wrongly signed image.

Pin a dated build, try the unreleased one, or roll back:

```
sudo bootc switch ghcr.io/redcodeworks/octarine-os:latest-<date>-<sha>   # pin (tags are on the package page)
sudo bootc switch ghcr.io/redcodeworks/octarine-os:testing               # unreleased build
sudo bootc rollback                                                      # boot the previous deployment
```

## Base image

Built on Universal Blue's `silverblue-main` for the current Fedora release (`ghcr.io/ublue-os/silverblue-main:45` today).

## Recipes

`ujust --list` shows them all.

| Recipe | What it does |
|---|---|
| `ujust add-user-groups` | Add a user to the `gamemode`, `input` and `libvirt` groups |
| `ujust toolbox [<name> [options]]` | List the toolboxes, or create and manage one (`ujust toolbox dev-toolbox`, `ujust toolbox gaming`); `ujust toolbox <name> --help` shows the options; `--ide` makes IDE launchers (JetBrains icon: the one Toolbox registered, else the file in the app's `bin/`; rerunning refreshes the icon of launchers it created) |
| `ujust gnome-themes <recipe>` | Run a recipe of [gnome-themes](https://github.com/redcodeworks/gnome-themes): themes and icons live there, not in the image |
| `ujust flatpak-games-access` | Give the Flatpak game launchers access to a games directory |
| `ujust steam-flatpak-devices` | Let Flatpak Steam see USB and input devices |
| `ujust steam-gamescope-setup` / `-reset` | Make Flatpak Steam and the gamescope layer work together, or undo it |
| `ujust extest-build`, `extest-steam-setup`, `extest-steam-reset` | Experimental: extest for Steam Input on Wayland |
| `ujust vscode-flatpak-podman` | Let Flatpak VS Code use Wayland and the rootless Podman socket |
| `ujust podman-desktop-deny-docker-socket` | Keep Podman Desktop away from a Docker socket |
| `ujust chrome-flatpak-webapps` | Let Flatpak Chrome install web apps as launchers |
| `ujust gearlever-applications` | Let Gear Lever manage AppImages in `~/Applications` |

## Contributing

This is a personal image; see `AGENTS.md`. `main` is protected: work happens on `testing` and a pull request
promotes it. Maintainer notes (design, CI, base image upgrades, forking, logo files) are in `CLAUDE.md`.

## License

Apache-2.0, inherited from the [Universal Blue image template](https://github.com/ublue-os/image-template).
See `LICENSE`.

## Credits

The logo (GDM login screen and Plymouth boot screen) is Kevin's own artwork: the square circuit-tree icon and the
wordmark. The repo ships no third-party image.

The experimental `ujust extest-build` recipe builds [extest](https://github.com/Supreeeme/extest) by Supreeeme
and contributors (MIT licence) from a pinned upstream commit; this repo ships none of its source.
