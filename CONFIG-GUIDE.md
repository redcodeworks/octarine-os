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
  and 4, terminals, Helix, bat, fzf, starship, btop and more. The themes are not in the image:
  `ujust gnome-themes install-themes` fetches them from github.com/redcodeworks/gnome-themes and
  `ujust gnome-themes install-icons` fetches icon sets (Papirus, Tela, Fluent, Gruvbox Plus, Zafiro, Candy), both into your home directory.
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

- bash is the login shell and stays authoritative. fish is launched by the terminals, so a login
  never depends on a Homebrew binary.
- Put system binaries ahead of Homebrew's in `PATH`. A brew `glib` once shadowed the system `gdbus`.
- The usual modern tools: Helix, starship, atuin, zoxide, fzf, bat, eza, yazi and Zellij.
- Terminals: Ghostty, Ptyxis and kitty.
- Homebrew's installer is a vendor script, which is why Homebrew is not baked into the image (its
  prefix has to be owned by the user who runs it). `ujust brew` installs it on the host. It downloads
  the installer to a file, prints its hash, lets you read it, runs it only after you confirm, and
  blocks sudo. Treat the installer as vendor code you are trusting.
- **The rule for installing software:** the toolbox's tools are baked into its image (packages are
  added in the fedora-toolbox repo, not installed in the box). An installer script is
  only for something that has no package (SDKMAN and nvm; rustup is Fedora's `rustup-init`, run once in your home), and nothing may need sudo. Homebrew stays
  a separate host recipe. The image itself has no compilers or build tools.

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
- **No build tools on the host.** The image carries no gcc, make, cmake, ninja, meson or the
  development-tools group, because builds belong in the Fedora toolbox and a compiler on the host
  invites installs that bypass it. `ujust dev-toolbox` creates that box from
  `/usr/share/ublue-os/distrobox/fedora-toolbox.ini` and runs `distrobox-export` so that `cc`, `gcc`,
  `make`, `cmake`, `uv`, the rustup proxies (`~/.cargo/bin`, created by `rustup-init`), `sdk` and a few CLI tools appear in `~/.local/bin`, and
  the host feels like it has a compiler. Add a stdin guard to the wrappers, or they hang tools that
  talk over stdio. See the recipe notes below for `--recreate`, `--remove`, `--upgrade`, `--update`
  and `--ide`.
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
7. **Dev toolbox, then Homebrew:** `ujust dev-toolbox` (builds the box, installs nothing on the host),
   then run the one-time `sudo mkdir` and `chown` for brew's prefix that `ujust brew` prints, run
   `ujust brew`, then `brew bundle` from the Brewfile. If brew came after the box, run
   `ujust dev-toolbox --recreate` so the box gets the read-only brew mount.
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
| `gnome-themes [recipe] [name]` | Runs a recipe of github.com/redcodeworks/gnome-themes from a fresh checkout in `~/.cache/gnome-themes/repo`: `install-themes`, `update-themes`, `remove-themes`, `list-themes`, `switch-theme`, and the same five for icons (`install-icons`, `update-icons`, `remove-icons`, `list-icons`, `switch-icons`). Without a name the install, remove and switch recipes show a checklist. Themes land in `~/.themes` and icons in `~/.local/share/icons`. Flatpak access for themes is handled by `ujust gnome-themes switch-theme` (it asks first). Needs network, git and just; `GNOME_THEMES_REF` picks a branch, tag or commit. |
| `flatpak-games-access [path]` | Gives Steam, Bottles and Lutris access to a games directory (default `~/Games`). |
| `steam-gamescope-setup` / `steam-gamescope-reset` | Installs the gamescope Flatpak layer matching Steam's runtime and puts its `bin` directory on Steam's `PATH`. The reset removes only that line. |
| `steam-flatpak-devices` | Lets Flatpak Steam see USB and input devices (controllers). This widens the sandbox. |
| `vscode-flatpak-podman` | Lets Flatpak VS Code use Wayland and the rootless Podman socket, for dev containers. |
| `podman-desktop-deny-docker-socket` | Stops Podman Desktop reaching a Docker socket. |
| `chrome-flatpak-webapps` | Lets Flatpak Chrome write web app launchers and icons. |
| `gearlever-applications` | Lets Gear Lever manage AppImages in `~/Applications`. |
| `dev-toolbox [--list] [--recreate] [--remove [--dry-run]] [--upgrade [--check]] [--update] [--ide ...] [tool ...]` | Builds the `fedora-toolbox` distrobox from the image's definition, makes it the default for `distrobox enter`, sets up uv, rustup, SDKMAN and nvm in it, and exports the build chain and CLI tools to `~/.local/bin`. Details in the notes below. |
| `brew` | Installs Homebrew on the host. The prefix `/home/linuxbrew/.linuxbrew` (`/home` is `/var/home` here) must exist and be yours first; if not, the recipe prints the one-time `sudo mkdir` and `chown` for you to run and stops. The installer is downloaded to a temp file, hashed, shown on request (`v`) and run only after `y`, with a `sudo` stub first on `PATH` and `no_new_privs` set. It prints the `brew shellenv` lines for bash and fish and edits no rc files. |
| `extest-build`, `extest-steam-setup` / `extest-steam-reset` | **Experimental.** Builds extest (an X11 XTEST to uinput shim that lets Steam Input work on Wayland without the "Allow Remote Interaction" prompt) and preloads it into Flatpak Steam. See the notes below. |

Notes on the extest recipes: the Flathub Steam package does not bundle extest, so the library
has to be built (it needs `cargo` and a C linker) and exposed to the sandbox. The recipes pin
the upstream commit the setup was tested with and preload the 64-bit build, since the Steam client
is 64-bit. Working inside the Flatpak client has not been verified end to end, and this may only be
a short-term workaround.

Notes on `dev-toolbox`:

- **What it does, in order.** It creates the box with `distrobox assemble create` from the definition
  (`/usr/share/ublue-os/distrobox/fedora-toolbox.ini`, pointing at `ghcr.io/redcodeworks/fedora-toolbox:latest`:
  our own toolbox image, built weekly from the `fedora-toolbox` repo on top of Universal Blue's toolbox,
  with the compilers, `-devel` libraries, uv, `rustup-init` and CLI tools already installed; it asks
  first and prints which image it uses), sets `container_name_default="fedora-toolbox"` in
  `~/.config/distrobox/distrobox.conf` (creating the file, or changing only that key and asking before
  replacing another value), shows a checklist for uv, rustup, SDKMAN and nvm (SPACE toggles, ENTER
  confirms, q skips; or name them: `ujust dev-toolbox sdkman nvm`), and exports to `~/.local/bin` (or
  `$UPM_EXPORT_DIR`) with `distrobox-export --bin`: the build chain (`cc gcc g++ c++ make cmake ninja
  meson ld as ar nm objdump strip ranlib pkg-config`, whichever exist in the box), `lsscsi nicstat
  waypipe evtest guestfish virt-v2v flatpak-builder`, `uv`/`uvx`, the rustup proxies from `~/.cargo/bin` (not `rustup-init`), and an
  `sdk` wrapper script (sdk is a shell function). `--list` shows the box, the default name, each tool's
  source (`image:<tool>` or `installer`) and export state. It never overwrites an existing file or
  link, edits no rc files, uses no sudo and never runs as root.
- **The image first.** uv and `rustup-init` come with the toolbox image, so the recipe only exports
  uv. Fedora's `rustup` package ships only `/usr/bin/rustup-init`; `~/.cargo/bin/rustup` and the
  proxies do not exist until it has run in your home, so the rustup row counts as installed when
  `~/.cargo/bin/rustup` exists, and otherwise (after asking, behind the no-sudo guard) runs
  `rustup-init -y --no-modify-path --default-toolchain stable` (a normal download from
  static.rust-lang.org) and exports the proxies it finds in `~/.cargo/bin`. If a tool is missing from
  the box, it says so and points at `--upgrade` (the image is rebuilt weekly): it cannot install
  packages itself, because that would need sudo. SDKMAN and nvm have no Fedora package, so they are the only vendor installer scripts: each is
  downloaded to a file, hashed, shown on request (`v`) and run only after `y`, with a `sudo` stub first
  on `PATH` and `no_new_privs` set. Installs of SDKMAN, nvm and rustup live in the
  shared home.
- **Shared home.** The definition has no `home=` key on purpose, so the box's `$HOME` is yours:
  `~/.cargo`, `~/.rustup`, `~/.sdkman`, `~/.nvm`, caches and dotfiles are shared.
- **Brew mount.** The definition mounts `/home/linuxbrew` read-only so Python source builds can see
  brew's Python. The directory must exist when the box is created and the recipe cannot create it
  (that needs root), so while it is missing the recipe drops the `volume=` line from a temporary copy
  of the definition and says so. After `ujust brew`, run `ujust dev-toolbox --recreate`.
- **Trying it before the image ships it.** Run it straight from a checkout, without `ujust`:
  `DEV_TOOLBOX_DEFINITION=system_files/usr/share/ublue-os/distrobox/fedora-toolbox.ini just --justfile
  system_files/usr/share/ublue-os/just/60-custom.just dev-toolbox` (the justfile has no imports, so
  this works as is; `DEV_TOOLBOX_DEFINITION` defaults to the installed path). To try another tag of
  the toolbox image, such as `testing` before `latest` exists, set `DEV_TOOLBOX_IMAGE` (for example
  `DEV_TOOLBOX_IMAGE=ghcr.io/redcodeworks/fedora-toolbox:testing ujust dev-toolbox`); it replaces the
  definition's `image=` line, and the recipe prints the image it uses.
- **`--recreate` (replace the box).** Asks, then removes the old container, removes the export files
  the state file lists (never a file it did not create), and creates the box again from the
  definition. Wipe by hand with `distrobox rm --force fedora-toolbox`. What survives: your whole
  shared home (`~/.cargo`, `~/.rustup`, `~/.sdkman`, `~/.nvm`, caches). What does not: packages you
  installed inside the box and everything else in the container's own filesystem.
- **`--remove` (clean up everything it made).** Differs from `--recreate`: nothing is rebuilt. It
  records in `$XDG_STATE_HOME/ublue-os/dev-toolbox` (default `~/.local/state/ublue-os/dev-toolbox`)
  what it created, including whether `~/.sdkman`, `~/.nvm`, `~/.rustup` and `~/.cargo` existed before
  its install steps. It deletes only what the state file says it created and skips, with the reason,
  any directory that already existed. It lists everything with sizes (exports, launchers, the
  `container_name_default` key, the container, the directories, the state file), warns that
  `~/.cargo` and `~/.sdkman` can hold things you installed afterwards (cargo install binaries, JDKs,
  Spark, Hadoop), and needs you to type `yes`. `--remove --dry-run` only prints the list. Order:
  exports and launchers, the default-name setting, the container, the directories, the state file
  last; a failed step stops and leaves the state file, so running it again finishes the job. It never
  touches `/usr` or `/etc`, never removes `~/.local/bin` itself and uses no sudo.
- **`--upgrade` (newer toolbox image) and `--update` (package updates).** A container never changes
  its image after creation. `--upgrade` pulls the toolbox image (the definition's, or
  `DEV_TOOLBOX_IMAGE`), compares its image id with the one the box was created from, and says
  `already on the latest image` if they match. `--upgrade --check` only reports both digests and the
  Fedora release of each and changes nothing. If the image is newer it warns when the Fedora major
  changes, asks for `yes` and replaces the box the way `--recreate` does. There is no package
  resolution test here: the fedora-toolbox repo's CI proves the package list installs when it builds
  the image. `--update` is separate and only runs `distrobox upgrade fedora-toolbox` (package updates
  inside the existing container).
- **`--ide` (launchers that start an IDE inside the box).** Writes
  `~/.local/share/applications/fedora-toolbox-<id>.desktop` with
  `Exec=distrobox enter -n fedora-toolbox -- <launcher> %F`, so the IDE is a process of the container:
  its terminals, run configurations and language servers use the box's compilers, libraries and
  package managers, without relying on exports. It only detects, never installs, and the box must
  already exist (it offers to start a stopped box, and never creates one). JetBrains IDEs (`pycharm
  idea datagrip rustrover clion goland webstorm`) use the stable shell scripts JetBrains Toolbox
  generates, in `~/.local/share/JetBrains/Toolbox/scripts` by default; turn on "Generate shell
  scripts" in the Toolbox settings if they are missing. The icon is taken from the IDE directory the
  script launches, so no versioned path is hardcoded. VS Code (`vscode`) uses a `code` found inside the
  box or a tarball under `~/.local/opt`, `~/opt` or `~/Applications`; it does not add Microsoft's
  repo, and a Flatpak cannot be used from the box. `--ide-custom NAME COMMAND [ICON]` covers any other
  executable under your home. Pick from a checklist (`ujust dev-toolbox --ide`) or name them (`--ide
  pycharm datagrip`); `--ide --list` shows detection and state; `--ide --remove` deletes only the
  launchers the state file lists. It never overwrites a file it did not create (JetBrains Toolbox's own
  entries are untouched). Downloads made inside the IDE (JDKs, plugins) land in the shared home, and a
  recreated box needs no new launchers. The `StartupWMClass` values (`jetbrains-pycharm`,
  `jetbrains-idea`, `Code`, ...) are from memory and not verified.

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
