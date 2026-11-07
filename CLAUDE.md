# CLAUDE.md

Project guidance for Claude Code. This file is the project's memory: keep durable rules and
decisions here, not in the global `~/.claude` memory. It is public if committed, so never put
secrets, hostnames or personal data in it.

## What this is

A personal, publicly shared bootc image (`ghcr.io/redcodeworks/octarine-os`) built on
`ghcr.io/ublue-os/silverblue-main:45`. It exists to make one desktop reproducible. See `README.md`
for the user-facing description and `CONFIG-GUIDE.md` for the wider desktop setup.

## Layout

- `Containerfile`: base image plus the single build step.
- `build_files/build.sh`: guard against secrets in `system_files`, copy `system_files`, generate the
  container signature policy from `IMAGE_ORG`/`IMAGE_NAME`/`cosign.pub`, install packages, enable services.
- `system_files/`: files copied onto `/` (PAM, sysctl, firewalld, sudoers, Flatpak preinstall lists, `ujust` recipes).
- `Justfile` (repo root, not in the image): build, VM and release recipes. `just check` runs `just --fmt --check`.
- `.github/workflows/`: `build.yml` (build, smoke test, push, then a separate `sign` job in the `signing`
  environment), `require-testing-branch.yml`, `prune-testing.yml`, `build-disk.yml`.
- `githooks/pre-push`: gitleaks scan; enable with `just install-hooks`.

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
