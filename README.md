# octarine-os

A personal [bootc](https://github.com/bootc-dev/bootc) image: Fedora Silverblue on top of Universal Blue's
`silverblue-main`, with the niri compositor and Noctalia shell, libvirt, Cockpit, backup tools and a set of
hardening and tuning defaults. It is built daily and signed with [cosign](https://github.com/sigstore/cosign).
It makes one desktop reproducible and is shared in case parts of it are useful to you. It is one person's
configuration with no promises: read what it changes (below) before you run it. The wider desktop setup is in
[`CONFIG-GUIDE.md`](CONFIG-GUIDE.md).

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

## Recipes

`ujust --list` shows them all.

| Recipe | What it does |
|---|---|
| `ujust add-user-groups` | Add a user to the `gamemode`, `input` and `libvirt` groups |
| `ujust toolbox [<name> [options]]` | List the toolboxes, or create and manage one (`ujust toolbox dev-toolbox`, `ujust toolbox gaming`); `ujust toolbox <name> --help` shows the options |
| `ujust brew` | Install Homebrew on the host (its prefix belongs to your user, so it is not in the image) |
| `ujust gnome-themes <recipe>` | Run a recipe of [gnome-themes](https://github.com/redcodeworks/gnome-themes): themes and icons live there, not in the image |
| `ujust flatpak-games-access` | Give the Flatpak game launchers access to a games directory |
| `ujust steam-flatpak-devices` | Let Flatpak Steam see USB and input devices |
| `ujust steam-gamescope-setup` / `-reset` | Make Flatpak Steam and the gamescope layer work together, or undo it |
| `ujust extest-build`, `extest-steam-setup`, `extest-steam-reset` | Experimental: extest for Steam Input on Wayland |
| `ujust vscode-flatpak-podman` | Let Flatpak VS Code use Wayland and the rootless Podman socket |
| `ujust podman-desktop-deny-docker-socket` | Keep Podman Desktop away from a Docker socket |
| `ujust chrome-flatpak-webapps` | Let Flatpak Chrome install web apps as launchers |
| `ujust gearlever-applications` | Let Gear Lever manage AppImages in `~/Applications` |

## Personal choices worth reviewing

These ship to everyone who uses the image as-is:

- **PAM:** `pam_u2f sufficient` for sudo and polkit. With a security key enrolled, a touch alone gives root;
  without a key the password still works. That is weaker than stock Fedora.
- **Firewall:** the default zone allows named services for Sunshine, MoonDeckBuddy, Steam streaming,
  GSConnect and Tailscale's UDP port.
- **sysctl:** `vm.overcommit_memory=1`, `kptr_restrict`, `ptrace_scope`, a very high `vm.max_map_count`, SysRq enabled.
- **Kernel argument:** `iommu=pt`.
- **Size:** ROCm makes the image big (roughly 11 GB on disk). It carries no compilers; those live in the toolbox.
- **Services:** only `pmcd`, `pmlogger` and `flatpak-preinstall` are enabled; `sshd`, `tailscaled`,
  `cockpit.socket` and the snapper timers are installed and left off.
- **Flatpaks:** a preinstall list of apps. Themes and icons are not in the image.

## Contributing

This is a personal image; see `AGENTS.md`. `main` is protected: work happens on `testing`, a pull request
promotes it, and CI is the test. Maintainer notes (design, CI, forking) are in `CLAUDE.md`.

## License

Apache-2.0, inherited from the [Universal Blue image template](https://github.com/ublue-os/image-template).
See `LICENSE`.

## Credits

The experimental `ujust extest-build` recipe builds [extest](https://github.com/Supreeeme/extest) by Supreeeme
and contributors (MIT licence) from a pinned upstream commit; this repo ships none of its source.
