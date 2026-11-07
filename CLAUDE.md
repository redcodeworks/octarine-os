# CLAUDE.md

Project guidance for Claude Code. This file is the project's memory: keep durable rules and
decisions here, not in the global `~/.claude` memory. It is public if committed, so never put
secrets, hostnames or personal data in it.

## What this is

A personal, publicly shared bootc image (`ghcr.io/redcodeworks/octarine-os`) built on
`ghcr.io/ublue-os/silverblue-main:45`, plus a sibling `octarine-os-stable` built every second week from
the same files on `silverblue-main:$STABLE_BASE_TAG` (`latest` in `image-template.env`; ublue has no
`stable` tag; the `BASE_TAG` build arg is the only difference). It exists to make one desktop reproducible. See `README.md`
for the user-facing description and `CONFIG-GUIDE.md` for the wider desktop setup.

## Layout

- `Containerfile`: base image (`ARG BASE_TAG`, default 45) and the single build step.
- `build_files/build.sh`: guard against secrets in `system_files`, copy `system_files`, run
  `signature-policy.sh` (policy scopes for every name in `IMAGE_NAMES`, from `IMAGE_ORG`/`cosign.pub`),
  install packages, enable services. Prints the base and resulting os-release; package names are
  release-specific (the stable base may be a different Fedora than 45).
- `system_files/`: files copied onto `/` (PAM, sysctl, firewalld, sudoers, Flatpak preinstall lists, `ujust` recipes).
- `Justfile` (repo root, not in the image): build, VM and release recipes. `just check` runs `just --fmt --check`.
- `.github/workflows/`: `build.yml` (plans the images, calls `build-image.yml` per image, and keeps the
  required `Build and push image` check as an aggregate job), `build-image.yml` (reusable: build, smoke
  test, push, then a separate `sign` job in the `signing` environment), `require-testing-branch.yml`,
  `prune-testing.yml` (both images), `build-disk.yml` (octarine-os only).
- `.github/scripts/plan-builds.sh`: which images a run builds; the stable image only on even ISO weeks
  for its weekly cron. Tests in `tests/plan-builds.sh`; keep the cron strings in sync with `build.yml`.
- `githooks/pre-push`: gitleaks scan; enable with `just install-hooks`.

## Branches and releases

`testing` builds the `testing` image of both names; `main` is protected, changes only by pull request from
`testing` (merge commit), and publishes `latest` and `stable`. `just release` opens or merges that pull request.
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
- `tests/plan-builds.sh` (cadence and matrix) and `tests/signature-policy.sh` (policy covers both image
  paths) run offline; run them after changing the schedule, `image-template.env` or the policy script.
- `tests/dev-toolbox.sh` tests the `dev-toolbox` and `brew` recipes with fake curl, distrobox and podman (no
  network, temp HOME); run it after any change to those recipes or to
  `system_files/usr/share/ublue-os/distrobox/fedora-toolbox.ini`.
- The image carries no compilers or build tools; they live in the toolbox the definition describes.
