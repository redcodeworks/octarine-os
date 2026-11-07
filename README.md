# octarine-os

A personal [bootc](https://github.com/bootc-dev/bootc) image built on Universal Blue's
`silverblue-main` (Fedora Silverblue plus codecs and a few conveniences). It adds the niri
compositor with the Noctalia shell, libvirt, Cockpit, backup tools and a set
of hardening and tuning defaults, and it is meant to make one desktop reproducible. It is shared
publicly in case parts of it are useful to you.

It started from the [Universal Blue image template](https://github.com/ublue-os/image-template),
and that project's documentation is still the best reference for how the build pipeline works.
For the wider desktop setup behind it, see [`CONFIG-GUIDE.md`](CONFIG-GUIDE.md).

This is one person's configuration, with no promises. Read what it changes before you run it.

## Use it

```
sudo bootc switch ghcr.io/redcodeworks/octarine-os:latest
```

Reboot, then run `ujust add-user-groups` to join the `gamemode`, `input` and `libvirt` groups.
Images are signed with [cosign](https://github.com/sigstore/cosign). To check one yourself:

```
cosign verify --key cosign.pub ghcr.io/redcodeworks/octarine-os:latest
```

The image also installs a container signature policy for its own registry path, so `bootc upgrade`
rejects an unsigned or wrongly signed image.

## What is in the repo

| Path | Purpose |
|---|---|
| `Containerfile` | The base image and the single build step |
| `build_files/build.sh` | Package installs, service enablement and the signature policy |
| `system_files/` | Files copied onto `/` (PAM, sysctl, firewalld, Flatpak preinstall list, `ujust` recipes) |
| `image-template.env` | Image name, owner, description and default tag |
| `disk_config/` | Installer settings for ISO and disk images |
| `.github/workflows/` | `build.yml` builds, tests, pushes and signs; `build-disk.yml` makes ISO and disk images |

## Branches and releases

Two branches, two images:

| Branch | Image tags | How it changes |
|---|---|---|
| `testing` | `testing`, `testing-<date>-<sha>`, `testing-<sha>`, `testing-<date>` | Push to it directly |
| `main` | `latest`, `latest-<date>-<sha>`, `latest-<sha>`, `latest-<date>`, `<date>`, `<date>-<sha>` | Only by pull request from `testing` |

`main` is protected. To release, open a pull request from `testing` into `main`. It can merge only
when the `Build and push image` check passed on the tip of `testing` and the `require-testing-branch`
check passes (it rejects any other source branch). The merge builds and publishes `latest`. A daily
scheduled build on `main` refreshes `latest` too. Merge with a merge commit, not a squash or rebase,
so `testing` stays in line with `main`. Dependabot proposes changes to `testing`.

Every build runs a smoke test before anything is pushed, signs every tag it pushes, and verifies each
tag against `cosign.pub`. To try an unreleased build, `sudo bootc switch ghcr.io/redcodeworks/octarine-os:testing`.
To pin or roll back, use a dated or per-commit tag, for example
`sudo bootc switch ghcr.io/redcodeworks/octarine-os:latest-<date>-<sha>`, or `sudo bootc rollback` to boot
the previous deployment.

### Pruning old testing images

GHCR has no retention policy, so `prune-testing.yml` runs weekly (from `main`) and deletes `testing`
builds beyond the newest 10, together with their cosign signatures and any untagged versions older
than a week. It never touches a version carrying a `latest*` tag. Scheduled runs only delete after
you set the repository variable `PRUNE_ENABLED` to `true`; until then they are dry runs. To see
the plan first, run the workflow from the Actions tab with `dry_run` on.

## Recipes

The image ships `ujust` recipes in `system_files/usr/share/ublue-os/just/60-custom.just`, covering
group membership, Flatpak overrides (themes, game directories, controllers, VS Code with Podman)
and Flatpak Steam with gamescope and extest. Run `ujust --list` to see them, and
[`CONFIG-GUIDE.md`](CONFIG-GUIDE.md) for what each one does.

## Build it yourself

You need `podman` and [`just`](https://github.com/casey/just). Disk and ISO images also need root.

```
just build                 # build the container image
just build-qcow2           # build a VM disk image
just run-vm-qcow2          # boot it
just build-iso             # build an installer ISO
just --list                # everything else
```

`cosign.pub` has to exist in the repo root, because the build copies it into the image.

## Fork it

1. Edit `image-template.env`: `IMAGE_NAME`, `REPO_ORGANIZATION`, `IMAGE_DESC`.
2. Create your own signing key and store the private half as a secret in a protected environment
   named `signing`, limited to `main` and `testing`, so no other branch's workflow can read it. Commit
   the public half as `cosign.pub`, replacing mine:
   ```
   COSIGN_PASSWORD="" cosign generate-key-pair
   gh api -X PUT repos/<owner>/<repo>/environments/signing --input - <<< '{"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}'
   gh api -X POST repos/<owner>/<repo>/environments/signing/deployment-branch-policies -f name=main -f type=branch
   gh api -X POST repos/<owner>/<repo>/environments/signing/deployment-branch-policies -f name=testing -f type=branch
   gh secret set SIGNING_SECRET --env signing < cosign.key
   ```
   Never commit `cosign.key`. It is in `.gitignore`.
3. Point `disk_config/iso.toml` at your image (`ghcr.io/<owner>/<image>:latest`).
4. Review `build_files/build.sh` and `system_files/` and remove what you don't want (below).
5. Enable GitHub Actions, run the build, and make the GHCR package public.

The signature policy, its registry entry and the key path are generated at build time from
`REPO_ORGANIZATION`, `IMAGE_NAME` and `cosign.pub`, so nothing else needs renaming for signing.

## Personal choices worth reviewing

These ship to everyone who uses the image as-is:

- **PAM:** `pam_u2f sufficient` for sudo and polkit. Once a security key is enrolled, a touch alone
  gives root, and without a key the password still works. That is weaker than stock Fedora.
- **Firewall:** the default zone allows named services for Sunshine, MoonDeckBuddy, Steam streaming,
  GSConnect and Tailscale's UDP port.
- **sysctl:** `vm.overcommit_memory=1` (for Valkey), `kptr_restrict`, `ptrace_scope`, a very high
  `vm.max_map_count`, and SysRq enabled.
- **Kernel argument:** `iommu=pt`.
- **Packages:** ROCm and the development-tools group make the image
  big (roughly 11 GB on disk).
- **Services:** only `pmcd`, `pmlogger` and `flatpak-preinstall` are enabled. `sshd`, `tailscaled`,
  `cockpit.socket` and the snapper timers are installed and left off.
- **Flatpaks:** a preinstall list of apps. Themes and icons are not in the image: `ujust gnome-themes <recipe>` fetches them from their own repos.

## License

Apache-2.0, inherited from the template. See `LICENSE`.
