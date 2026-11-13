<p align="center"><picture><source media="(prefers-color-scheme: dark)" srcset="system_files/usr/share/octarine-os/logo/octarine-logo-dark-512.png"><source media="(prefers-color-scheme: light)" srcset="system_files/usr/share/octarine-os/logo/octarine-logo-light-512.png"><img src="system_files/usr/share/octarine-os/logo/octarine-logo-neutral-512.png" alt="octarineOS logo" width="560"></picture></p>

# octarineOS

A personal [bootc](https://github.com/bootc-dev/bootc) image: Fedora Silverblue on top of Universal Blue's
`silverblue-main`, with the niri compositor and Noctalia shell, Cockpit, backup tools and a set of
hardening and tuning defaults. It is built daily and signed. It makes one desktop reproducible and is shared in case
parts of it are useful to you. It is one person's configuration with no promises: read what it changes before you run it.
The wider desktop setup is in [`CONFIG-GUIDE.md`](CONFIG-GUIDE.md).

## Requirements

- A PC that runs Fedora Silverblue (the current release, 45), with UEFI boot and enough disk for the image.
- An internet connection for the install and for updates.

## Highlights

From the Universal Blue base (`ghcr.io/ublue-os/silverblue-main`), not added here: distrobox, ffmpeg and the
multimedia codecs, security-key support, `ujust` and its recipes, and automatic update staging.

Added by this image:

**Desktop and apps**
- niri compositor and Noctalia shell (optional)
- zsh installed (opt-in as your login shell, see `ujust user-setup`)
- Backup tools: snapper, btrfs-assistant, borgbackup, restic, rclone
- Virtual disk tools: libguestfs and virt-v2v (running virtual machines is in the dx image, see Variants)
- Cockpit and its host modules (off by default)
- PCP metrics
- Tailscale and `usbip` (off by default)
- Podman extras: podman-compose, podman-tui, podman-docker, kind; rootless Podman socket on for every user
- steam-devices, GSConnect, GameMode config, a Proton environment snippet
- Prebuilt sched_ext schedulers (`scx_*`) and the extest libraries for Steam Input on Wayland (installed, not enabled)
- Flatpak apps preinstalled: GNOME apps, Firefox, Thunderbird, GNOME Boxes, Vorta, Flatseal, Bazaar

**Removed from the base**
- gnome-software (Bazaar is the software center; firmware updates still work)
- The Firefox RPM (the Flatpak replaces it) and `toolbox` (distrobox replaces it)

**Compilers and build tools**
- The default image has none (neither does the base). The dx variant adds them (see Variants).

**Homebrew**
- Installed on first boot; formulae update automatically, upgrades are manual

**Distrobox**
- `ujust toolbox` creates and manages distrobox containers from definitions the image ships (`dev-toolbox`, `gaming`)
- Other recipes set up the owner's own configuration in your home directory (see Recipes)

**Hardening and defaults**
- sshd (off by default): no root login, no X11 or TCP forwarding; password and keyboard-interactive logins are not turned off
- Kernel and network tuning: ptrace scope, restricted kernel pointers, SysRq, BBR, a higher `vm.max_map_count`, zram swap tuning
- Firewall zone with named services (Sunshine, MoonDeckBuddy, Steam streaming, GSConnect, Tailscale)
- Security-key (YubiKey) touch for sudo and polkit (the password still works without a key); 30-minute sudo timeout
- Images are signed; after the second switch (Install, step 3) the system refuses unsigned updates

## Variants

| Image | Description | URL |
|---|---|---|
| default | The image described above | `ghcr.io/redcodeworks/octarine-os:latest` |
| NVIDIA | Adds the proprietary NVIDIA driver (built weekly; NVIDIA GPUs only, not used by the owner). With Secure Boot, enroll the key with `ujust enroll-secure-boot-key` | `ghcr.io/redcodeworks/octarine-os-nvidia:latest` |
| dx | Developer image: compilers and build tools, `-devel` libraries, `uv`, `rustup-init`, the VM-hosting set (libvirt, QEMU, virt-manager, Cockpit machines; the default image no longer has it), tracing tools, the `iommu=pt` kernel argument, and `ujust dev` (which can also install Visual Studio Code). Larger than the default | `ghcr.io/redcodeworks/octarine-os-dx:latest` |
| NVIDIA dx | The NVIDIA image with the same developer tools as dx (built weekly, NVIDIA GPUs only). The CUDA toolkit is not included: `ujust dev` can set it up in a container | `ghcr.io/redcodeworks/octarine-os-nvidia-dx:latest` |

The default and dx images also have a `beta` tag (for example `octarine-os:beta`): a weekly build on Universal Blue's beta base
that shows early what the next Fedora release would break. It is not tested for daily use. The NVIDIA images have only `latest`.

## Install

1. Install Fedora Silverblue (the current release, 45).
2. Switch to the image (this is the first install of it), then reboot:

   ```
   sudo bootc switch ghcr.io/redcodeworks/octarine-os:latest
   ```

3. Switch again so updates are signature-verified, then reboot:

   ```
   sudo bootc switch --enforce-container-sigpolicy ghcr.io/redcodeworks/octarine-os:latest
   ```

4. Install the preinstalled apps (run it from the desktop, in a terminal):

   ```
   ujust flatpak-preinstall
   ```

5. Optionally run `ujust user-setup`, then the other recipes below.

For a variant, run the steps above first, then switch with the same enforced command and the variant's URL from the table, or use `ujust switch-image`.

Pin a dated build, try the unreleased one, or roll back:

```
sudo bootc switch --enforce-container-sigpolicy ghcr.io/redcodeworks/octarine-os:latest-<date>-<sha>   # pin (tags are on the package page)
sudo bootc switch --enforce-container-sigpolicy ghcr.io/redcodeworks/octarine-os:testing               # unreleased build
sudo bootc rollback                                                                                    # boot the previous deployment
```

## Recipes

Run `ujust --list` for all of them; each recipe explains itself (`--help`).

| Recipe | What it does |
|---|---|
| `ujust flatpak-preinstall` | Installs the Flatpak apps the image lists |
| `ujust user-setup` | Checklist for a new user: groups, login shell (zsh is opt-in), Flatpak access, fonts, a fish terminal profile, GNOME search providers |
| `ujust gaming-setup` | Checklist for gaming: Steam, ProtonUp-Qt, Lutris, gamescope, MangoHud, Proton-GE, extest, launchers and GameMode tuning |
| `ujust niri-setup` | Sets up the niri session in your home directory: config files, portal file and Noctalia polkit agent |
| `ujust toolbox [<name>]` | Lists, creates and manages distrobox containers |
| `ujust switch-image [image] [channel]` | Switches to another published image (default, dx, nvidia, nvidia-dx) or channel (latest, beta, testing); `--list` shows what exists |
| `ujust toggle-updates [enable\|disable\|status]` | Checklist of the automatic updates: image, Flatpak, distrobox and Homebrew |
| `ujust update` | Updates exactly the sources that `ujust toggle-updates` has switched on |
| `ujust luks-tpm-unlock [enroll\|remove]` | Checklist of the LUKS devices: enrolls or removes TPM2 auto-unlock |
| `ujust hardware-setup [--list]` | Checklist of vendor and hardware specific setup; every step is hidden when your machine lacks that hardware (AMD or NVIDIA GPU, ROCm in a container, Secure Boot, TPM unlock, security key, fan sensors) |
| `ujust sensors-setup [--yes\|--no]` | Detects the fan and temperature chip of your board and loads its driver at boot, so the fan headers show up in `sensors` |
| `ujust gnome-candy <recipe>` | Themes and icons from [gnome-themes](https://github.com/redcodeworks/gnome-themes), installed into your home directory |
| `ujust dev` (DX only) | Developer setup checklist: libvirt, Homebrew tools, VS Code, JetBrains Toolbox, Rust, Java, Node, Python and, on an NVIDIA machine, the CUDA toolkit in a container |

## Contributing

This is a personal image; see `AGENTS.md`. Fork it rather than sending changes here.

## License

Apache-2.0, inherited from the [Universal Blue image template](https://github.com/ublue-os/image-template).
See `LICENSE`.

## Credits

The logo is a recolored version of the Fedora Silverblue logo; Fedora and the Fedora logo are trademarks of Red Hat, Inc.
The wordmark is set in JetBrains Mono (SIL OFL 1.1, © The JetBrains Mono Project Authors).

The shipped niri key bindings and defaults follow niri's own default configuration (GPL-3.0-or-later, by the niri authors).

The image ships prebuilt [extest](https://github.com/Supreeeme/extest) libraries (by Supreeeme and contributors, MIT license, built
from the owner's fork) that `ujust gaming-setup` installs for Steam, and the [sched_ext schedulers](https://github.com/sched-ext/scx)
(scx, GPL-2.0, by the sched-ext authors); the license texts and source records are in `/usr/share/licenses/octarine-os-binaries/`.

This image builds on [Universal Blue](https://universal-blue.org)'s `silverblue-main` base, its Homebrew files image and its image template (the template is Apache-2.0). The firewall service definition for GSConnect is from the GSConnect developers (GPL-2.0-or-later, noted in the file).

## About this repo

This is a personal project, assisted by Claude (Anthropic's coding assistant), so please excuse the slop.
I have only tested it on my own machine and will not actively maintain it beyond my own needs.

### Fork it

If you find something valuable here, you are encouraged to fork it: change the image name and organization,
generate your own signing key, and adjust the package list and files under `system_files/` to your taste. The
steps are in `CLAUDE.md`.
