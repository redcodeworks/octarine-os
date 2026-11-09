# A tour of this desktop setup

A curated look at the configuration that goes with this image: what is in `~/.config`,
why it is set up that way, and how to rebuild it on a clean install. Think of it as an
"awesome configurations" list, not a set of recommendations. Take the pieces that suit you
and ignore the rest; plenty of choices here are personal taste or tied to one machine.

The dotfiles repository itself is private, so this guide describes the ideas and the
mechanisms instead of linking to files. Placeholders: `<user>` is the login name,
`<host>` the machine, `<owner>/<image>` this repo's published image.

Status: a snapshot from November 2026. Where something is untested or only partly
verified, it says so.

## The big picture

Four layers, each with one job:

| Layer | Holds | Tooling |
|---|---|---|
| System image | Kernel, desktop, daemons, drivers, PAM and firewall defaults | This repo's bootc image (Fedora Silverblue base) |
| Flatpak | GUI apps | System-scope Flatpaks, many preinstalled by the image |
| Homebrew | Day-to-day CLI tools and language servers | `brew bundle` from a Brewfile |
| Distrobox | Compilers, language runtimes, anything needing a real package manager | One container per purpose |

Two ideas run through everything:

- **Servers are Quadlets, clients are distroboxes.** Always-on services (databases, caches,
  object storage) run as rootless Podman Quadlets on the host, bound to loopback.
  Distroboxes connect to them as clients.
- **Snapshots of the host, not hand edits.** Anything touched under `/etc` is copied into the
  dotfiles repo, and package choices live in manifests, so a rebuild is a replay.

## What the image provides

Everything system-level that used to be hand-layered now lives in this repo:

- **Packages:** the niri compositor with the Noctalia shell, libvirt and QEMU, Cockpit and its
  plugins, PCP for Cockpit metrics, backup tools, GSConnect and more. See `build_files/build.sh`.
- **Config under `system_files/`:** YubiKey PAM for sudo and polkit, sysctl tuning, sshd hardening,
  firewalld services and zone, GameMode settings, the `iommu=pt` kernel argument, a container
  signature policy for the image itself.
- **Preinstalled Flatpaks:** official GNOME apps, Firefox, Thunderbird, virt-manager, Vorta,
  Flatseal, Extension Manager and Bazaar (the software center; gnome-software is removed, firmware
  updates stay available through `fwupdmgr`).
- **Build checks:** every build runs a smoke test before it is pushed and signed.

What the image deliberately leaves to you: `sshd`, `tailscaled`, `cockpit.socket` and the snapper
timers are installed but not enabled. Turn on what you use.

## The dotfiles repo, ideas worth borrowing

- **Allow-list `.gitignore`.** `~/.config` is the repo and ignores everything by default; each
  tracked path is added on purpose. That keeps secrets and caches out without a long deny list.
- **A `homefiles/` directory for things outside `~/.config`.** Files that belong in `$HOME`
  (`.bashrc`, `.local/bin` scripts, `.desktop` launchers) are stored under `homefiles/` and
  symlinked back by a script that defaults to a dry run.
- **Read-only `/etc` snapshots.** Touched `/etc` files are copied under `etc/` by a sync script
  and committed for history. The real file stays in `/etc`, and nothing is symlinked.
- **Capture scripts and manifests.** Brew, Flatpak (with overrides), distrobox, systemd units,
  firewall zones, dconf and layered packages are dumped into text manifests, so a clean install
  has something to compare against.
- **A secret scanner on `git push`.** A gitleaks hook runs before anything leaves the machine.

## Disk, boot and encryption

- **Layout:** one drive for the OS (EFI, `/boot`, LUKS-encrypted btrfs for root and home), a
  separate LUKS volume with LVM for data and container storage, and a third drive for a Windows
  dual boot. The point is that a reinstall touches only the OS drive.
- **TPM unlock:** the data volume unlocks through the TPM (`tpm2-device=auto` in `crypttab`). After
  a rebase or reinstall the TPM keyslot can stop matching the boot state, and systemd falls back to
  asking for the passphrase. Re-enrolling bound to PCR 7 (Secure Boot state) is the usual fix, for
  example with `systemd-cryptenroll`. Keep a LUKS header backup and redo it after any keyslot change.
- **GRUB:** a `custom.cfg` adds a Windows chainloader entry and a longer menu timeout. The
  bootupd static config ignores `next_entry`, so a small block handles one-shot boots. This part
  was marked not yet re-tested.
- **Reinstall rules that matter:** install to the OS drive only, use UID 1000, and keep the same
  `subuid` and `subgid` range. Otherwise rootless Podman's btrfs storage ownership breaks.

## Login and boot logo (icon and wordmark)

- **Where:** the PNGs are in `system_files/usr/share/octarine-os/logo/` (`/usr/share/octarine-os/logo/` on the
  image). GDM reads it through `zz-octarine-login-screen.gschema.override` (sorts after gdm's own override;
  `build.sh` runs `glib-compile-schemas`). Plymouth uses its own theme `octarine`, generated by `build.sh` from
  `bgrt` plus the spinner assets with our `watermark.png`, selected by `system_files/etc/plymouth/plymouthd.conf`.
  The initramfs is regenerated in the build (dracut, ostree module), because the boot and LUKS passphrase
  screens run from it.
- **Size:** `octarine-logo.png` is 465x72, about 24% of a 1920 px screen and about 9% of 5120 px as the Plymouth
  watermark; how GDM handles that width is unverified.
- **Change it:** replace the PNG, push, let CI rebuild. **Hide the GDM logo:** `logo=''` in the override.
- **Undo:** delete the override file and `plymouthd.conf` (and the theme block and dracut step in `build.sh`);
  the stock Fedora logos return. The vendor logo that `bgrt` shows comes from the UEFI firmware, not the OS.
- **Not tested by CI:** how either screen renders; that needs a boot.

## Package tiers, login shell and build cancelling

- `build_files/build.sh` installs CRITICAL packages in one transaction (missing one fails the build; the smoke test
  also requires the RPM vendor `Fedora Project`) and OPTIONAL packages in groups (`misc`, `codecs`, `cockpit`, `pcp`,
  `containers`, `libguestfs`). Failed optional packages are listed in
  `/usr/share/octarine-os/optional-packages-missing` (read it on a machine to see what an image lacks) and appear as
  CI warnings. Outside-Fedora packages (negativo17 `gstreamer1-plugins-bad`/`-ugly`) are optional only.
- `fish` is optional: nothing in the image depends on it and it is never a login shell (bash stays the login shell; new users get zsh). A user who configures their own terminal to start fish needs it installed, which is their own setting.
- New users get `zsh` (`/etc/default/useradd`, `/etc/skel/.zshrc`); existing users are unchanged. Rolling back to an
  image without zsh breaks only accounts created meanwhile; distrobox copies the host login shell, so toolbox
  images need zsh too (`gaming` unchecked).
- CI: a newer push to `testing` (or a PR) cancels the older build; `main` and the scheduled run never are. A cancelled
  build can leave the `testing` tag unsigned until the next build finishes.

## Snapshots

- Snapper takes timeline snapshots of `/home` only (hourly, daily, monthly), with space-pressure
  pruning. There is no root config, because ostree deployments already cover `/usr` and `/etc`.
- Order matters: install snapper, reboot, convert the directories you want excluded
  (`~/.cache`, game libraries) to their own subvolumes, then run the setup script.
- It is not a backup, since it sits on the same disk. Gotcha: GIO cannot move files to Trash across
  a subvolume boundary, so deletes in excluded directories are permanent.

## Desktop

- **Sessions:** GNOME is the main session. niri is a second session using Noctalia as its shell
  and panel. Hyprland support exists, using its Lua config format, and is the least finished part.
- **niri needs a polkit agent** started with the session, and a portal config that prefers the
  GNOME and GTK portals.
- **Theme:** Gruvbox Material, dark and medium contrast, applied by hand across the shell, GTK 3
  and 4, terminals, Helix, bat, fzf, starship, btop and more. The themes are not in the image:
  `ujust gnome-candy install-theme` fetches them from github.com/redcodeworks/gnome-themes and
  `ujust gnome-candy install-icon` fetches icon sets (Papirus, Tela, Fluent, Gruvbox Plus, Zafiro, Candy), both into your home directory.
- **GNOME extensions:** the image ships GSConnect (and its Nautilus integration). The rest are
  per-user, and Extension Manager is preinstalled for adding them. The ones used here: Dash to
  Dock, Blur My Shell, User Themes (needed to apply a GNOME Shell theme), Caffeine, AppIndicator
  and Auto Move Windows, which sends apps to fixed workspaces: general, browsers, media and chat,
  games.
- **Keybindings for a keyboard with no arrow keys.** Right Command becomes Hyper and right Alt
  becomes Meh. Meh moves focus, Hyper moves windows, Super stays OS-level, Super+Alt launches apps,
  and Ctrl and Ctrl+Shift stay for applications and terminals. The same chords are mirrored in
  niri, GNOME and Zellij.
- **Settings capture:** GNOME settings are dumped with `dconf` and reloaded with `dconf load`.

## Shell and terminal

- bash is the login shell and stays authoritative. a login never depends on a
  Homebrew binary (a terminal set up to start fish is the user's own choice).
- Put system binaries ahead of Homebrew's in `PATH`. A brew `glib` once shadowed the system `gdbus`.
- The usual modern tools: Helix, starship, atuin, zoxide, fzf, bat, eza, yazi and Zellij.
- Terminals: Ghostty, Ptyxis and kitty.
- Homebrew comes from the image, as files: Universal Blue's `ghcr.io/ublue-os/brew` (a tarball of the prefix
  plus systemd units), copied in at build time. On first boot `brew-setup.service` extracts it to
  `/home/linuxbrew/.linuxbrew` and hands it to UID 1000 (hard-coded, so the first user must be 1000); it is
  skipped when that prefix or `/etc/.linuxbrew` already exists, so an existing machine keeps its own brew.
  Only `brew-update.timer` (every 6 hours) is enabled; `brew-upgrade.timer` is kept off by this image's own
  preset: upgrades are manual (`brew upgrade`, or opt in per machine with
  `sudo systemctl enable --now brew-upgrade.timer`, undone with `disable --now`), so they stay under your soak
  policy, and only `brew update` (metadata, every 6 hours per the upstream unit) runs by itself. brew goes at the end of `PATH` (system binaries win).
  The image does not pin formulae: `brew bundle` from a Brewfile (kept outside the image) is what makes them
  reproducible. The brew tarball is pinned by digest (`ARG BREW_TAG` and `ARG BREW_DIGEST` in the Containerfile; `just brew-bump`
  moves the pin and verifies its signature, `just brew-tags` lists the newest tags); the build logs the pinned
  reference, which is the record of what a build used. Upstream builds the tarball by running
  Homebrew's own `install.sh`. To undo: remove the `brew` stage, the `COPY --from=brew` line, the
  `systemctl preset` line and the preset file; existing prefixes are untouched. If the prefix is missing,
  repair by hand (unverified): `sudo mkdir -p /var/home/linuxbrew/.linuxbrew`, chown it to your user, and
  `sudo systemctl start brew-setup.service` only if `/etc/.linuxbrew` is absent. The toolbox's tools come
  with its image. The host has no compilers.

## Containers

- **Rootless Podman on btrfs.** A `storage.conf` selects the btrfs driver and moves the graph root
  to the container volume. `CONTAINERS_STORAGE_CONF` has to be exported in bash, fish and
  `environment.d`, or Podman falls back to overlay.
- **Quadlets** live in `~/.config/containers/systemd/`. They need lingering
  (`loginctl enable-linger <user>`) and the user Podman socket, which this image enables for every
  user. Use `podman secret` for credentials.
- **Distroboxes by purpose:** Fedora for builds and language tooling with a shared home, Ubuntu for
  data science, Arch for AUR and bleeding-edge tools, Debian as a stand-in on-prem server, an AI
  stack, and a Steam container. Only the Fedora one shares the real home; the others get an isolated
  one.
- **No build tools on the host.** Builds belong in the dev-toolbox (`ujust toolbox dev-toolbox`): a distrobox
  with a shared home whose build chain, `uv`, the rustup proxies and a few CLI tools are exported to
  `~/.local/bin`, so the host feels like it has a compiler.
- Containers on the host network share loopback, so containers see host services. They also share `/tmp`.
- **Datastores:** Postgres, Valkey and SeaweedFS run in one shared pod on loopback, with a
  least-privilege role per database.

## Gaming and streaming

- **Steam is the Flatpak.** gamescope comes from the Flatpak extension and is wired into Steam with
  `ujust gaming-setup` (see Recipes). Set per-game launch options like
  `gamescope -f -W <w> -H <h> -r <hz> --adaptive-sync -- %command%`.
  - The Flatpak gamescope has no `cap_sys_nice` and no DRM backend.
  - If a game won't start, check that a Proton is selected for it. Without one, Steam tries to run
    the Windows `.exe` natively.
  - Lutris cannot wrap Steam games with gamescope or GameMode. This is a known upstream limit.
- **GameMode** with a twist: it switches `tuned` to `latency-performance` while a game runs and back
  to `balanced` after. If the daemon dies mid-game, run `tuned-adm profile balanced`. The shipped
  config keeps the governor at `powersave`, working around an upstream bug on amd-pstate.
- **Sunshine and Moonlight streaming:** Sunshine runs as a Flatpak user unit and is not autostarted.
  A prep command switches the display to the client's resolution and back, with separate niri,
  Hyprland and GNOME backends. A lock-watcher stops it when the session locks. Keep a rescue
  chord, and know how to run the undo over SSH.
- **Tuning shipped in the image:** a high `vm.max_map_count`, BBR, large inotify limits, a raised
  memlock limit and SysRq enabled.

## Security choices

Some of these are tradeoffs you may not want.

- **YubiKey for sudo and polkit** with `pam_u2f sufficient` and `nouserok`: a security-key touch
  is accepted instead of the password, no PIN is required, and without an enrolled key the password
  still works (see "Security key" in the README).
- **sshd:** the image disables root login and X11 and TCP forwarding, and leaves sshd off. Key-only
  login (`PasswordAuthentication no`) is a separate drop-in that is not shipped, so set it yourself
  once your `authorized_keys` works.
- **Firewall:** the default zone keeps a short allow-list of named services plus Tailscale's UDP
  port, with the wide high-port range removed. A zone that names a missing service makes firewalld
  silently fall back to the wide stock config. Check with `firewall-cmd --check-config`.
- **Loopback-only services** are structurally unreachable from the network. The firewall is the
  second line.
- **Sysctl hardening:** `ptrace_scope=1` and `kptr_restrict=1`.
- **SELinux stays enforcing.** Root-equivalent group membership (`docker`, `incus-admin`) is removed.
- **Signed images:** the image is cosign-signed, and the shipped container policy verifies it.

## Backups and restore

- **Borg** to a separate machine, scheduled through the Vorta Flatpak. The repo holds LUKS header
  backups, container homes (minus the image cache), the data volume minus games, and `~/.ssh`.
  VM disks are not included. Export the repo key and keep it off the machine.
- Gotcha: in Vorta, pick **Add Existing Repository**. **Initialize** wiped a repo once.
- The restore procedure was written down and has **not been tested end to end on a clean install**.

## Changing the base image

The base is `${BASE_IMAGE}:${FEDORA_VERSION}`: defaults in the workflow `env:` block (and the `Containerfile`
ARGs), overridable with the repository variables of the same names. A Fedora major upgrade:

1. Set the variable: `gh variable set FEDORA_VERSION --body 46 -R <owner>/<image>` (undo: `gh variable delete
   FEDORA_VERSION`), or edit the default in the workflow `env:` block and the `Containerfile` ARG on a commit.
2. Changing a variable does not start a build: run the `Build container image` workflow on `testing` (a push to
   `testing` or manual dispatch). The "Check the base image can be pulled" step fails early and names the tag if
   it does not exist (`skopeo list-tags docker://ghcr.io/ublue-os/silverblue-main` lists them); the smoke test
   checks that `VERSION_ID` matches. The log and the OCI labels `org.opencontainers.image.base.name` and
   `base.digest` record the resolved base.
3. Test the `testing` build: `sudo bootc switch --enforce-container-sigpolicy ghcr.io/<owner>/<image>:testing` (or the testing VM).
4. Soak about a week and keep the current deployment pinned as the rollback (`sudo ostree admin pin <index>`).
   Then merge the pull request: promotion only retags an already tested `testing` digest, so a variable changed
   without a tested `testing` build never reaches `latest` by promotion; the daily scheduled `main` build does
   read the variable, so set it only when you intend the next scheduled build to use it.

## Clean install walkthrough

1. **Before wiping:** push the dotfiles, run the capture scripts, run the data backup, confirm sync
   clients are up to date and passphrases are stored elsewhere.
2. **Install Fedora Silverblue** to the OS drive only. UID 1000, same subuid/subgid range.
3. **Switch to the image:** `sudo bootc switch ghcr.io/<owner>/<image>:latest`, reboot, then repeat it with
   `--enforce-container-sigpolicy` and reboot again (the first switch runs under stock Fedora's accept-anything policy).
   Remove old layered packages first, since local layers get in the way of `bootc upgrade`.
4. **Fix identity:** run `ujust user-setup` (groups `gamemode`, `input` and `libvirt`, the zsh login shell, fish profile, search providers and the Flatpak access steps), restore the
   `crypttab` and `fstab` lines for the data drives, and re-enroll TPM unlock.
5. **Clone the dotfiles into `~/.config`**, set the hooks path, and run the homefiles deploy script.
6. **Flatpaks:** `ujust flatpak-preinstall` (from a desktop terminal) installs the set the image lists. Restore the rest and their overrides
   from the manifest. Restore app data before first launch where it matters (browser profiles).
7. **Homebrew, then dev-toolbox:** brew's prefix appears on first boot (`brew-setup.service`), so run
   `brew bundle` from the Brewfile, then `ujust toolbox dev-toolbox` (builds the box, installs nothing on the
   host, mounts the prefix read-only). If the box came first, run `ujust toolbox dev-toolbox --recreate`.
8. **Containers:** recreate the distroboxes from their config, enable lingering, restore Quadlets.
9. **Opt in to services:** `tailscaled`, `sshd`, `cockpit.socket`, the snapper timers.
10. **Restore data from borg,** then check `systemctl --failed`, the firewall zone,
    `sudo -n true` (it must ask for a password), and `id`.

## Recipes (`ujust`)

Recipes run through `ujust`; arguments are positional, for example `ujust toolbox dev-toolbox`.
They are idempotent. The README has the one-line list and `ujust --list` is the index; options, state files
and safeguards are in `CLAUDE.md`. What you need to use them:

- **`user-setup [user] [--yes|--no] [--only STEP[,STEP...]]`:** an interactive checklist, one y/n question per step,
  in this order: `groups` (join `gamemode`, `input` and `libvirt`), `shell` (login shell to zsh with `usermod -s`; copies
  the skeleton zsh files when you have none), `flatpak` (games directory for Steam, Bottles and Lutris, Steam USB and
  input devices, VS Code and the rootless Podman socket, Podman Desktop without the Docker socket, Chrome web-app
  launchers, Gear Lever's `~/Applications`), `fonts` (Nerd Fonts from Homebrew casks: the 12-font developer set from
  `/usr/share/octarine-os/homebrew/fonts.Brewfile` by default, JetBrains Mono only, a pick from all Nerd Font casks, or
  skip; then optionally the Ptyxis terminal font), `fish-terminal` (a Ptyxis profile that starts fish, made the default,
  plus starship from Homebrew hooked in through `~/.config/fish/conf.d/starship.fish`) and `search` (the Calculator,
  Bazaar, Characters and Clocks GNOME search providers; the Calculator goes first; existing entries are merged, never
  replaced). Each step is skipped when the app is not installed or the change is already in place; Enter takes the
  default. `--yes` takes the defaults without asking, `--no` changes nothing and prints the plan. The summary lists how
  to undo each applied step.
- **`gnome-candy <recipe> [name]`:** themes and icons from the gnome-themes repo into your home
  directory (`install-theme`, `switch-theme`, `install-icon`, `switch-icon`; no name opens a checklist with everything off).
- **`toolbox [<name> [options]]`:** no name lists the toolboxes; with a name it creates and manages one
  (`--help` shows the options). A box created before the brew prefix existed lacks the read-only brew mount; run
  `ujust toolbox dev-toolbox --recreate` to add it.
  It then asks which container `distrobox enter` should open by default: Enter takes the toolbox's own name,
  another name sets that, `-` leaves the current value.
- **`toolbox gaming`:** a second Steam client in its own container with its own home. The Flatpak Steam on the
  host stays the primary client; the container never shares its library folders (the isolated home guarantees
  it), so do not point both at the same library. It exports a `gaming-steam` launcher to the host.
  Two optional variables in your own shell environment: `TOOLBOX_HOMES_DIR` (where isolated homes live, default
  `~/.local/share/toolbox-homes`; point it at a bigger disk, then the home is `$TOOLBOX_HOMES_DIR/gaming`) and
  `TOOLBOX_VOLUMES` (extra binds `src:dst[:opts]`, space-separated, for example your games disk, applied when the
  box is created; use `--recreate` after changing it). `--remove` keeps the home; `--remove --purge-home` deletes
  it after a typed `yes`.
- **`gaming-setup [step...] [--yes|--no]`:** a checklist, or name steps to run exactly those: `steam`, `protonup`
  (ProtonUp-Qt), `lutris` (Flatpaks from Flathub, installed only when Flathub lists them as verified),
  `extensions` (gamescope and MangoHud Vulkan layers for Steam's runtime branch, Proton-GE, and a PATH override so
  they resolve inside the sandbox), `extest` (experimental; builds a pinned upstream commit, in the dev-toolbox when the
  host has no cargo), `desktop` (generated Steam launchers in `~/.local/share/applications`, marked with an
  `X-Octarine-Generated` key; extest is hooked in when built; a gamescope launcher uses your current resolution and
  refresh rate), `gamemode` (installs the tuning from `/usr/share/octarine-os/gamemode.ini` as
  `~/.config/gamemode.ini`, never silently over a different file) and `reset` (removes the generated launchers and
  the PATH line, optionally the extest library, and undoes the gamemode file when unchanged). Installed Flatpaks stay.

Ideas for more, each a candidate for its own recipe:

- One-shot reboot into Windows through a GRUB `next_entry`
- Re-enrolling TPM unlock after a rebase
- Snapper setup (the subvolume conversion and config)
- Syncing RetroArch info files for Lutris, plus an emulation health check
- Fixing the Ghostty icon after an AppImage update
- A firewall sanity check, including the "missing service" case
- Exposing host GE-Proton builds to the Flatpak Steam

Recipes live in `system_files/usr/share/ublue-os/just/60-custom.just`.

## Caveats

- This is one person's setup. Hardware (an AMD desktop, an ultrawide monitor, a Wi-Fi-less
  wired box) shapes several choices.
- Some older notes this was assembled from predate the image and still mention layering packages
  by hand, or Arch-era workarounds. The image replaces the layering.
- Parts remain unverified: the restore procedure on a clean machine, the Hyprland config,
  the GRUB one-shot boot, and some niri window rules.
