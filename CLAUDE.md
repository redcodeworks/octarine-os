# CLAUDE.md

Project guidance for Claude Code. This file is the project's memory: keep durable rules and
decisions here, not in the global `~/.claude` memory. It is public if committed, so never put
secrets, hostnames or personal data in it.

## What this is

A personal, publicly shared bootc image (`ghcr.io/redcodeworks/octarine-os`) built on
`${BASE_IMAGE}:${FEDORA_VERSION}` (now `ghcr.io/ublue-os/silverblue-main:45`; see the Containerfile bullet). It exists to make one desktop reproducible. See `README.md`
for the user-facing description and `CONFIG-GUIDE.md` for the wider desktop setup.

## Layout

- `Containerfile`: base image plus the single build step. The base is `FROM ${BASE_IMAGE}:${FEDORA_VERSION}`; the
  ARGs sit before the first FROM (ARGs after a FROM belong to that stage). Where the base is set: the workflow
  `env:` block in `build.yml` (`BASE_IMAGE: ${{ vars.BASE_IMAGE || ... }}`, `FEDORA_VERSION` likewise), where a
  repository variable of the same name overrides the default; the Containerfile ARG defaults repeat it for a bare
  `podman build` (keep both in sync). CI and `just build` pass them as `--build-arg` (an exported
  `FEDORA_VERSION=46 just build` works locally). Because a variable is not versioned with the commit, the build logs
  the resolved base and digest and sets the labels `org.opencontainers.image.base.name`/`base.digest`.
  Fedora major upgrade: set the variable (the owner runs `gh variable set FEDORA_VERSION --body 46`; undo
  `gh variable delete`), run the build workflow on `testing` (changing a variable starts no build), `bootc switch`
  to the `testing` image, soak about a week, keep a deployment pinned, then merge; promotion only retags a tested digest.
- `build_files/build.sh`: guard against secrets in `system_files`, copy `system_files`, generate the
  container signature policy from `IMAGE_ORG`/`IMAGE_NAME`/`cosign.pub`, install packages, enable services.
- `system_files/`: files copied onto `/` (PAM, sysctl, firewalld, sudoers, Flatpak preinstall lists, `ujust` recipes).
- `Justfile` (repo root, not in the image): build, VM and release recipes. `just check` runs `just --fmt --check`.
- `.github/workflows/`: `build.yml` (plan, build, smoke test, push, then a separate `sign` job in the `signing`
  environment), `require-testing-branch.yml`, `prune-testing.yml`, `build-disk.yml` (details under "CI and
  signing flow").
- `githooks/pre-push`: gitleaks scan; enable with `just install-hooks`.

## Homebrew (files image)

- The Containerfile has a stage `brew` from `ghcr.io/ublue-os/brew` (Universal Blue, `FROM scratch`,
  holds `/system_files`: `/usr/share/homebrew.tar.zst` built upstream by running Homebrew's `install.sh`, the
  `brew-setup`/`brew-update`/`brew-upgrade` units, `/etc/profile.d/brew.sh` which appends brew to the END of
  `PATH`, a fish snippet and a nofile limit). `COPY --from=brew /system_files /` runs before `build.sh`, which
  copies `system_files/` over it and runs `systemctl preset brew-setup.service brew-update.timer
  brew-upgrade.timer`.
- Pinned to a dated tag: `ARG BREW_TAG=20261108` in the Containerfile (upstream builds weekly; the tag is
  `YYYYMMDD`). Bump by changing that one value; `just brew-tags` lists the newest tags (needs skopeo). A dated
  tag can in principle be re-pushed, so the build job (before the base pull) resolves it to a digest, verifies
  that digest with cosign against `keys/ublue-os-brew-cosign.pub` (vendored, see `keys/README.md`), logs it
  ("Brew image ... resolved to ...") and passes `ref@digest` as `BREW_IMAGE` to `just build`, so verify and use
  cannot diverge; the logged digest is the record of what a build used.
- Presets: `system_files/usr/lib/systemd/system-preset/00-octarine-brew.preset` disables `brew-upgrade.timer`
  (upgrades are manual and stay under the owner's soak policy; opt in per machine with `sudo systemctl enable --now brew-upgrade.timer`, undone with `disable --now`). systemd takes the first matching line in file-name order, so
  the `00-` name beats upstream's `01-homebrew.preset`, which enables it. Enabled: `brew-setup.service`
  (first boot, root, oneshot; skipped when `/etc/.linuxbrew` or `/home/linuxbrew/.linuxbrew` exists; chown to
  UID 1000, hard-coded) and `brew-update.timer` (every 6 h, runs as UID 1000). The smoke test checks these
  states and the files.
- Formulae are not pinned by the image; `brew bundle` from a Brewfile (kept outside this repo) is their
  reproducibility. The first-boot path cannot be tested in CI (the smoke test only checks units and files).
- There is no `ujust brew` any more (removed 2026-11-08). Repair for a missing prefix is manual and unverified:
  `sudo mkdir -p /var/home/linuxbrew/.linuxbrew`, chown it to the user, and run
  `sudo systemctl start brew-setup.service` only if `/etc/.linuxbrew` is absent (the unit also skips while the
  prefix exists).
- Undo: remove the `brew` stage, the `COPY --from=brew` line, the `systemctl preset` line, the preset file,
  the CI steps and the smoke assertions; existing prefixes stay untouched.

## Branches and releases

`testing` builds the `testing` image; `main` is protected, changes only by pull request from `testing`
(merge commit), and publishes `latest`. `just release` opens or merges that pull request.
The `testing` VM (`just test-vm`) follows the `testing` tag, and updating it is the normal way to test.

## Rules

- Home- or user-level configuration (themes, icons, dotfiles) never goes in the image. It lives in its own
  repo and is pulled in by a `ujust` recipe, such as `ujust gnome-themes <recipe>`. System-level files
  (PAM, sysctl, firewalld, `/etc` defaults) are fine in `system_files/`.
- Podman only; no Docker daemon.
- `sshd`, `tailscaled`, `cockpit.socket`, the snapper timers and `mcelog` stay off by default.
  Leave `rpm-ostreed-automatic.timer` alone.
- Never put security key registrations (`u2f_keys`), private keys or `.env` files in `system_files/`;
  the build guard and gitleaks hook both reject them.
- `just` takes positional arguments only. Recipe text changes must pass `just --fmt --check`.
- Commit and push only when asked. Never push `main` directly or touch the signing key.
- The `AGENTS.md` file is a notice for outside agents; it does not apply to the owner's own sessions.

## Scope and delegation

- This repo is its own Claude project. Work only inside it; never edit anything outside it (other
  repos, home-directory configs, live system settings).
- Anything that needs the outside (a change in another repo, applying something on a running machine,
  `rpm-ostree` or `sudo` checks) is not done from here. Report it as a request under `Needs from hub:`
  to whoever spawned the session, who handles it or delegates it.
- Other sessions work on this repo through a project agent spawned by that hub, not by editing files directly.
- Branch and CI rules above and below stay as written.

## Verifying changes

- The CI smoke test (`build.yml`) is the check for package, service and lockout expectations; add new
  packages and units to it.
- Package names cannot be checked from the sandbox (no mirror access); the first CI build confirms them.
- Shell blocks in workflows and recipes: check with `bash -n`.
- `tests/plan-build.sh` tests the docs-only plan script with fixed inputs; run it after changing
  `.github/scripts/plan-build.sh`.
- `tests/image-version.sh` tests the version string and its channel-neutral check.
- `tests/aggregate-result.sh` tests the aggregate decision with fixed job results.
- `tests/plan-promote.sh` and `tests/prune-testing.sh` test the promote decision and the prune safety net.
- `tests/user-setup.sh` tests `ujust user-setup` with fake flatpak, sudo, id, getent and usermod; run it after changing that recipe.
- `tests/toolbox.sh` tests the `toolbox <name>` recipe with fake curl, distrobox and podman (no
  network, temp HOME); run it after any change to those recipes or to
  `system_files/usr/share/ublue-os/distrobox/` (`<name>.ini`, `<name>.conf`).
- The image carries no compilers or build tools; they live in the toolbox the definition describes, which
  is the image `ghcr.io/redcodeworks/fedora-toolbox` built from its own repo (`TOOLBOX_IMAGE` overrides the tag). The host recipe is `ujust toolbox <name>`; to add a toolbox ship a
  definition `<name>.ini` (section `[<name>]`), an optional `<name>.conf` (TOOLS, EXPORT_BINS, IDES as plain data) and
  an image from the fedora-toolbox repo.

## CI and signing flow

- **Tags.** `testing` pushes publish `testing`, `testing-<date>-<sha>`, `testing-<sha>`, `testing-<date>`.
  `main` publishes (build, or promote of the tested `testing` digest) `latest`, `latest-<date>-<sha>`, `latest-<sha>`, `latest-<date>`, `<date>`, `<date>-<sha>`
  (`just generate-build-tags`). A daily schedule on `main` (10:05 UTC) refreshes `latest`. Pull requests
  into `testing` build without publishing. Dependabot proposes changes to `testing`.
- **Promotion.** `main` merges only when `Build and push image` passed on the tip of `testing` and
  `require-testing-branch` passes (it rejects any other source branch). Use a merge commit so `testing`
  stays in line with `main`. Pin or roll back by switching to a dated tag; `bootc rollback` boots the previous
  deployment.
- **Build job.** Choose channel, `just check`, a base-pull step (pulls the base named by
  the workflow env, where repository variables override, logs its digest and fails naming the tag if it does not exist), `just build`, an image-size guard
  (15 GiB), the smoke test, `just ostree-rechunk`, tags, push. The smoke test runs the image and checks
  units, packages, PAM fallbacks, the signature policy, os-release (`ID=fedora`, and `VERSION_ID` against
  a numeric base tag), sudoers, firewalld, the toolbox definition `dev-toolbox.ini`/`dev-toolbox.conf` and the preinstall
  list. Add new packages and units to it.
- **Package tiers.** `build.sh` has a CRITICAL `dnf5 install` (one transaction; a missing name fails the build) and
  OPTIONAL groups (own transaction each, per-package retry, failures written to
  `/usr/share/octarine-os/optional-packages-missing`, warning annotations and a step summary from the build job).
  Policy: packages from outside Fedora's repositories (negativo17, RPM Fusion, COPR, vendors) are optional only;
  the smoke test requires vendor `Fedora Project` for every critical package. `fish` is optional: nothing in the image depends on it and it is never a login shell (the image ships no terminal configuration). New users default to zsh (`/etc/default/useradd` patched in `build.sh`,
  `system_files/etc/skel/.zshrc`; distrobox copies the host login shell). Add a package to the right tier and to the
  smoke test's critical or informational list.
- **Cancelling.** `build.yml` concurrency cancels the older run for any ref but `main` and any scheduled run. A cancelled run
  never turns `Build and push image` green; it can leave the `testing` tag unsigned until the next build.
- **Labels.** `just build` sets the OCI labels (source `https://github.com/<owner>/<image>`, licenses,
  title, description, created, version, artifacthub keys). `rpm-ostree compose build-chunked-oci` starts
  from the rootfs, so `ostree-rechunk` re-passes every label except `containers.bootc` and `ostree.*`
  with `--label`; without that the pushed image lost them.
- **Version.** Every build, testing or main, stamps `org.opencontainers.image.version` (what `bootc status`
  shows as the version) with `<YYYYMMDD>-<short sha>` from `.github/scripts/image-version.sh`, never a channel
  (tests: `tests/image-version.sh`). A promoted image keeps the version it was built with, which is why it must
  be channel-neutral: the retag cannot change it. After the rechunk the build checks, with
  `check-version-neutral.sh`, that the version label (and any other `*version*` label) is present and contains
  neither `testing` nor `latest`. Image tags are unchanged.
- **Signing.** A separate `sign` job in the `signing` environment (limited to `main` and `testing`) signs
  every distinct pushed digest with cosign (old bundle format, `--use-signing-config=false`) and verifies
  each tag against `cosign.pub`. Pull request builds never reach it. `build.sh` generates the container
  signature policy (a `sigstoreSigned` scope for `ghcr.io/<org>/<image>`, a `registries.d` entry, the key under
  `/etc/pki/containers`) from `IMAGE_ORG`, `IMAGE_NAME` and `cosign.pub`, keeping the catch-all last.
  `just build` passes `IMAGE_NAME=${target_image##*/}` so a `localhost/` prefix does not leak into it.
- **Pruning.** `prune-testing.yml` runs weekly from `main`: it keeps the newest 10 `testing` builds, deletes
  older ones with their cosign signature versions and untagged versions older than a week, never a `latest*`
  or dated tag. Scheduled runs only delete once the repository variable `PRUNE_ENABLED` is `true`; run it by
  hand with `dry_run` on to see the plan.
- **Docs-only skip.** A `plan` job always runs `.github/scripts/plan-build.sh` (tested by
  `tests/plan-build.sh`). When every file changed in the range (push: `github.event.before` to the sha; pull
  request: base to head) is docs-only, it sets `build=false`: top-level `*.md`, `docs/**`, `LICENSE`, `.gitignore`
  (the list is `is_docs` in `.github/scripts/docs-only.sh`, one place, sourced by the plan scripts). The heavy `build_push` job (named `Build image`) and
  `sign` are then skipped, and the aggregate `build_result` job, named exactly `Build and push image`, passes.
  An unknown or all-zero before-SHA, the schedule, `workflow_dispatch` and any other changed file always build.
  Required checks are `Build and push image`, `require-testing-branch` and `Sign and verify images`; do not
  rename them (a skipped `sign` job counts as passing).
- **Promotion (build once, promote).** A merge into `main` retags the already tested and signed `testing`
  image as `latest` instead of rebuilding. Off unless the repository variable `PROMOTE_ENABLED` is `true`
  (the owner sets it; the workflow never does). `plan-promote.sh` (tests: `tests/plan-promote.sh`, with a fake
  registry lookup) promotes only when the push is to `main`, the commit is a merge (two parents), every file
  differing between `HEAD^2` (the testing tip) and `HEAD` is docs-only, and walking first-parent history back
  from `HEAD^2` reaches a commit C with a published `testing-<short sha>` tag without crossing a non-docs
  change (so a docs-only testing tip, which has no image of its own, promotes the image of the commit behind
  it). The plan job then verifies the digest against `cosign.pub`; if that fails it falls back to the normal
  build and sign. The `promote` job copies the manifest with `skopeo copy --all --preserve-digests` (skopeo is
  preinstalled on the runners) to every tag `just generate-build-tags` emits for `latest` (`latest`,
  `latest-<date>`, `latest-<sha>`, `latest-<date>-<sha>`, `<date>`, `<date>-<sha>`, with the merge commit's
  sha) and compares the digest (`registry-digest.sh`, raw manifest bytes) before and after each copy. The
  `sign` job only verifies on this path: the digest before and each new tag after. Retagging the manifest is
  enough for the bootc image: the rechunked layers, the config (labels, ostree commit label) and the
  signature (which belongs to the digest) all stay as they were; the only difference from a rebuild is that
  the content, `created` label and base-image snapshot are those of the testing build, and the daily schedule
  still rebuilds `latest` from the current base. Always build: schedule, `workflow_dispatch`, non-merge pushes
  to `main`, differing trees, no matching image, failed verification, `PROMOTE_ENABLED` not `true`. The
  aggregate `Build and push image` counts a successful promote as the build.
  The job graph is linear: `plan` -> `build_push` or `promote` (exclusive) -> `sign` -> `build_result`, so the
  aggregate means built, signed and published. `aggregate-result.sh` (tested by `tests/aggregate-result.sh`)
  accepts a skipped `sign` only when nothing was published and fails when sign was expected and did not succeed. Pruning stays safe: a version
  carrying `latest*` next to `testing*` tags is never a candidate (`tests/prune-testing.sh`).
- **Disk images.** `build-disk.yml` runs only on `workflow_dispatch` (Run workflow in the Actions tab, or
  `just build-iso` / `just build-qcow2` locally); no trigger, no required check depends on it. It passes
  `rootfs: btrfs` to the builder action (the failure was `no default root filesystem type specified in
  container`). Config paths are passed as `./disk_config/...` because podman reads a bare path as a volume name.

## Base image and Fedora major upgrade

- The base is `${BASE_IMAGE}:${FEDORA_VERSION}`, default `ghcr.io/ublue-os/silverblue-main:45`. The defaults are in the
  workflow `env:` block (`.github/workflows/build.yml`) and repeated as `ARG` defaults in the `Containerfile` (keep
  them in sync); the repository variables `BASE_IMAGE` and `FEDORA_VERSION` override the workflow defaults. CI and
  `just build` pass both as build args; for a local experiment `FEDORA_VERSION=46 just build` works.
- Upgrade steps: (1) set the variable, `gh variable set FEDORA_VERSION --body 46 -R <owner>/<image>` (undo:
  `gh variable delete FEDORA_VERSION`), or edit the workflow default and the `Containerfile` ARG in a commit.
  (2) Changing a variable starts no build: run the `Build container image` workflow on `testing` (a push or manual
  dispatch). The "Check the base image can be pulled" step fails early and names the tag if it does not exist
  (`skopeo list-tags docker://ghcr.io/ublue-os/silverblue-main` lists them); the smoke test checks that `VERSION_ID`
  matches; the log and the labels `org.opencontainers.image.base.name`/`base.digest` record the resolved base.
  (3) Test the `testing` build with `sudo bootc switch --enforce-container-sigpolicy ghcr.io/<owner>/<image>:testing` (or the testing VM).
  (4) Soak about a week and keep the current deployment pinned as the rollback (`sudo ostree admin pin <index>`),
  then merge the pull request. Promotion only retags an already tested `testing` digest, so a variable changed
  without a tested `testing` build never reaches `latest` by promotion; the daily scheduled `main` build does read the
  variable, so set it only when the next scheduled build should use it.

## Logo files

- PNGs in `system_files/usr/share/octarine-os/logo/`: `octarine-logo.png` (465x72, the dark variant; GDM login screen
  and Plymouth watermark) and `octarine-logo-{neutral,dark,light}-{512,full}.png` (3306x512 and 7000x1084). The README
  shows the 512 files in a `<picture>` block. No mono variant.
- The three `-full` files are the sources for every smaller size: resize with Lanczos and keep the alpha channel. The
  uncompressed originals (about 36 MB each) are not stored in the repo or the image.
- Variants: `dark` has cream-grey "OS" letters for dark backgrounds (the one used on the login and boot screens),
  `light` dark-brown "OS" letters for light backgrounds, `neutral` grey "OS" letters that work on any background.
- Origin: a recoloured version of the Fedora Silverblue logo, wordmark set in JetBrains Mono (credits in the README); no font file is shipped, only rendered text in the PNGs.

## Defaults that deviate from stock Fedora

Shipped to everyone who uses the image as-is (moved here from the README's former "Personal choices" section):

- **PAM:** `pam_u2f sufficient` for sudo and polkit: a security-key touch is accepted instead of the password; the
  password still works when no key is registered; no PIN is required. Details in `CONFIG-GUIDE.md`.
- **Firewall:** the default zone allows named services for Sunshine, MoonDeckBuddy, Steam streaming, GSConnect and
  Tailscale's UDP port (`CONFIG-GUIDE.md` has the zone notes).
- **sysctl:** `vm.overcommit_memory=1`, `kptr_restrict`, `ptrace_scope`, a very high `vm.max_map_count`, SysRq enabled.
- **Kernel argument:** `iommu=pt`.
- **Size:** ROCm makes the image big (roughly 11 GB on disk). It carries no compilers; those live in the toolbox.
- **Services:** only `pmcd`, `pmlogger` and `flatpak-preinstall` are enabled; `sshd`, `tailscaled`, `cockpit.socket`
  and the snapper timers are installed and left off.
- **Homebrew:** see the Homebrew section above; formulae are not pinned (use `brew bundle`).
- **Login shell for new users:** `zsh` (`SHELL=/usr/bin/zsh` in `/etc/default/useradd`, plus `/etc/skel/.zshrc`).
  Existing accounts and root keep their shell. Rolling back to an image without zsh breaks only accounts created while
  zsh was the default; distrobox copies the host login shell, so every toolbox image a zsh user enters needs zsh
  (`dev-toolbox` has it; check the `gaming` one).
- **Flatpaks:** a preinstall list of apps; themes and icons are not in the image.

## Forking

Edit `image-template.env` (`IMAGE_NAME`, `REPO_ORGANIZATION`, `IMAGE_DESC`), generate a key
(`COSIGN_PASSWORD="" cosign generate-key-pair`), commit `cosign.pub`, create a protected environment
`signing` limited to `main` and `testing` (deployment branch policies through the API) and store the private key
as the `SIGNING_SECRET` environment secret. Never commit `cosign.key`. Point `disk_config/iso.toml` at the
image, review `build.sh` and `system_files/`, enable Actions and make the GHCR package public.

## build.sh notes

- Packages come from the base's repos (distrobox, ffmpeg and pam-u2f already ship in `silverblue-main`; its
  multimedia stack is negativo17, so `gstreamer1-plugins-bad/-ugly` replace the `-free` variants and there is no
  `mesa-va-drivers-freeworld`). Package names are release-specific; `dnf5 install` stops on an unknown name.
- No compilers or build tools in the image: builds happen in a toolbox. Nothing compiles from source.
- Only `PRETTY_NAME` changes in os-release (ID, NAME, VERSION_ID stay, as update tooling reads them).
  os-release is printed before and after.
- Firefox and toolbox are removed when present (Flatpak Firefox, distrobox).
- gnome-software is removed (Bazaar, `io.github.kolunmi.Bazaar` in `tools.preinstall`, is the software centre;
  fwupd and PackageKit stay and firmware updates remain available through `fwupdmgr`). `build.sh` previews
  `dnf5 remove --assumeno gnome-software` and fails the build if the transaction lists a package of
  `PROTECTED_PKGS` (gnome-shell, nautilus, fwupd, flatpak and a few more; the one place for that list).
  The smoke test checks `! rpm -q gnome-software` and that fwupd, flatpak and gnome-shell remain.
  Bazaar's manifest reads host config from `/run/host/etc/bazaar/` (none shipped).

## The toolbox recipe (`ujust toolbox <name>`)

Defined in `system_files/usr/share/ublue-os/just/60-custom.just`; tests in `tests/toolbox.sh`.

- **Scope.** `<name>` selects `/usr/share/ublue-os/distrobox/<name>.ini` (override the directory with
  `TOOLBOX_DEFINITIONS`); the `[<name>]` section is the container name. `image=` points at an image built in the
  `fedora-toolbox` repo (`dev-toolbox`: `ghcr.io/redcodeworks/fedora-toolbox:latest`, weekly, packages baked in);
  `TOOLBOX_IMAGE` overrides the reference of the named toolbox and the recipe prints the image it uses. No name
  lists the definitions with box state (missing, stopped, running), the default marker and the image. An
  unknown name fails with the known ones. `dev` is the old name of `dev-toolbox` (renamed 2026-11): with a `dev` state file it still means the old box, for `--remove` only; otherwise it is an alias.
- **Sidecar `<name>.conf`.** Plain `KEY=value`, parsed as data and never sourced; values may hold only letters,
  digits, space and `. _ + -` (anything else is ignored with a warning). `TOOLS` selects checklist rows from the
  recipe's catalogue (uv, rustup, sdkman, nvm), `EXPORT_BINS` the commands exported with `distrobox-export`,
  `IDES` the launchers `--ide` offers. No sidecar means no tools, exports or launchers. The catalogue and notes
  stay in the recipe's `rows` table.
- **Sidecar keys for isolated toolboxes.** `ISOLATED_HOME=true` gives the container its own HOME: the recipe adds
  `home=<dir>` to the temporary copy of the definition, `<dir>` being `$TOOLBOX_HOMES_DIR/<name>` (default
  `~/.local/share/toolbox-homes/<name>`; a personal location is set in the user's own environment, never in shipped
  files or tests). It creates the directory itself (`mkdir -p`, no sudo), records `home <path> created|existed`,
  prints the path, and refuses to continue when the path is relative, holds odd characters or `..`, exists but is not
  a directory, or is not writable. `EXPORT_APPS="steam"` exports each app's launcher with `distrobox-export --app`
  run in the box (the launcher lands in the host's `~/.local/share/applications/<name>-<app>.desktop` because
  distrobox knows the host home); a file the recipe did not create is never overwritten, each created launcher is
  recorded as `app <path>`, `--list` shows state per app (`exported`, `not exported`, `foreign file`), `--remove`
  deletes only recorded launchers, `--recreate` removes them first and exports again. The exported icon files stay.
  The overview (`ujust toolbox`) adds one line per such toolbox: home path and state, apps and state.
- **`TOOLBOX_VOLUMES`.** Space-separated `src:dst[:opts]` entries add `volume=` lines to the temporary definition of
  any toolbox, applied when the box is created (use `--recreate` after changing it). Each entry needs absolute
  paths, an existing source directory, no `..` and only letters, digits and `/ _ . + - @`; invalid entries are
  skipped and reported.
- **Removing an isolated home.** `--remove` never deletes the home (Steam library, Proton prefixes, saves) and
  prints its path; the state file then keeps just the `home` record. `--remove --purge-home` (also with
  `--dry-run`) lists the home with its size, warns, asks for `yes` and deletes only the directory recorded as
  `created` whose basename is the box name, never a symlink, `/` or the user's home. A home that `existed`
  before the recipe is adopted but never purged (delete it by hand).
- **The `gaming` toolbox.** `gaming.ini` and `gaming.conf` describe `ghcr.io/redcodeworks/fedora-gaming`
  (built in the fedora-toolbox repo: RPM Fusion Steam, gamescope, mangohud, gamemode, protontricks and more; no
  Terra). `init=false`, `nvidia=false`, distrobox's default privileged host-network container (`unshare_netns=true`
  is only a documented fallback for `bwrap ... resolv.conf` errors after suspend), isolated home, `steam` launcher
  exported, no tools, bins or IDEs. It replaces nothing: the host Flatpak Steam stays the primary client, and the
  isolated home guarantees the two never share library folders. Try from a checkout:
  `TOOLBOX_DEFINITIONS=system_files/usr/share/ublue-os/distrobox TOOLBOX_IMAGE=ghcr.io/redcodeworks/fedora-gaming:testing just --justfile system_files/usr/share/ublue-os/just/60-custom.just toolbox gaming`.
- **State per toolbox** in `$XDG_STATE_HOME/ublue-os/toolbox/<name>`: `box`, `export`, `launcher`, `conf` and
  `dir ... created|existed` lines. `--remove` acts only on that file. A shared home directory (`~/.cargo`,
  `~/.rustup`, `~/.sdkman`, `~/.nvm`) is recorded as created by the first toolbox; a toolbox that finds a tool
  already installed records the directory as existed. Removing the creator keeps a directory another state file
  lists and hands ownership over, so the last one removed deletes it.
- **Options** (all on the named toolbox): `--list`, `--recreate`, `--force` (rerun installers), `--remove
  [--dry-run]` (lists with sizes, needs `yes`, never touches `/usr`, `/etc` or files it did not create),
  `--upgrade [--check]` (pull the image, compare image ids, show digests and Fedora versions, warn when the
  major changes, confirm, replace via recreate; no package resolution test, the fedora-toolbox CI covers it),
  `--update` (`distrobox upgrade`), `--set-default`, `--ide [names]`, `--ide-custom NAME COMMAND [ICON]`,
  `--ide --list`, `--ide --remove [--dry-run]`. Options exclusive of each other are rejected with exit 2.
- **Default container.** The recipe asks one line: `Default container for 'distrobox enter' (current: <value or
  none>[, no such container]) [<toolbox name>]: `. Enter sets the toolbox's own name, another valid name
  (letters, digits, `_ - .`; invalid asks again) sets that, `-` leaves it; an equal value says `already set` and
  writes nothing. Only the `container_name_default` line changes. With no answer to read (no terminal) nothing
  changes and the command `ujust toolbox <name> --set-default` is printed. `--set-default` asks the same
  question later. Records (`conf ...`, plus `conf-value <name>` for a typed name) let `--remove` restore the
  old value while the file still holds what the recipe wrote.
- **No sudo, no rc edits.** Installer scripts (SDKMAN, nvm) are https-only, downloaded
  to a file, hashed, shown on request and run only after `y`, with a `sudo` stub first on `PATH` and
  `no_new_privs` through `setpriv` (refused if `setpriv` is missing). Nothing edits shell rc files or runs as root.
- **rustup.** Fedora's `rustup` package ships only `/usr/bin/rustup-init`; `~/.cargo/bin/rustup` and the proxies
  exist only after it has run in the home. The row counts as installed when `~/.cargo/bin/rustup` exists;
  otherwise, after a confirm and under the sudo guard, it runs `rustup-init -y --no-modify-path
  --default-toolchain stable`, then exports the executables in `~/.cargo/bin` (not `rustup-init`).
- **Brew mount.** The definition mounts `/home/linuxbrew` read-only; the source must exist at creation and the
  recipe cannot create it, so while it is missing the `volume=` line is dropped from a temporary copy and
  `box-no-brew-mount` is recorded; `--recreate` once the prefix exists (the image's first-boot `brew-setup.service` creates it) adds it.
- **Exports.** `distrobox-export --bin` into `~/.local/bin` (never overwrites; recorded per toolbox); `sdk` is a
  wrapper script because it is a shell function. Host `node`/`npm` stay brew's, so nvm exports nothing.
- **IDE launchers.** `~/.local/share/applications/<name>-<id>.desktop` with `Exec=distrobox enter -n <name> --
  <launcher> %F`; detection only, never installs; never overwrites a file the recipe did not create. JetBrains
  uses the Toolbox-generated shell scripts (`~/.local/share/JetBrains/Toolbox/scripts`, icon taken from the IDE
  directory the script launches); VS Code uses `code` in the box or a tarball under `~/.local/opt`, `~/opt` or
  `~/Applications`. `StartupWMClass` values are from memory and unverified.
- **Adding a toolbox.** Ship `<name>.ini` (section `[<name>]`) and optionally `<name>.conf` in
  `system_files/usr/share/ublue-os/distrobox/`, with an image from the fedora-toolbox repo; extend `tests/toolbox.sh`.
- **Wrapper scripts.** Exported wrappers need a stdin guard, or they hang tools that talk over stdio.
- **Installer scripts.** SDKMAN and nvm (in the toolbox) are the only installer
  scripts; nothing here needs sudo.
- **Other recipes.** `ujust gnome-themes` runs a recipe of the gnome-themes repo from a fresh checkout in
  `~/.cache/gnome-themes/repo` (`GNOME_THEMES_REF` picks the ref).
  `user-setup [user] [--yes|--no]` replaced the seven single-purpose recipes `add-user-groups`, `flatpak-games-access`,
  `steam-flatpak-devices`, `vscode-flatpak-podman`, `podman-desktop-deny-docker-socket`, `chrome-flatpak-webapps` and
  `gearlever-applications` (removed, no aliases). It is an interactive y/n checklist; the groups step copies the
  `gamemode`, `input` and `libvirt` lines from `/usr/lib/group` into `/etc/group` first and is the only sudo use. Each
  Flatpak step is skipped when the app is missing (`flatpak info`) or the override is present (`flatpak override
  --user --show`); defaults are yes except the Steam devices (widens the sandbox) and the games directory (needs a
  path); `--yes` takes defaults, `--no` prints the plan; a failed step is reported, the rest continue, exit status
  non-zero. Tests: `tests/user-setup.sh` (fake flatpak, sudo, id, getent, usermod). The extest recipes build a pinned upstream commit of extest (github.com/Supreeeme/extest, by Supreeeme and
  contributors, MIT licence; credited in the recipe comment, its output and the README; no source or licence text is
  shipped) and preload the 64-bit build into Flatpak Steam.
  Flatpak recipes only add or remove their own override entries (Flatseal shows the result); recipes are
  idempotent, and each override-changing recipe has a matching reset (`user-setup` prints the undo per applied step).
  Themes land in `~/.themes`, icons in `~/.local/share/icons`; `gnome-themes` needs network, git and just, and
  without a name shows a checklist. The extest recipes need `cargo` and a C linker (the host has none; use the
  toolbox) and are not verified end to end.

## Image hygiene notes

- Labels were missing from the pushed image until `ostree-rechunk` passed them on (see "Labels").
- The base image may carry `/etc/brlapi.key` (brltty's API key, generated at package install and so identical
  in every copy of a public image) and a copy of `/sysroot/ostree/repo/objects`; neither is created by this
  repo's Containerfile or `build.sh`. Findings are with the hub for follow-up.
