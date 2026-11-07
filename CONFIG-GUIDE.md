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
  plugins, PCP for Cockpit metrics, backup tools, GNOME extensions and more. See `build_files/build.sh`.
- **Config under `system_files/`:** YubiKey PAM for sudo and polkit, sysctl tuning, sshd hardening,
  firewalld services and zone, GameMode settings, the `iommu=pt` kernel argument, a container
  signature policy for the image itself, and the Gruvbox themes.
- **Preinstalled Flatpaks:** official GNOME apps, Firefox, Thunderbird, virt-manager, Vorta,
  Flatseal and Extension Manager.
- **Build checks:** every build runs a smoke test before it is pushed and signed. See the README.

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
  and 4, terminals, Helix, bat, fzf, starship, btop and more. The shell and GTK themes ship in the
  image under `/usr/share/themes`.
- **GNOME extensions:** Dash to Dock, Blur My Shell, User Themes, GSConnect, Caffeine, AppIndicator,
  Auto Move Windows. Auto Move Windows sends apps to fixed workspaces: general, browsers, media and
  chat, games.
- **Keybindings for a keyboard with no arrow keys.** Right Command becomes Hyper and right Alt
  becomes Meh. Meh moves focus, Hyper moves windows, Super stays OS-level, Super+Alt launches apps,
  and Ctrl and Ctrl+Shift stay for applications and terminals. The same chords are mirrored in
  niri, GNOME and Zellij.
- **Settings capture:** GNOME settings are dumped with `dconf` and reloaded with `dconf load`.

## Shell and terminal

- bash is the login shell and stays authoritative. fish is launched by the terminals, so a login
  never depends on a Homebrew binary.
- Put system binaries ahead of Homebrew's in `PATH`. A brew `glib` once shadowed the system `gdbus`.
- The usual modern tools: Helix, starship, atuin, zoxide, fzf, bat, eza, yazi and Zellij.
- Terminals: Ghostty, Ptyxis and kitty.
- Homebrew's installer is a vendor `curl | bash` script. Read it before running it, and treat it as
  the exception to a no-pipe-to-shell rule.

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
- **Toolchain wrappers.** `distrobox-export` puts `cc`, `gcc`, `make`, `cmake`, `uv` and friends in
  `~/.local/bin`, so the host feels like it has a compiler. Add a stdin guard to the wrappers, or
  they hang tools that talk over stdio.
- Containers on the host network share loopback, so containers see host services. They also share `/tmp`.
- **Datastores:** Postgres, Valkey and SeaweedFS run in one shared pod on loopback, with a
  least-privilege role per database.

## Gaming and streaming

- **Steam is the Flatpak.** gamescope comes from the Flatpak extension and is wired into Steam with
  `ujust steam-gamescope-setup` (see Recipes). Set per-game launch options like
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

- **YubiKey for sudo and polkit** with `pam_u2f sufficient` and `nouserok`: a touch alone gives
  root, and a missing key falls back to the password. That is weaker than stock Fedora, and was
  accepted knowingly.
- **sshd:** key-only login, no root login, no forwarding. Check that `authorized_keys` works first.
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

## Clean install walkthrough

1. **Before wiping:** push the dotfiles, run the capture scripts, run the data backup, confirm sync
   clients are up to date and passphrases are stored elsewhere.
2. **Install Fedora Silverblue** to the OS drive only. UID 1000, same subuid/subgid range.
3. **Switch to the image:** `sudo bootc switch ghcr.io/<owner>/<image>:latest`, then reboot.
   Remove old layered packages first, since local layers get in the way of `bootc upgrade`.
4. **Fix identity:** run `ujust add-user-groups` for `gamemode`, `input` and `libvirt`, restore the
   `crypttab` and `fstab` lines for the data drives, and re-enroll TPM unlock.
5. **Clone the dotfiles into `~/.config`**, set the hooks path, and run the homefiles deploy script.
6. **Flatpaks:** the image preinstalls a set at first boot. Restore the rest and their overrides
   from the manifest. Restore app data before first launch where it matters (browser profiles).
7. **Homebrew,** then `brew bundle` from the Brewfile.
8. **Containers:** recreate the distroboxes from their config, enable lingering, restore Quadlets.
9. **Opt in to services:** `tailscaled`, `sshd`, `cockpit.socket`, the snapper timers.
10. **Restore data from borg,** then check `systemctl --failed`, the firewall zone,
    `sudo -n true` (it must ask for a password), and `id`.

## Recipes (`ujust`)

The image ships `just` recipes that run through `ujust`. Arguments are positional, for example
`ujust flatpak-games-access /mnt/games`. Every recipe is idempotent. The Flatpak ones only
add or remove their own entries, so your other overrides are left alone, and Flatseal (preinstalled)
shows the result.

| Recipe | What it does |
|---|---|
| `add-user-groups [user]` | Adds you, or the user you name, to `gamemode`, `input` and `libvirt`. These groups exist only in `/usr/lib/group`, so it copies their lines into `/etc/group` first. |
| `flatpak-theme-access` / `flatpak-theme-reset` | Lets every Flatpak app read the host GTK config, icons and `~/.themes`, read-only, with a global override. The reset removes just those entries. |
| `flatpak-games-access [path]` | Gives Steam, Bottles and Lutris access to a games directory (default `~/Games`). |
| `steam-gamescope-setup` / `steam-gamescope-reset` | Installs the gamescope Flatpak layer matching Steam's runtime and puts its `bin` directory on Steam's `PATH`. The reset removes only that line. |
| `steam-flatpak-devices` | Lets Flatpak Steam see USB and input devices (controllers). This widens the sandbox. |
| `vscode-flatpak-podman` | Lets Flatpak VS Code use Wayland and the rootless Podman socket, for dev containers. |
| `podman-desktop-deny-docker-socket` | Stops Podman Desktop reaching a Docker socket. |
| `chrome-flatpak-webapps` | Lets Flatpak Chrome write web app launchers and icons. |
| `gearlever-applications` | Lets Gear Lever manage AppImages in `~/Applications`. |
| `extest-build`, `extest-steam-setup` / `extest-steam-reset` | **Experimental.** Builds extest (an X11 XTEST to uinput shim that lets Steam Input work on Wayland without the "Allow Remote Interaction" prompt) and preloads it into Flatpak Steam. See the notes below. |

Notes on the extest recipes: the Flathub Steam package does not bundle extest, so the library
has to be built (it needs `cargo` and a C linker) and exposed to the sandbox. The recipes pin
the upstream commit the setup was tested with and preload the 64-bit build, since the Steam client
is 64-bit. Working inside the Flatpak client has not been verified end to end, and this may only be
a short-term workaround.

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
