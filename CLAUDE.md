# CLAUDE.md

Project guidance for Claude Code. This file is the project's memory: keep durable rules and
decisions here, not in the global `~/.claude` memory. It is public if committed, so never put
secrets, hostnames or personal data in it.

## What this is

A personal, publicly shared bootc image (`ghcr.io/redcodeworks/octarine-os`) built on
`${BASE_IMAGE}:${FEDORA_VERSION}` (now `ghcr.io/ublue-os/silverblue-main:45`; see the Containerfile bullet). It exists to make one desktop reproducible. See `README.md`
for the user-facing description and `CONFIG-GUIDE.md` for the wider desktop setup.

## README policy

The README is user-facing for people who just need the concise what, why and basic how to use it. It is not a place
for notes to yourself and carries no technical implementation details (those go here). Essential sections:
Requirements, Install/Usage, Contributing, License, Credits, and a closing disclaimer ("About this repo": personal
project assisted by Claude, tested only on the owner's setup, not actively maintained beyond the owner's needs, forks
encouraged). American English throughout.

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
- `.github/workflows/`: `test.yml` (quick tests and secret scan on dev branches), `build.yml` (plan, build, smoke test, push, then a separate `sign` job in the `signing`
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
- Pinned by DIGEST: `ARG BREW_TAG` (dated tag, `YYYYMMDD`, upstream builds weekly, kept for humans), `ARG BREW_DIGEST`
  (`sha256:` plus 64 hex) and `ARG BREW_IMAGE=ghcr.io/ublue-os/brew:${BREW_TAG}@${BREW_DIGEST}` in the Containerfile (a
  re-pushed tag cannot change what is built). Bump with `just brew-bump [tag]` (default: the newest dated tag; needs
  skopeo, cosign and python3): it resolves the digest (`skopeo inspect --raw | sha256sum`), runs `cosign verify --key
  keys/ublue-os-brew-cosign.pub ghcr.io/ublue-os/brew@sha256:...` (the key is vendored, see `keys/README.md`) and only then
  writes tag and digest; `just brew-tags` lists the newest tags and the current pin. CI no longer resolves or verifies
  per build: the build job's "Check the brew image pin" step fails unless tag and digest have the right format and logs
  `Brew image pinned: ...` (the record of what a build used); the plan job output `brew_pin_changed` is true when the
  push changed `BREW_TAG`/`BREW_DIGEST` (or there is no usable before-commit: schedule, dispatch, new branch) and then the
  build job runs `cosign verify` on the pinned digest, so a hand-edited digest cannot ship unverified. Test: `tests/brew-bump.sh`.
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

`testing` builds the `testing` image (once per merge, no build on pull requests); `main` is protected, changes only by pull request from `testing`
(merge commit), and publishes `latest`. `just release` opens or merges that pull request.
The `testing` VM (`just test-vm`) follows the `testing` tag, and updating it is the normal way to test.

## Branching: GitLab Flow

GitLab Flow, "production branch" variant (reference implementation for the owner's other repos). `testing` is the
integration branch (GitLab's "main"); `main` is the production branch.

- **Environments.** dev = the `Test` workflow on every push to a dev branch (jobs `test` and `secrets`, about 80
  seconds, no image build); `testing` = the image build and publish of the `testing` tags once per merge (UAT; the
  `octarine-testing` VM follows it); `main` = promotion of the tested build to `latest` (prod, the owner's machine).
- **Direction.** One way, downstream: feature branch -> pull request into `testing` -> pull request from `testing`
  into `main`. Fixes go upstream first (into `testing`, then promoted).
- **Branch names.** `feat/<topic>`, `fix/<topic>`, `hotfix/<topic>`. A push to a feature branch runs the `Test`
  workflow and builds no image; there is no `pull_request` trigger in `build.yml`.
- **Merge methods (enforced by rulesets).** A feature pull request into `testing` is squashed: one commit per feature
  (only squash is allowed there). `testing` into `main` is a merge commit (only merge commits are allowed there).
  Why: promotion must keep `testing`'s commits as ancestors of `main`; a rebase or squash of `testing` into `main`
  would rewrite them and the next promotion would replay commits that are already applied. No back-merge of `main`
  into `testing` is needed: `main` only gains the promotion merge commits that `testing` lacks, which is harmless.
- **Who merges.** Direct pushes to `testing` and `main` are blocked and there is no bypass. Required checks (rulesets): into
  `testing`, `test` and `secrets`; into `main`, `Build and push image`, `require-testing-branch` and
  `Sign and verify images`. Agents may merge their own feature pull request into `testing` once the required checks
  are green (Kevin, 2026-11-09; GitHub does not let an author approve their own pull request, so this means
  merging). Merging into `main` is the owner's only.
- **Promotion.** Pull request `testing` -> `main` (`require-testing-branch.yml` runs on pull requests into `main`
  only, never on those into `testing`); the push to `main` retags the tested `testing` image by tree hash and signs.
- **Hotfix rule.** Fix on a `hotfix/<topic>` branch into `testing`, then promote. If `testing` is red and prod needs
  an emergency fix, open the pull request into `main` and cherry-pick the same fix into `testing` straight away.
- **The image is built once per change, after the merge.** A pull request into `testing` gets no image build (by
  design; `build.yml` has no `pull_request` trigger); the merge into `testing` is the push build that publishes the
  `testing` tags and is the first time the image is built. The trade-off: a broken image is only found by the build
  after the merge into `testing`. A red `testing` build publishes nothing and cannot be promoted, because its
  `Build and push image` check on the tip commit fails (that is the check `main` requires); fix it forward with a new
  dev branch and pull request.
- **Validation build of a dev branch by hand.** `gh workflow run build.yml -R redcodeworks/octarine-os --ref <branch>`
  runs the full plan, build, size check and smoke test on that branch. It never publishes: the "Choose channel" step
  sets `publish=false` for every ref but `main` and `testing`; "Login to GitHub Container Registry" and "Push To
  GHCR" need `publish == 'true'`; the `sign` job runs only after a publish or a promotion, so it skips; no tags are
  pushed; the aggregate job `Build and push image` still passes. Concurrency group is workflow plus ref,
  cancel-in-progress on (only `main` and the schedule are never cancelled). The workflow must exist on that branch.
  Test: `tests/build-triggers.sh`.
- The owner's other repos (gnome-themes, fedora-toolbox, dot-files) still commit straight on `testing`.

## Test workflow

`.github/workflows/test.yml` (name `Test`) is the fast lane for dev branches (the image build takes about ten
minutes). Triggers: `push` with `branches-ignore: [main, testing]` and `workflow_dispatch`; no `pull_request`
(the push check run is reported on the commit, so the pull request shows it and nothing runs twice) and nothing on
`testing` or `main` (those run `build.yml`). One concurrency group per ref, cancel in progress, `contents: read`.
Two jobs, with these exact names because they become required checks:

- `test`: in a `fedora:45` container (tools match the image), installs the tools in one retried `dnf install`, then
  `just check` (which includes `just --fmt --check`), `bash -n` on every tracked `*.sh`, and every `tests/*.sh` by
  glob (a per-script PASS/FAIL line and a summary; any failure fails the job). The tests use stubs for podman,
  skopeo, cosign, brew and the network, so none is skipped in CI. The container runs as root, so `just check` and the tests run as an ordinary user (some recipes and tests refuse root). A new test script needs no workflow change.
- `secrets`: gitleaks over the full history, pinned release and sha256, `curl --retry`.

Run the same locally: `just check; for t in tests/*.sh; do bash "$t" || echo "FAIL $t"; done`.
Test: `tests/test-workflow.sh`.

Status: done in two parts. The `testing` ruleset requires `test` and `secrets`, and `build.yml` has no `pull_request`
trigger, so the image builds only on `testing` and `main` pushes, the schedule and a manual dispatch.

## Rules

- Home- or user-level configuration (themes, icons, dotfiles) never goes in the image. It lives in its own
  repo and is pulled in by a `ujust` recipe, such as `ujust gnome-candy <recipe>`. System-level files
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
- `tests/beta-channel.sh` tests the beta workflow (schedule, base env, permissions, pins, tags, signing) and the beta prune rule.
- `tests/nvidia-variant.sh` tests the variant workflow triggers, the policy of both repositories, the kernel-matched akmods tag, the smoke checks and the released-tag prune mode.
- `tests/dx-image.sh` tests the dx workflow (triggers, guards, channel mapping, permissions, pins, tags, signing, the plan step with stub tools), the Containerfile and package lists, the policy of all three repositories, the dx smoke script with stub tools, the dx prune rule and `just dev-packages-bump`.
- `tests/image-version.sh` tests the version string, the neutral-version check (labels and os-release `IMAGE_VERSION`, beta rule) and `set_os_release_field` of the three scripts; `tests/fastfetch-default.sh` the default fastfetch configuration.
- `tests/build-triggers.sh` tests the build triggers: no `pull_request` in `build.yml`, a dispatch from another ref never logs in, pushes or signs, the aggregate job name, other workflows unchanged.
- `tests/dev-setup.sh` tests `ujust dev` (dx only), the sdk wrapper, the fnm and cargo shell snippets and the dx-only wiring (see "Developer menu").
- `tests/niri-setup.sh` tests `ujust niri-setup` and the shipped niri files (see "niri setup").
- `tests/system-defaults.sh` tests the dconf keyfile, the fish snippets and the GameMode defaults (see "System defaults").
- `tests/brew-bump.sh` tests `just brew-bump` with fake skopeo and cosign and the digest format of the Containerfile pin.
- `tests/plan-skip.sh` tests the scheduled-run skip decision with fixed inputs.
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
  (`just generate-build-tags`). A daily schedule on `main` (11:00 UTC, GitHub may delay on-the-hour runs by several minutes) refreshes `latest`. Pull requests
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
  `/etc/pki/containers`) from `IMAGE_ORG`, `IMAGE_NAME` and `cosign.pub`, keeping the catch-all last (rules for the default, `-nvidia` and `-dx` repositories).
  `just build` passes `IMAGE_NAME=${target_image##*/}` so a `localhost/` prefix does not leak into it.
- **Pruning.** `prune-testing.yml` runs weekly from `main`: it keeps the newest 10 `testing` builds, deletes
  older ones with their cosign signature versions and untagged versions older than a week, never a `latest*`
  or dated tag. Scheduled runs only delete once the repository variable `PRUNE_ENABLED` is `true`; run it by
  hand with `dry_run` on to see the plan.
- **Scheduled skip.** The 11:00 UTC run rebuilds only when something changed. The `plan` job (steps "Scheduled run, skip
  when nothing changed") reads the published `latest` with `skopeo inspect --config` and compares: the base image's
  manifest-list digest now (`sha256sum` of `skopeo inspect --raw`) against the label
  `io.github.redcodeworks.octarine-os.base-index-digest`; the git tree of main HEAD against the tree of the commit in
  the label `org.opencontainers.image.revision` (equal content counts, so a promoted merge commit does not force a
  rebuild); `org.opencontainers.image.created` younger than `SCHEDULED_REBUILD_MAX_AGE_DAYS` (7: the build installs RPMs
  from live Fedora and RPM Fusion repositories, so updates arrive without a base change); and a valid cosign signature on
  `latest`. All must hold, otherwise it builds. Every lookup that fails, an image from before the labels existed, and
  every event but `schedule` on main (push, dispatch, `testing`, pull requests) mean build. A skip sets `build=false`
  in the final plan decision, the build, promote and sign jobs are skipped and the aggregate `Build and push image`
  passes (like a docs-only push) with the summary line "skipped: base, repo and age unchanged". The decision is
  `.github/scripts/plan-skip.sh` (pure function of its environment; tests: `tests/plan-skip.sh`). The labels are set by
  `just build` and re-passed by the rechunk. Failure modes: a stale or unavailable registry lookup builds (costs minutes,
  never skips wrongly); a base digest label from a different lookup method would build every day (the build computes the
  label the same way the plan does).
- **Runners and cache.** Every job runs on the pinned `ubuntu-26.04` (build-disk also `ubuntu-26.04-arm`), not
  `ubuntu-latest`, so the toolchain (podman, skopeo, just) changes only when this repo changes it. No layer or registry
  cache: the image is one large `RUN build.sh` after `COPY system_files`, whose cache key changes with every commit and
  with the daily base, so a layer cache would almost never hit, and the rechunk step rebuilds the layers anyway; the
  scheduled skip removes the repeated identical builds instead. Tool installs go through the composite action
  `.github/actions/setup-tool` (`tool: cosign` or `tool: just`, versions pinned inside it): it restores the binary from
  `actions/cache` (key `octarine-tool-<tool>-<version>-linux-amd64`, path `~/.cache/octarine-tools/<tool>-<version>`),
  skips the download on a hit, and on a miss runs the SHA-pinned installer (`sigstore/cosign-installer`,
  `extractions/setup-just`) with `continue-on-error`, waits 60 s and tries once more if it failed (GitHub release
  downloads return 504 now and then), failing only when both attempts fail; the cache is saved after a successful install
  (the binary is copied there). Cache scoping: a run can read caches of its own branch and of the default branch, but
  not those of another branch, so `testing` and pull request runs fall back to `main`'s cache and `main` never sees
  `testing`'s: the first run on each branch downloads, then it is a hit. A cached binary that does not run is ignored
  and reinstalled. Bumping a tool means changing the version in the action (and the installer's `with:`).
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
- Variants: `dark` has cream-gray "OS" letters for dark backgrounds (the one used on the login and boot screens),
  `light` dark-brown "OS" letters for light backgrounds, `neutral` gray "OS" letters that work on any background.
- Branding: `PRETTY_NAME` is `octarineOS` (ID, NAME and VERSION_ID unchanged); the logo is on the GDM login screen and the Plymouth boot screen (own `octarine` theme, initramfs rebuilt by `build.sh`).
- Origin: a recolored version of the Fedora Silverblue logo, wordmark set in JetBrains Mono (credits in the README); no font file is shipped, only rendered text in the PNGs.

## Defaults that deviate from stock Fedora

Shipped to everyone who uses the image as-is (moved here from the README's former "Personal choices" section):

- **PAM:** `pam_u2f sufficient` for sudo and polkit: a security-key touch is accepted instead of the password; the
  password still works when no key is registered; no PIN is required. Details in `CONFIG-GUIDE.md`.
- **Firewall:** the default zone allows named services for Sunshine, MoonDeckBuddy, Steam streaming, GSConnect and
  Tailscale's UDP port (`CONFIG-GUIDE.md` has the zone notes).
- **sysctl:** `vm.overcommit_memory=1`, `kptr_restrict`, `ptrace_scope`, a very high `vm.max_map_count`, SysRq enabled.
- **Kernel argument:** `iommu=pt`.
- **Size and compilers:** the image carries no compilers; those live in the toolbox. ROCm was removed from the image (2026-11-08): GPU compute tooling moves into a toolbox image.
- **Services:** only `pmcd` and `pmlogger` are enabled; `sshd`, `tailscaled`, `cockpit.socket`
  and the snapper timers are installed and left off.
- **First install and signatures:** step 2 of the README switches on a stock Fedora, whose container policy accepts any
  image, so it is unverified (users can check first with `cosign verify --key cosign.pub ghcr.io/redcodeworks/octarine-os:latest`).
  The image installs its own policy (default `reject` plus a `sigstoreSigned` rule for `ghcr.io/redcodeworks/octarine-os`
  in `/etc/containers/policy.json`), so the second switch with `--enforce-container-sigpolicy` makes bootc pull again with
  verification enforced; after that `bootc upgrade` verifies signatures. Running the enforced form on a stock Silverblue
  before step 2 fails with `containers-policy.json specifies a default of insecureAcceptAnything; refusing usage`, which
  is expected because the policy exists only once the image is running.
- **Security key mechanics:** `system_files/etc/pam.d/sudo` and `polkit-1` carry `pam_u2f.so cue nouserok
  origin=pam://sudo appid=pam://sudo` as a `sufficient` rule before the password stack. The sudo file first skips
  `pam_u2f` with two `pam_exec` guards: no `PAM_TTY` (scripts, non-interactive sudo), or a terminal that `who` shows with a
  remote host (ssh). The prompt text is "Please touch the FIDO authenticator" (`cue`); `nouserok` lets users without a
  mapping use the password. The mapping `~/.config/Yubico/u2f_keys` has one line per user and must be made with the same
  origin and appid; a second key goes on the same line (`pamu2fcfg ... -n` prints the key part only).
- **Homebrew:** see the Homebrew section above; formulae are not pinned (use `brew bundle`).
- **Login shell for new users:** `zsh` (`SHELL=/usr/bin/zsh` in `/etc/default/useradd`, plus `/etc/skel/.zshrc`).
  Existing accounts and root keep their shell. Rolling back to an image without zsh breaks only accounts created while
  zsh was the default; distrobox copies the host login shell, so every toolbox image a zsh user enters needs zsh
  (`dev-toolbox` has it; check the `gaming` one).
- **Flatpaks:** a preinstall list of apps (`system_files/usr/share/flatpak/preinstall.d`), installed by `ujust flatpak-preinstall [--dry-run]` run as the user from a desktop session (checks: not root, session bus, flathub remote, network; test `tests/flatpak-preinstall.sh`). The former root boot unit `flatpak-preinstall.service` was removed: a root service has no session bus, and on a machine installed from stock Silverblue the enabled `fedora` OCI remote asks for a token over the session bus, so `flatpak preinstall -y` failed with `Cannot autolaunch D-Bus without X11 $DISPLAY` and left a failed unit on every boot (`flatpak remote-add --disable` does not disable an existing remote; `dbus-run-session` is not shipped). The smoke test asserts the unit is not enabled and the recipe exists. Unverified: the polkit behavior for a user running it. Themes and icons are not in the image.

## Recipe conventions (ujust recipes in `60-custom.just`, and `70-octarine-dev.just` in the dx image)

- Every public recipe has `[group('...')]` (Setup, Gaming, Toolbox, Appearance, System; Developer in the dx image) and ONE `#` comment line that is
  its `ujust --list` description; usage text goes into `help`, `--help` or `-h` output of the recipe, not the comment.
- Body: `#!/usr/bin/env bash`, `set -uo pipefail` (`-e` only where a failing step should stop). Positional arguments only
  (`[positional-arguments]` with `*args`). Unknown option or step: usage on stderr, exit 1 (2 for option errors in the
  checklist recipes). Fail soft inside checklists: report a failed step, go on, exit non-zero at the end.
- Menus come from the shared helper `system_files/usr/share/octarine-os/lib/menu.sh`, sourced at the top of a recipe
  with `menu_lib="${OCTARINE_MENU_LIB:-/usr/share/octarine-os/lib/menu.sh}"` plus inline no-op fallbacks if the file is
  missing. Items are `id^text^selected` strings; an empty id is a section heading, never returned; commas in text show
  as `;`. `menu_multi HEADER ITEM...` is a checklist with real `gum choose --no-limit` (Bluefin's `toggle-devmode` look:
  `◉`/`○`/`▸`, `--height` min(items, rows-4), `--selected` with the exact item texts) and fills `MENU_RESULT`; Esc or
  empty means nothing chosen, not a failure. `menu_one HEADER ITEM...` is a single choice through `ugum choose` (its fzf
  fallback drops every `-` flag, so none are passed; the header is printed by the helper) and sets `MENU_ONE`.
  `menu_confirm Q [y|n]` is real `gum confirm` or a plain prompt, default n; never use `ugum confirm` (its fallback
  answers YES on Esc). `menu_ready`/`menu_ready_one` say whether gum or ugum is usable on a real terminal; return code 3
  from `menu_multi`/`menu_one` means no handler, and the recipe falls back to its built-in prompts. Menus appear only
  on a terminal; `--yes`, `--no`, `--only` and a named step never open one. `gum` is an optional package of the image.
- Every selectable entry must be valid: no dividers or headings as rows in any `gum`-rendered list (gum cannot make a row
  unselectable; the helper turns a group label into a prefix, `Account: Login shell`, and puts the key hint in the header:
  `x` or space ticks, ENTER confirms the ticked rows, an empty result prints a hint); optional parameters (those with a
  default) never prompt, only required ones do. Scoped menus read recipes from `just --dump --dump-format json`, never
  from the human `just --list` (it prints group headings): public recipes only, no `default`; jq, then python3, else the
  plain `--summary` list.
- Menus follow the terminal palette: `menu.sh` exports gum's `GUM_CHOOSE_*` and `GUM_CONFIRM_*` color variables as ANSI colors 0-15
  only (cursor and selected green 2, header and prompt blue 4, buttons 0/2 and 7/8, titles `--foreground 4`), never
  overriding a variable the user set; no 256-color or hex values.
- Scoped recipes (`gnome-candy`, `toolbox`) open a menu of their next commands when run with no arguments on a
  terminal; explicit arguments pass straight through.
- Every recipe gets a test in `tests/` with stubbed binaries; tests fake a terminal with `OCTARINE_MENU_FORCE_TTY=1`.
- The `gnome-candy` menu is built from the JSON dump of the checkout (name - comment, ordered by group then name);
  `just --choose` was not used because its chooser needs fzf or `JUST_CHOOSER`, and our own menu keeps the look of the
  other menus. Untested on a real terminal (no tty or gum here).

## System defaults (dconf, fish, GameMode)

- **Selection rule** for everything taken from the owner's public dot-files repo (`redcodeworks/dot-files`, read with
  `gh api repos/redcodeworks/dot-files/contents/<path>?ref=main --jq .content | base64 -d`), decided file by file and
  entry by entry; when in doubt EXCLUDE and list it in the pull request table. INCLUDE only what is sensible for any user of the image
  and needs nothing personal. EXCLUDE: visual themes and colors (Gruvbox Material, shell theme, icon, cursor, font
  choices), the keyboard model (MEH and HYPR), workspace names and window rules, an app-grid layout built around the
  owner's apps, editor choice, personal paths and host names, anything tied to one machine or GPU, anything needing
  software the image does not ship (unless guarded), settings for extensions the image does not ship.
- **Paths.** dconf: `system_files/etc/dconf/db/distro.d/90-octarine-os` (a keyfile; group headers are dconf paths; no
  locks), compiled by `dconf update` in `build.sh` right after `system_files` is copied (a bad keyfile fails the build;
  `test distro -nt keyfile` follows). `/etc/dconf/profile/user` in the base is `user-db:user`, `system-db:local`,
  `system-db:site`, `system-db:distro`, so the user's own value wins and our file only fills `distro`; the package
  `authselect` already puts `distro.d/20-authselect` there. A key set in the `distro` database REPLACES the
  schema default, it does not merge: `org.gnome.shell enabled-extensions` has the packaged default
  `['background-logo@fedorahosted.org']` (Fedora's schema override), so our list starts with it. Extensions are enabled only when
  the image ships them as RPMs (AppIndicator, GSConnect); a uuid that is not installed is ignored by GNOME Shell.
  fish: `system_files/usr/share/fish/vendor_conf.d/octarine-os-NN-*.fish` (snippets) and
  `vendor_functions.d/<name>.fish` (functions); `/etc/fish/config.fish` is never touched. fish loads a user file of the same
  name from `~/.config/fish/conf.d/` (or `functions/`) INSTEAD of the vendor file, so an empty file disables a snippet.
  Every snippet must be safe in a non-interactive shell (`status is-interactive` or a pure PATH/guarded source) and
  every helper guarded with `command -q <tool>`. `fish_add_path --global` fills `fish_user_paths`, which fish puts in front of PATH after startup
  (and it skips directories that do not exist). The base already ships `ublue-brew.fish` (brew shellenv), so no brew snippet is added.
  GameMode: `system_files/etc/gamemode.ini` holds only `renice=10`; the machine-specific tuning (amd-pstate governor,
  tuned profile) is the `ujust gaming-setup gamemode` source `usr/share/octarine-os/gamemode.ini`, installed into
  `~/.config/gamemode.ini` (the user file overrides per key).
- **Decisions (dot-files -> image).**

  | Source | Entry | Decision | Reason |
  |---|---|---|---|
  | `20-interface.dconf` | `enable-hot-corners=false` | included | neutral behavior, one key, easy to undo |
  | | `color-scheme`, `gtk-theme`, `icon-theme`, `monospace-font-name` | excluded | visual theme and font taste, themes come from gnome-themes |
  | | `font-antialiasing='rgba'`, `font-hinting='full'` | excluded | depend on the display, differ from the GNOME default |
  | | `enable-animations`, `text-scaling-factor`, `toolkit-accessibility` | excluded | equal to the GNOME default, no effect |
  | `30-enable-extensions.sh` | AppIndicator, GSConnect | included | shipped RPMs, GSConnect has a firewall service in the image |
  | | caffeine, blur-my-shell, dash-to-dock, auto-move-windows, user-theme | excluded | shipped but change the look or need personal data (Auto Move needs an app list, blur-my-shell and the dock are visual, caffeine adds a panel icon, user-theme is useless without a theme) |
  | | arcmenu, hotedge, coverflow, clipboard-indicator, tiling shell | excluded | not shipped |
  | `10-app-folders.dconf` | folder layout | excluded | layout taste, replaces GNOME's own default folders (category-based, so a candidate if the owner wants it) |
  | `31-shell-keybindings`, `42-tiling-shell`, `43-arcmenu` | all | excluded | shortcut model, extensions not shipped |
  | `40-dash-to-dock`, `41-auto-move-windows`, `50-shell-theme` | all | excluded | look, owner's app list, Gruvbox shell theme |
  | `10-dotfiles-brew.fish` | brew shellenv | excluded | the base ships `ublue-brew.fish` |
  | `20-dotfiles-editor.fish` | helix as EDITOR | excluded | editor choice |
  | `30-dotfiles-env.fish` | `~/.local/bin` on PATH | included | neutral |
  | `40-dotfiles-steam-ld-preload.fish` | overlay LD_PRELOAD fix | included | generic, interactive only |
  | `45-dotfiles-rustup.fish` | cargo env | included | guarded by the file existing |
  | `50-dotfiles-interactive.fish` | colors, aliases, eza and fzf aliases | excluded | Gruvbox colors, personal aliases (`cp -i`, `lt` ...), tools not shipped |
  | `60-dotfiles-fzf-colors.fish` | fzf colors | excluded | colors, fzf not shipped |
  | `functions/fish_greeting.fish` | fastfetch greeting | excluded | personal fastfetch file path |
  | `functions/y.fish` | yazi wrapper | included | guarded with `command -q yazi` |
  | `gamemode.example.ini` | `renice=10` | included | generic |
  | | `desiredgov=powersave`, `[custom]` tuned profile | excluded from `/etc` | AMD amd-pstate specific and needs tuned; stays in the `gaming-setup` user file |

- **Refreshing a default from dot-files.** Read the dot-files file, apply the selection rule again, edit the shipped file
  by hand (nothing is generated), run `tests/system-defaults.sh`. The image never copies dot-files wholesale.
- Tests: `tests/system-defaults.sh` (placement and modes, `dconf compile`, `fish --no-execute`, snippet behavior in a temp HOME,
  INI parse, build step, smoke checks in `build.yml` and `build-beta.yml`, and a grep that no excluded category is shipped).
  Not verified in CI or here: a real boot reading the compiled database, fish loading the vendor snippets in a session.

## niri setup (`ujust niri-setup`)

- **Design (Kevin).** The image ships niri configuration SOURCE files in `/etc/niri/*.kdl`; `ujust niri-setup` copies them into
  the user's `~/.config/niri/` (user-owned copies) and brings in the portal and polkit configuration. Nothing applies without the
  recipe, except that `/etc/niri/config.kdl` is also niri's own fallback.
- **niri facts (26.04, from its docs under `/usr/share/doc/niri/wiki/`).** niri loads `$NIRI_CONFIG`/`--config`, else
  `$XDG_CONFIG_HOME/niri/config.kdl`, else the fallback `/etc/niri/config.kdl`; it never merges the two; with neither it writes the
  user file from its built-in default. `include "file.kdl"` works at the top level (relative to the including file, absolute,
  `~/` since 26.04, `optional=true` since 26.04); includes are positional (later overrides earlier), most sections merge, repeating
  sections (`window-rule`, `output`, `workspace`) append; a bind repeated in a later include replaces the earlier one (validated:
  `niri validate` accepts it). `niri validate -c <file>` checks a file. niri's default is `/usr/share/doc/niri/default-config.kdl`.
- **Layout of `system_files/etc/niri/`.** `config.kdl` (only relative `include` lines and a comment on outputs; no monitors are
  shipped), `10-environment.kdl` (`QT_QPA_PLATFORMTHEME gtk3`), `20-input.kdl` (niri's default input: localed keyboard layout,
  numlock, touchpad tap and natural scroll), `30-layout.kdl` (niri's default layout and screenshot path), `40-binds.kdl` (niri's
  default key bindings with `Mod+T` = `alacritty`, the terminal the image ships and niri's own default (Kevin 2026-11-10: not ghostty,
  which the image does not ship); no launcher or lock bind; media and brightness keys guarded with `command -v`), `50-noctalia.kdl`
  (`spawn-at-startup "noctalia"`, the documented way for Noctalia v5, Fedora package `noctalia`; launcher, control center, settings,
  window switcher and volume/brightness binds through `noctalia msg ...`, replacing the plain ones of the binds part), `60-window-rules.kdl`
  (niri's two default rules). No second polkit agent is started anywhere. The parts derive from niri's default config
  (GPL-3.0-or-later; credited in the README). Deleting an include line drops a part; the files are listed in the order they must stay.
- **Selection rule applied to dot-files `config/niri`** (same rule as "System defaults"): excluded the MEH/HYPR binds
  (`41-binds-meh-hyper`), the app-folder binds (`42-binds-apps`: ghostty, yazi, helix, personal folders), workspace names and routing
  (`20-workspaces`, `51-workspace-routing`), the window rules (`50-window-rules`: opacity and blur for ghostty, Steam, personal apps),
  Gruvbox colors, struts, gaps and column presets of `31-layout`, input taste of `30-inputs` (scroll factor, clickfinger, drag-lock),
  gestures (`32-gestures`), `PROTON_ENABLE_HDR` and the Adwaita cursor of `10-environment`, and from `60-noctalia` the corner radius, global
  blur, transparent workspace background, backdrop layer rule, floating settings window and the `honor-xdg-activation-with-invalid-serial`
  debug flag (it weakens focus-steal protection). Included: `QT_QPA_PLATFORMTHEME`, `spawn-at-startup "noctalia"` and the Noctalia binds.
- **Other two sources** (in `system_files/usr/share/octarine-os/niri-setup/`, never in `/etc`): `niri-portals.conf` (the packaged
  `/usr/share/xdg-desktop-portal/niri-portals.conf` has `default=gnome;gtk;`, Access and Notification `gtk`, Secret `gnome-keyring`; the
  image ships oo7-daemon/oo7-portal AND gnome-keyring, and `org.freedesktop.secrets` is aliased to `oo7-daemon.service`, so on niri the
  packaged file selects gnome-keyring while oo7 owns the service; the user file keeps the packaged lines and sets
  `org.freedesktop.impl.portal.Secret=oo7-portal;`; a user file replaces the packaged one entirely) and `10-octarine-os.toml`
  (Noctalia v5.4.1 has no system-wide config layer: built-in defaults, then every `*.toml` in the user's config directory sorted and merged,
  then `~/.local/state/noctalia/settings.toml`; `10-` sorts before the user's `config.toml`, so the user wins; content `[shell]
  polkit_agent = true` plus the explanatory comment). No `/etc` override for portals or Noctalia exists, and `user-setup` has no polkit step.
- **Recipe.** Group Setup; steps `niri`, `portals`, `polkit`; `--yes`, `--no` (plan only), `--only STEP[,STEP]`, `help`; the shared
  checklist helper (a step chosen in it is not asked "Apply?" again); each file is idempotent (identical = "already done"), a different
  existing file shows a diff, the replace question defaults to keep (also under `--yes` and with no answer to read) and a yes saves
  `<file>.bak-YYYYMMDD-HHMMSS` first; the `polkit` step skips without `noctalia` on PATH; a failed step is FAILED with its re-run command, exit 1;
  option errors exit 2; no sudo. Test hook: `OCTARINE_NIRI_SETUP_SRC` (a tree with `niri/*.kdl`, `niri-portals.conf`, `10-octarine-os.toml`).
  Test: `tests/niri-setup.sh` (fake gum, ugum, noctalia, sudo, temp HOME; `niri validate` of every include combination when niri exists; a guard
  that `ghostty` and `ptyxis` appear in no shipped niri file). The smoke checks in `build.yml` and `build-beta.yml` look for the files.
- **Unverified.** niri and Noctalia reading the copied files in a session, Noctalia's `msg` subcommand names (taken from the owner's dot-files),
  the portal actually attaching oo7, `alacritty` on a booted image.

## Image identity (`IMAGE_ID`, `IMAGE_VERSION`) and the fastfetch default

- `PRETTY_NAME` stays `octarineOS` in EVERY image (default, beta, nvidia, dx); `NAME`, `ID`, `VERSION_ID`, `VARIANT_ID` are
  untouched. The image identity goes only into `IMAGE_ID` and `IMAGE_VERSION` of `/usr/lib/os-release` (`/etc/os-release` is a
  symlink), written as quoted lines by `set_os_release_field` (replace the line if it exists, append otherwise; the same
  function is in `build_files/build.sh`, `variants/nvidia/nvidia.sh` and `variants/dx/dx.sh`, and `OS_RELEASE_FILE` is a test-only
  override of the path).
- Field values:

  | Image | `IMAGE_ID` | `IMAGE_VERSION` | Set in |
  |---|---|---|---|
  | `octarine-os` (`latest`, `testing`) | `octarine-os` | `<YYYYMMDD>-<short sha>` | `build.sh` |
  | `octarine-os:beta` | `octarine-os` | `beta-<YYYYMMDD>-<short sha>` | `build.sh` |
  | `octarine-os-nvidia` | `octarine-os-nvidia` | its own build's `<YYYYMMDD>-<short sha>` | `nvidia.sh` |
  | `octarine-os-dx` (`latest`) | `octarine-os-dx` | its own build's version | `dx.sh` |
  | `octarine-os-dx:beta` | `octarine-os-dx` | `beta-` plus its own build's version | `dx.sh` |

- The version string is `.github/scripts/image-version.sh`, the same string as the `org.opencontainers.image.version` label (the
  label never carries the `beta-` prefix). It reaches the build as the build argument `IMAGE_VERSION` (`just build` adds
  `${IMAGE_VERSION_PREFIX}` in front: the beta workflow sets `IMAGE_VERSION_PREFIX: beta-` in its `env:`; the nvidia and dx
  workflows pass `--build-arg IMAGE_VERSION`, dx adds `beta-` for its beta channel). The variants override both fields with
  their OWN build's version, never the base's. A promoted image (testing to `latest`) is a retag of the tested digest, so it keeps
  exactly the fields it was built with: that is why the version names no channel.
- Checks: the smoke tests of `build.yml` and `build-beta.yml` (env `VERSION_RE`), `dx-smoke.sh` (env `IMAGE_CHANNEL`) and
  `nvidia-smoke.sh present` assert `PRETTY_NAME="octarineOS"`, the right `IMAGE_ID` and the `IMAGE_VERSION` format
  (`[0-9]{8}-[0-9a-f]{7,}`, with `beta-` for beta builds). `check-version-neutral.sh` also reads the image's os-release
  `IMAGE_VERSION` (the workflows append it to the label lines): required, no `testing`/`latest`, no `beta` in a stable image, and
  with `BETA=true` it must start with `beta-`. Tests: `tests/image-version.sh`, `beta-channel.sh`, `dx-image.sh`, `nvidia-variant.sh`.
- fastfetch is NOT in the image and stays a Homebrew install (owner's rule); only a default configuration ships:
  `system_files/etc/xdg/fastfetch/config.jsonc` (a plain file; fastfetch reads `~/.config/fastfetch/` first, then `/etc/xdg/fastfetch/`,
  so the user's own file wins). Its `Image` line prints `IMAGE_ID IMAGE_VERSION`, falls back to the booted rpm-ostree deployment where
  they are missing, and `n/a` elsewhere. Test: `tests/fastfetch-default.sh` (strips the `//` lines, then `jq`). Never add fastfetch to
  `build.sh` or a Brewfile.

## Beta channel (`octarine-os:beta`)

- `.github/workflows/build-beta.yml`: weekly (Wednesday 14:00 UTC, clear of the daily 11:00, Sunday 05:00 prune and Sunday 12:00
  NVIDIA runs) and on dispatch from any ref, never on pushes or pull requests, not a required check. It builds the normal
  image FROM `ghcr.io/ublue-os/silverblue-main:beta` (workflow env `BASE_IMAGE`, `FEDORA_VERSION=beta`; the repository variables
  are ignored), smoke tests (a copy of build.yml's block, `tests/beta-channel.sh` fails on drift), rechunks, pushes `beta` and
  `beta-<date>-<sha>` only, signs with the same key (`signing` environment) and verifies both tags. Failure = a red scheduled run, no
  notification. The `beta` tag only exists upstream while ublue-os/main builds a beta (their `BUILD_BETA` variable); until then it
  equals stable. Policy: the existing rule for the `octarine-os` path covers every tag. Prune: `PRUNE_KIND=beta KEEP=3` in
  `prune-testing.yml` keeps the newest three `beta-*` builds and any version holding `beta`. Test: `tests/beta-channel.sh`.

## NVIDIA variant (`octarine-os-nvidia`)

- **What it is.** A second image, `ghcr.io/redcodeworks/octarine-os-nvidia`, built weekly (Sunday 12:00 UTC, after the
  daily 11:00 run) by `.github/workflows/build-nvidia.yml` and by manual dispatch on `main`; never on pushes, pull requests
  or `testing`, no testing or promote channel; it publishes `latest` and the dated aliases and signs them with the same key
  in the `signing` environment. A separate small workflow because `build.yml` is built around testing, promote and docs-only
  semantics; the tag, push and sign steps are the same. The default image, its daily skip logic and its promote flow do not know about it.
  The owner does not use it; it exists for others (opt-in, unsupported).
- **Initramfs check (2026-11-09).** `nvidia-smoke.sh` runs under `pipefail`, so `lsinitrd | grep -q` failed whenever grep
  quit at the first match and lsinitrd died of SIGPIPE; the listing now goes to a file first. On failure the script prints
  `DIAG` lines (lsinitrd status and stderr, first lines, nvidia lines, `ls -l`), and `nvidia.sh` logs the initramfs size and
  mtime around dracut, dracut's exit status (non-zero fails the build) and the nvidia entries of the new initramfs. The
  `dracut-install ... /root` error in the build log has exit status 0 and is not the cause.
- **How it is built.** `variants/nvidia/Containerfile` starts FROM `ghcr.io/redcodeworks/octarine-os@<digest of :latest at
  build time>` (verified with cosign first) and adds only the driver: an akmods stage `ghcr.io/ublue-os/akmods-nvidia-lts@<digest>`
  (proprietary driver, closed kernel modules, the 580 branch, which supports older cards; the `-open` modules need RTX 20 or
  newer) is bind-mounted at `/tmp/akmods-rpms` and `variants/nvidia/nvidia.sh` runs its
  `IMAGE_NAME=silverblue .../ublue-os/nvidia-install.sh` (needs dnf5 and the network: negativo17, NVIDIA's container toolkit
  repository and a build-time COPR; it exits 1 when kmod and driver versions differ), then writes
  `/usr/lib/modprobe.d/00-nouveau-blacklist.conf` and `/usr/lib/bootc/kargs.d/00-nvidia.toml` (`rd.driver.blacklist=nouveau`,
  `modprobe.blacklist=nouveau`, `nvidia-drm.modeset=1`, the Bluefin LTS shape, unverified for Fedora; bootc merges it with the
  default image's own kargs file) and rebuilds the initramfs with dracut. No rechunk (a layer on a chunked image). `silverblue-nvidia` was
  retired by Universal Blue (notice of 7 Nov 2026), which is why the variant starts from our image instead.
- **Kernel match (the main risk).** The workflow reads the kernel inside the pulled base (`rpm -q kernel-core`) and
  `.github/scripts/nvidia-akmods-ref.sh` picks the akmods tag pinned to exactly that kernel: `main-<fedora>-<kernel with arch>`
  or without the arch suffix (the tag form is unverified, both are tried), resolved to a digest with skopeo. No such tag, a
  kernel of another Fedora release or a malformed kernel fails the job loudly and publishes nothing; the moving `main-<fedora>`
  tag is never used. `nvidia.sh` also asserts the kernel is unchanged by the install. Base and akmods digests are logged and
  recorded in the labels (`org.opencontainers.image.base.digest`, `io.github.redcodeworks.octarine-os.nvidia-akmods`).
- **Checks.** `.github/scripts/nvidia-smoke.sh present` inside the built image (a non-firmware package with nvidia in its
  name, a `nvidia*.ko*` for the kernel, the one-kernel and base-kernel equality, initramfs content when `lsinitrd` exists,
  the kargs and modprobe files, an NVIDIA SELinux module) and `... absent` on the default image (no driver packages or
  modules). The akmods image signature is checked with the vendored `keys/ublue-os-main-cosign.pub`; that this key signs the
  nvidia image is unverified, so a failure is a visible warning, not a silent skip.
- **Signature policy order.** `build.sh` writes a `sigstoreSigned` rule for `ghcr.io/redcodeworks/octarine-os`,
  `...-nvidia` and `...-dx` into the default image (the variant inherits the file; the `registries.d` entry is per namespace and already
  there). A machine first switches to the default image (installing the policy), then to the variant with
  `--enforce-container-sigpolicy`; switching back works the same way.
- **Prune.** `prune-testing.yml` also prunes the variant's repository (`PRUNE_KIND=released`: versions whose tags are only
  dated or `latest-*` aliases, never one that carries the bare `latest`, newest builds kept).
- **Policy exception.** NVIDIA's proprietary driver is out-of-tree software (negativo17, NVIDIA's toolkit repository, a COPR at
  build time), accepted only in this opt-in variant; the default image stays Fedora-official packages only.
- **Unverified.** No GPU, no boot test, the akmods kernel-tag form, the driver version, Secure Boot enrollment
  (`ujust enroll-secure-boot-key`, from the base, enrolls Universal Blue's key; MOK password `universalblue`), SELinux module
  detection by `semodule -l` in a build container. Tests: `tests/nvidia-variant.sh`.

## dx image (`octarine-os-dx`)

- **What it is.** `ghcr.io/redcodeworks/octarine-os-dx`: the published default image plus the developer toolchain of the owner's
  `dev-toolbox` (so the host has compilers, `-devel` libraries, debuggers, `uv`, `rustup`, `fish`, ROCm userspace), VM tooling,
  tracing tools and a few extras; the VS Code Flatpak is preinstalled through the preinstall list. Opt-in, for the owner's own
  use. The default image still has no compilers (see "Verifying changes"); nothing in `Containerfile` or `build.sh` installs the dx
  set, `tests/dx-image.sh` asserts that.
- **Lineage (two channels).**

  | Base | Default image | dx image |
  |---|---|---|
  | `ghcr.io/ublue-os/silverblue-main:45` | `octarine-os:latest` | `octarine-os-dx:latest` |
  | `ghcr.io/ublue-os/silverblue-main:beta` | `octarine-os:beta` | `octarine-os-dx:beta` |

  The beta channel is a duplicate of latest until Universal Blue moves its `beta` tag to Fedora 46; that is expected.
- **Files.** `variants/dx/Containerfile` (ARGs `BASE_IMAGE`, `BASE_TAG`, `BASE_DIGEST`; `FROM ${BASE_IMAGE}:${BASE_TAG}${BASE_DIGEST:+@}${BASE_DIGEST}`,
  so the workflow's digest wins and a bare local `podman build` still works; the `devpkgs` stage; `bootc container lint`),
  `variants/dx/dx.sh` (runs the shared installer, then the extras, copies `variants/dx/system_files/`, enables
  `podman.socket` (rootful; the default image already enables the user one globally) and asserts the kernel is unchanged and
  the only one), `variants/dx/packages/extras.txt` (grouped list, one strict `dnf5 install`),
  `variants/dx/system_files/usr/share/flatpak/preinstall.d/dx.preinstall` (VS Code; `ujust flatpak-preinstall` reads every
  `*.preinstall` in that directory, so a dx-only drop-in needs no recipe change), `.github/workflows/build-dx.yml`,
  `.github/scripts/dx-smoke.sh`, `tests/dx-image.sh`.
- **The shared package list (digest pin).** `ghcr.io/redcodeworks/dev-packages` is a signed FROM scratch image from the
  fedora-toolbox repository (`/dev.txt`, `/install.sh`, `/README`; `dev-toolbox` installs the same list). The Containerfile pins it by
  digest (`ARG DEV_PACKAGES_TAG` for humans, `ARG DEV_PACKAGES_DIGEST` decides) and installs it with
  `RUN --mount=type=bind,from=devpkgs,source=/,target=/dev-packages` (inside `dx.sh`: `bash /dev-packages/install.sh`; it needs
  dnf5 and root, runs one strict install, cleans the dnf caches; `EXCLUDE="a b"` drops entries; `a|b` alternatives, `@group`
  and `#` comments are its syntax). **Bump it** with `just dev-packages-bump [tag]` (default `latest`): it takes the digest of
  the raw manifest with `skopeo inspect --raw`, verifies the signature with `keys/redcodeworks-toolbox-cosign.pub`
  (the toolbox repository's cosign key, ECDSA) and only then edits the two ARG lines, recording the dated
  `latest-<date>-<sha>` tag that has the same digest. CI checks the pin's format and verifies the signature on every build.
  `tests/dx-image.sh` covers the recipe with fake skopeo and cosign.
- **Workflow rules (`build-dx.yml`).** Triggers: `workflow_run` of "Build container image" and "Build beta image" (`completed`,
  `branches: [main]`; `workflow_run` workflows run from the default branch's file, so the workflow cannot be run from `testing`
  or a feature branch and the first run happens only after promotion) and `workflow_dispatch` (inputs `channel`, `force`). The
  plan job runs only when `github.ref == refs/heads/main` and (a dispatch, or the triggering run concluded `success`, its event
  is `schedule`, `push` or `workflow_dispatch`, and its `head_branch` is `main`; never a pull request). Channel: `beta` after
  the beta build, `latest` after the default build, the input on dispatch. Plan: resolves
  `octarine-os:<channel>` to a digest (sha256 of the raw manifest), verifies it with `cosign.pub`, reads the published
  `octarine-os-dx:<channel>` labels and ends green with the notice "base unchanged, nothing to build" when its
  `org.opencontainers.image.base.digest` equals the digest AND its `io.github.redcodeworks.octarine-os.dx-tree` label equals
  `git rev-parse HEAD:variants/dx` (so a change to the dx files, for example a bumped pin, also rebuilds; the base digest
  alone would wait for the next base change) and no force; a missing, unreadable or unlabelled image builds. The plan job logs
  in with `packages: read` because a new GHCR package is private until the owner makes it public. Build: setup tools, the pin
  check and signature verification, base verified again by digest and pulled, kernel of the base read, `podman build` with
  explicit labels (the `just build` set plus `base.name`/`base.digest`, `dx-tree` and `dev-packages`; inherited maintainer
  labels and the base's `base-index-digest` are unset), size guard (15 GiB), `dx-smoke.sh`, `just ostree-rechunk`, the
  channel-neutral version check, push of `<channel>` and `<channel>-<date>-<sha>`. Sign job (`signing` environment): signs
  every pushed digest with the repository key, verifies both tags with `cosign.pub`. Concurrency: one group per channel,
  `cancel-in-progress: false`. Least privilege per job, actions pinned by SHA with version comments, schedules none.
- **Smoke test.** `dx-smoke.sh` runs inside the built image: gcc, g++, clang, cmake, ninja, meson, gdb, pkgconf, uv, fish, the rustup package and `rustup-init` (the RPM ships only that; no `rustup` command),
  `glib2-devel`, `openssl-devel`, virt-manager, virt-viewer, qemu-kvm, the libvirtd and virtqemud units, `podman.socket`,
  the VS Code preinstall list, exactly one kernel equal to `BASE_KERNEL`, and the default image's checks that still apply
  (os-release, the three policy rules, sudoers, brew, recipes, removed packages). It prints `DIAG` lines on failure. Under
  `pipefail` it never pipes a producer into `grep -q` (the lesson of the NVIDIA initramfs check).
- **Signature policy.** `build.sh` writes a `sigstoreSigned` rule for `octarine-os`, `octarine-os-nvidia` and `octarine-os-dx` into
  the default image (strips `-nvidia` and `-dx` from `IMAGE_NAME`); the dx image inherits it. A machine therefore switches to
  the dx image only after it runs a default image built with the rule (update first, then
  `bootc switch --enforce-container-sigpolicy`). Asserted in `tests/nvidia-variant.sh` and `tests/dx-image.sh`, and in the smoke tests of
  `build.yml` and `build-beta.yml`.
- **Prune.** `prune-testing.yml` also prunes the `octarine-os-dx` package with `PRUNE_KIND=dx KEEP=3`: per channel the newest
  three dated builds (`latest-<date>-<sha>`, `beta-<date>-<sha>`) stay, never a version holding the bare `latest` or `beta`
  tag, any version with another tag is not a candidate, signatures of deleted images go with them.
- **VS Code.** `com.visualstudio.code` is the community-maintained Flathub build; Flathub's API reports it as not verified
  (Microsoft is only listed as developer). The owner chose it knowingly; the preinstall file and the README say so.
- **Stage 3 (planned).** The VM-hosting set (libvirt, QEMU, Cockpit machines and friends) will move out of the default image
  and live only in dx (`extras.txt` already lists it so dx stays self-sufficient); the libguestfs tools stay in the default image.
- **Unverified until promotion.** The real build (no build before the merge exercises `variants/dx`: `build.yml` builds the default
  image only), the base digest compare, the sign step and the first `workflow_run` behavior only run after the workflow
  exists on `main`. The `FROM` expansion `${BASE_DIGEST:+@}${BASE_DIGEST}` was checked with a local podman, not on the runner.

## Developer menu (`ujust dev`, dx image only)

- **Wiring.** The recipe is `variants/dx/system_files/usr/share/ublue-os/just/70-octarine-dev.just` (group Developer, one recipe `dev`).
  ublue-os-just's `/usr/share/ublue-os/justfile` imports the files of its own package plus only the OPTIONAL `60-custom.just`
  (`import?`), so a new file there is not seen by itself: `variants/dx/dx.sh` copies the dx `system_files`, then appends the line
  `import? "/usr/share/ublue-os/just/70-octarine-dev.just"` to that justfile (idempotent, newline-safe, asserted with `grep -qxF`).
  The default image has neither the file nor the line; `tests/dev-setup.sh` asserts that and runs the import block of `dx.sh`.
  Other dx-only files: `variants/dx/system_files/usr/bin/sdk` (the SDKMAN wrapper, see below) and
  `variants/dx/system_files/etc/profile.d/octarine-dx-cargo.sh`. The smoke test (`dx-smoke.sh`, env hooks `ETC_DIR`, `BIN_DIR`) checks that
  `ujust --summary` lists `dev`, the recipe file, the import line, the wrapper and the profile snippet.
- **Shape.** Follows the recipe skill: `help`/`--help`/`-h`, `--yes`, `--no` (plan only), `--only STEP[,STEP]`, the shared checklist
  (`menu_multi`, NOTHING preselected, because nothing may run that was not ticked) with plain y/n prompts as the fallback,
  summary with undo lines, option errors exit 2, fail-soft steps, exit 1 when any failed. `retry` runs a network command up to three times
  (`DEV_RETRIES`, `DEV_RETRY_WAIT` seconds). Existing different files go through `place` (diff, default keep, timestamped backup).
  A root user is refused. `--yes` without `--only libvirt` skips the libvirt step because it needs sudo (never an unprompted sudo).
- **Steps (ids in order) and what they do.**
  - `libvirt`: system libvirt. One `sudo sh -c '...'` built from only what is missing, run once and never retried; on failure the exact
    command is printed. It copies the `libvirt` line from `/usr/lib/group` into `/etc/group` first when needed (Atomic keeps it only
    there, same as `user-setup`), `usermod -aG libvirt`, `systemctl enable --now` for the missing ones of `virtqemud.socket`,
    `virtnetworkd.socket`, `virtstoraged.socket`. The user file `~/.config/libvirt/libvirt.conf` gets `uri_default = "qemu:///system"` (`place`).
    The default network is checked with `virsh -c qemu:///system` only once the group is in the session (`id -nG`), else a note says to log in
    again and re-run: `net-autostart default`, or `net-define` from `/usr/share/libvirt/networks/default.xml`, autostart, start when missing.
  - `tools`: second checklist of groups on a terminal (all preselected), per-group y/n without gum, all under `--yes`; one `brew install` per
    formula (retried), installed ones skipped, a failed package is listed with `ujust dev --only tools` and does not stop the rest.
    Groups: Editor `helix`; Python `ruff ty sqlfluff`; Web `prettier typescript-language-server vscode-langservers-extracted yaml-language-server marksman`;
    Java `jdtls google-java-format`; Lua `lua-language-server stylua`; TOML `taplo`; SQL `sql-language-server`; GitHub `gh` (no login).
    Debuggers were considered and not added: gdb is an image package and the IDEs bring their own.
  - `vscode`: `flatpak install --user -y flathub com.visualstudio.code` (adds the flathub remote to the user installation when missing), with the
    note "community-maintained build, not verified on Flathub".
  - `jetbrains`: official cask `brew install --cask jetbrains-toolbox` (supports Linux since Oct 2026, `auto_updates`, so brew upgrade does not touch it);
    the older ublue tap cask `jetbrains-toolbox-linux` is uninstalled first when present (default yes, the state in `$HOME` stays). The official cask only
    links the binary, so the step writes `~/.local/share/applications/jetbrains-toolbox.desktop` (`Exec=<brew prefix>/bin/jetbrains-toolbox %u`, the stable
    path, never the versioned Caskroom path; marked `X-Octarine-Generated=ujust dev`; validated with `desktop-file-validate` when present) and copies a
    `*toolbox*.png` found under the cask's Caskroom directory to `~/.local/share/icons/hicolor/256x256/apps/jetbrains-toolbox.png`; no PNG found means a note, not a failure.
  - `rust`: `~/.cargo/bin/rustup` present means "already set up" (shows `rustup show active-toolchain`), else `rustup-init -y --profile default --no-modify-path`;
    then `rustup component add rust-analyzer rust-src` for the missing ones. PATH without rc edits: `/etc/profile.d/octarine-dx-cargo.sh` (dx only; appends
    `~/.cargo/bin` to the END of PATH when it exists, idempotent) and the fish snippet, which is the existing default-image `octarine-os-30-rustup.fish`, extended
    (sources `~/.cargo/env.fish` when present, else `fish_add_path --global --append ~/.cargo/bin` when the directory exists; harmless in the default image).
  - `java`: SDKMAN through the OFFICIAL TAP, never a `curl | bash`: `brew install sdkman/tap/sdkman-cli` (the formula installs the pinned release zip with sha256
    pins under `$(brew --prefix sdkman-cli)/libexec`; `brew install --help` of Homebrew 7.0.13 has no trust option, the fully qualified name is what the brief used) and
    `brew pin sdkman/tap/sdkman-cli` (undo `brew unpin`). `sdkman-init.sh` hard-sets `SDKMAN_CANDIDATES_DIR=$SDKMAN_DIR/candidates`, so the JDKs would live inside the keg
    and be lost on a brew upgrade or cleanup: the real directory is `~/.sdkman/candidates` and the keg's `libexec/candidates` is a symlink to it. The wrapper `/usr/bin/sdk`
    re-checks that on every call (a formula upgrade recreates an empty directory; anything found there is MERGED into `~/.sdkman/candidates`, never deleted; a name present on
    both sides leaves both and warns). The wrapper runs SDKMAN in a bash subshell (`sdkman-init.sh` defines `sdk` as a function and is not written for `set -u`); it
    picks `~/.sdkman` when its `bin/sdkman-init.sh` exists (an installation made by SDKMAN's own script: used as it is, never migrated, the tap is not installed beside it),
    else the tap's libexec. `sdk --octarine-relink` only does the symlink check and prints the SDKMAN_DIR (the recipe uses it and never depends on a user's own `~/.local/bin/sdk`,
    which wins on PATH on the owner's machine). Then Zulu: `sdk list java` is parsed by the last `|` column (identifier ending in `-zulu`, `.fx` and `crac` builds excluded), the newest per
    major of 8, 11, 17, 21, 25 by `sort -V`, skipped when a `^MAJOR[.+-]*-zulu` directory exists; `sdk install java ID` gets `n` on stdin (declines SDKMAN's default question), then
    `sdk default java <21>`. Test hooks: `OCTARINE_SDK_WRAPPER`, `SDK_HOME_DIR`, `OCTARINE_BREW_PREFIX`.
  - `node`: fnm (not nvm: nvm.sh costs several hundred milliseconds to source, upstream does not support Homebrew installs of nvm, Volta is unmaintained). `brew install fnm`,
    `fnm install --lts`, `fnm default lts-latest` (`fnm default` is a shorthand for `fnm alias VERSION default`; `--lts` and `lts-latest` are from fnm's docs; the exact alias
    handling was not run here). Shell files written with `place` into `~/.config/octarine-os/`: `fnm.sh` (bash and zsh) and `fnm.fish`; each caches `fnm env --use-on-cd --shell <sh>`
    under `${XDG_CACHE_HOME:-~/.cache}/octarine-os/shell/fnm.<shell>`, regenerates it only when the fnm binary is newer than the cache (`-nt`, builtin) or when
    `FNM_MULTISHELL_PATH` no longer exists (fnm keeps a per-shell directory, possibly on a tmpfs cleaned at reboot), and sources it. A consequence: every shell shares the
    cached multishell path, so `fnm use` in one shell is seen by the others (unverified in practice). The step prints the one guarded `source` line per shell and offers to append
    it to an existing `~/.zshrc`, `~/.bashrc` or `~/.config/fish/config.fish` (diff, timestamped backup, default keep, so `--yes` never edits them). It does not depend on `ujust shell-setup`.
    An existing `~/.nvm` is untouched (fnm keeps versions in `~/.local/share/fnm`; `.nvmrc` works).
  - `python`: `uv python install 3.12 3.13 3.14` for the missing ones; installed means a `cpython-<v>.` line of `uv python list --only-installed` whose path is under
    `UV_PYTHON_INSTALL_DIR` or `~/.local/share/uv/python` (a system Python does not count), then the list is printed. `DEV_PYTHONS` is a test hook.
- **Facts used.** The dx image carries `fuse-libs` (the Toolbox AppImage), Homebrew is on PATH for bash, zsh and fish, the VS Code Flatpak is NOT verified on Flathub (chosen knowingly),
  Fedora's `rustup` RPM ships only `rustup-init`. `rustup-init` writes `~/.cargo/env` and `env.fish` even with `--no-modify-path` (it only skips rc edits).
- **Tests.** `tests/dev-setup.sh`: stub brew, flatpak, rustup, rustup-init, fnm, uv, virsh, systemctl, sudo, id, getent, gum and the sdk wrapper on a restricted PATH, temp HOME;
  covers fresh, already done, partial, a failed package, retries, missing brew, `--only`, `--yes` (no sudo), `--no`, the menu entries, the generated files, the real wrapper
  (tap mode, symlink re-creation, merge, conflict), the fnm cache creation and reuse in bash, zsh and fish, the profile and fish snippets, and the dx-only placement.
- **Unverified (needs a real machine).** A real `brew install` of every formula and the cask, `flatpak install` of the VS Code build, `sudo usermod` and the socket
  enablement, `sdkman/tap/sdkman-cli` install and the symlink under a real brew upgrade, real `sdk list java` output (the parser was written against the documented table),
  fnm's `lts-latest` alias, the icon file inside the real cask, the cached `fnm env` behavior across reboots, the libvirt default network on a real host, `ujust` seeing the
  import line after a real dx build.

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
- gnome-software is removed (Bazaar, `io.github.kolunmi.Bazaar` in `tools.preinstall`, is the software center;
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
  recipe's catalog (uv, rustup, sdkman, nvm), `EXPORT_BINS` the commands exported with `distrobox-export`,
  `IDES` the launchers `--ide` offers. No sidecar means no tools, exports or launchers. The catalog and notes
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
- **Other recipes.** `ujust gnome-candy` runs a recipe of the gnome-themes repo from a fresh checkout in
  `~/.cache/gnome-themes/repo` (`GNOME_THEMES_REF` picks the ref).
  `user-setup [user] [--yes|--no] [--only STEP[,STEP...]]` replaced the seven single-purpose recipes `add-user-groups`,
  `flatpak-games-access`, `steam-flatpak-devices`, `vscode-flatpak-podman`, `podman-desktop-deny-docker-socket`,
  `chrome-flatpak-webapps` and `gearlever-applications` (removed, no aliases). It is an interactive y/n checklist; steps
  in order: `groups` (copies the `gamemode`, `input` and `libvirt` lines from `/usr/lib/group` into `/etc/group` first;
  sudo), `shell` (`usermod -s /usr/bin/zsh`, second and last sudo use; skeleton zsh files copied with `cp -n` for the
  invoking user only), `flatpak` (skipped per app when missing (`flatpak info`) or the override is present (`flatpak
  override --user --show`); defaults yes except the Steam devices (widens the sandbox) and the games directory (needs a
  path)), `fonts` (Homebrew casks only, no downloads or checksum code here: preset `system_files/usr/share/octarine-os/
  homebrew/fonts.Brewfile`, Bluefin's `fonts-dev.Brewfile` plus `font-fantasque-sans-mono-nerd-font` (12 casks), installed with `brew bundle --file`; or JetBrains
  Mono only, or a pick from `brew search --cask nerd-font`; terminal font only on an explicit choice), `fish-terminal` (Ptyxis profile via `gsettings`,
  reused when one already starts fish; starship via `brew install`, hook file `~/.config/fish/conf.d/starship.fish`),
  `search` (`org.gnome.desktop.search-providers`: Calculator, Bazaar, Characters and Clocks into `enabled`, Calculator
  first in `sort-order`; always merged with the value read just before writing, never rebuilt from constants, no write
  when nothing changes). `--yes` takes defaults; `--no` prints the plan; a failed step is reported, the rest continue, exit status
  non-zero. Test hooks: `USER_SETUP_FISH/ZSH/SHELLS/SKEL/SEARCH_DIRS/FONTS_BREWFILE`. Tests: `tests/user-setup.sh` (fake
  flatpak, sudo, id, getent, usermod, gsettings, brew, fc-list). The dot-files steps (`dotfiles`, `brew`, `gnome` with its
  GNOME extension installer) were removed from `user-setup` on 2026-11-09 by Kevin's decision; the dot-files repo itself and its
  `just` recipes still exist, independent of this image.
 `gaming-setup [step...] [--yes|--no]` replaced `steam-gamescope-setup`, `steam-gamescope-reset`, `extest-build`,
  `extest-steam-setup` and `extest-steam-reset` (removed, no aliases). Steps: `steam`, `protonup`, `lutris` (Flatpaks:
  `com.valvesoftware.Steam`, `net.davidotek.pupgui2`, `net.lutris.Lutris`; installed in the user installation only when
  Flathub's appstream catalog marks them verified, `flathub::verification::verified`, failing closed; the catalog key
  and the ProtonUp-Qt id are unverified here), `extensions` (gamescope and MangoHud Vulkan layers on Steam's runtime
  branch, Proton-GE `com.valvesoftware.Steam.CompatibilityTool.Proton-GE//stable`, each ref checked with `flatpak
  remote-info` first; the PATH override adds `/usr/lib/extensions/vulkan/gamescope/bin` and `.../MangoHud/bin` when
  installed; the MangoHud directory name is unverified), `extest` (pinned commit `cb77cd4f...`, env `EXTEST_SRC`,
  `EXTEST_DEST`, `EXTEST_COMMIT`; builds with host cargo or inside dev-toolbox), `desktop` (launchers
  `octarine-gaming-steam*.desktop` carrying `X-Octarine-Generated=ujust gaming-setup`; only marked files are
  overwritten; the extest hook is the old mechanism, `--filesystem=<lib>:ro --env=LD_PRELOAD=<lib>/lib64/libextest.so`,
  but passed to `flatpak run` per launcher instead of a global override; gamescope launcher: `flatpak run
  --command=gamescope ... -f -W -H -r --adaptive-sync -- steam -gamepadui`, the `steam -gamepadui` part is an
  unverified choice; resolution from Mutter DisplayConfig, else `niri msg --json outputs` with jq, else `GAMING_SETUP_RES`
  or a prompt; never silent), `gamemode` and `reset` (also removes the old global extest override entries). Tests:
  `tests/gaming-setup.sh`. Extest is by Supreeeme and contributors, MIT license; credited in the README, no source
  shipped.
  Flatpak recipes only add or remove their own override entries (Flatseal shows the result); recipes are
  idempotent, and each override-changing recipe has a matching reset (`user-setup` prints the undo per applied step).
  Themes land in `~/.themes`, icons in `~/.local/share/icons`; `gnome-candy` needs network, git and just, and
  without a name opens a checklist (everything off by default). The extest step needs `cargo` and a C linker (the host has none; the recipe uses the
  toolbox) and is not verified end to end.

## Image hygiene notes

- Labels were missing from the pushed image until `ostree-rechunk` passed them on (see "Labels").
- The base image may carry `/etc/brlapi.key` (brltty's API key, generated at package install and so identical
  in every copy of a public image) and a copy of `/sysroot/ostree/repo/objects`; neither is created by this
  repo's Containerfile or `build.sh`. Findings are with the hub for follow-up.
