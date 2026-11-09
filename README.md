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
- `user-setup` (groups and Flatpak access steps, one y/n question each), `toolbox`, `gnome-themes` (themes and icons live in their own repo), Steam gamescope and extest helpers; the full list is under "Recipes"

## Use it

1. Install Fedora Silverblue (the current release, 45).
2. Switch to the image and reboot:

   ```
   sudo bootc switch ghcr.io/redcodeworks/octarine-os:latest
   ```

3. Switch again with signature enforcement and reboot:

   ```
   sudo bootc switch --enforce-container-sigpolicy ghcr.io/redcodeworks/octarine-os:latest
   ```

4. Optionally run the user-level setup, an interactive checklist for the `gamemode`, `input` and `libvirt` groups
   and the Flatpak access overrides (`--yes` takes the defaults, `--no` only prints the plan):

   ```
   ujust user-setup
   ```

The first switch runs on a stock Fedora, whose container policy accepts any image, so it is unverified; you can check
the image first with `cosign verify --key cosign.pub ghcr.io/redcodeworks/octarine-os:latest`. The image installs its
own container signature policy (default `reject`, plus a `sigstoreSigned` rule for `ghcr.io/redcodeworks/octarine-os`),
so the second switch makes bootc pull the image again with signature verification enforced, and from then on
`bootc upgrade` verifies signatures. Running the enforced form on a stock Silverblue before step 2 fails with
`containers-policy.json specifies a default of insecureAcceptAnything; refusing usage`; that is expected, because the
policy exists only once the image is running.

Pin a dated build, try the unreleased one, or roll back (on a system that has done step 3):

```
sudo bootc switch --enforce-container-sigpolicy ghcr.io/redcodeworks/octarine-os:latest-<date>-<sha>   # pin (tags are on the package page)
sudo bootc switch --enforce-container-sigpolicy ghcr.io/redcodeworks/octarine-os:testing               # unreleased build
sudo bootc rollback                                                                                    # boot the previous deployment
```

## Security key (YubiKey) for sudo and polkit

sudo and polkit accept a FIDO2/U2F security-key touch instead of the password. The password keeps working when no
key is enrolled, and no PIN is required. `pam-u2f` and `pamu2fcfg` ship in the image; the PAM files are
`system_files/etc/pam.d/sudo` and `polkit-1`, both with `pam_u2f.so cue nouserok origin=pam://sudo appid=pam://sudo`
as a `sufficient` rule before the normal password stack.

- sudo asks for the touch only in an interactive local terminal. With no tty (scripts, non-interactive sudo) or in a
  remote session (the file skips `pam_u2f` when the terminal shows a remote host in `who`, as with ssh) it goes
  straight to the password, so nothing waits for a touch.
- Polkit authentication dialogs (GNOME) accept the touch too. The prompt is "Please touch the FIDO authenticator"
  (`cue`); `nouserok` means a user without an enrolled key just gets the password.

Enrol a key (the mapping must use the same origin and appid as the PAM line): plug it in, then

```
mkdir -p ~/.config/Yubico
pamu2fcfg -o pam://sudo -i pam://sudo > ~/.config/Yubico/u2f_keys
```

and touch the key when it blinks. pam_u2f reads one line per user, so a second (backup) key goes onto the same line:
`pamu2fcfg -o pam://sudo -i pam://sudo -n` prints only the key part (meant for appending). This joins it onto the
existing line whatever newlines the tool prints:

```
f=~/.config/Yubico/u2f_keys
{ tr -d '\n' < "$f"; pamu2fcfg -o pam://sudo -i pam://sudo -n | tr -d '\n'; echo; } > "$f.new" && mv "$f.new" "$f"
```

Verify: `sudo -k` then `sudo true` asks for the touch; `sudo -n true` (no tty path) says a password is required.
Opt out by not enrolling, or delete `~/.config/Yubico/u2f_keys`; the password path stays.

## Base image

Built on Universal Blue's `silverblue-main` for the current Fedora release (`ghcr.io/ublue-os/silverblue-main:45` today).

## Recipes

`ujust --list` shows them all.

| Recipe | What it does |
|---|---|
| `ujust user-setup [user] [--yes\|--no]` | Interactive checklist: add the user to `gamemode`, `input` and `libvirt` (sudo), then Flatpak overrides for game launchers (a games directory you name), Steam USB/input devices (default no, widens the sandbox), VS Code and the Podman socket, Podman Desktop without the Docker socket, Chrome web-app launchers and Gear Lever's `~/Applications`; steps for apps that are not installed or already done are skipped, and the summary lists how to undo each applied step |
| `ujust toolbox [<name> [options]]` | List the toolboxes, or create and manage one (`ujust toolbox dev-toolbox`, `ujust toolbox gaming`); `ujust toolbox <name> --help` shows the options; `--ide` makes IDE launchers (JetBrains icon: the one Toolbox registered, else the file in the app's `bin/`; rerunning refreshes the icon of launchers it created) |
| `ujust gnome-themes <recipe>` | Run a recipe of [gnome-themes](https://github.com/redcodeworks/gnome-themes): themes and icons live there, not in the image |
| `ujust steam-gamescope-setup` / `-reset` | Make Flatpak Steam and the gamescope layer work together, or undo it |
| `ujust extest-build`, `extest-steam-setup`, `extest-steam-reset` | Experimental: extest for Steam Input on Wayland |

## Contributing

This is a personal image; see `AGENTS.md`. `main` is protected: work happens on `testing` and a pull request
promotes it. Maintainer notes (design, CI, base image upgrades, forking, logo files) are in `CLAUDE.md`.

## License

Apache-2.0, inherited from the [Universal Blue image template](https://github.com/ublue-os/image-template).
See `LICENSE`.

## Credits

The logo is a recoloured version of the Fedora Silverblue logo; Fedora and the Fedora logo are trademarks of Red Hat, Inc.
The wordmark is set in JetBrains Mono (SIL OFL 1.1, © The JetBrains Mono Project Authors).

The experimental `ujust extest-build` recipe builds [extest](https://github.com/Supreeeme/extest) by Supreeeme
and contributors (MIT licence) from a pinned upstream commit; this repo ships none of its source.
