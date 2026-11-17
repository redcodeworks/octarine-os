# CLAUDE.md

Project guidance for Claude Code. This file is the project's memory: keep durable rules and
decisions here, not in the global `~/.claude` memory. It is public if committed, so never put
secrets, hostnames or personal data in it.

## What this is

A personal, publicly shared bootc image (`ghcr.io/redcodeworks/octarine-os`) built on
`${BASE_IMAGE}:${FEDORA_VERSION}` (now `ghcr.io/ublue-os/silverblue-main:45`; see the Containerfile bullet). It exists to make one desktop reproducible. See `README.md`
for the user-facing description and `docs/CONFIG-GUIDE.md` for the two-step setup guide (rebase, then recipes); `docs/README.md` indexes the directory documents.

## README policy

The README is user-facing for people who just need the concise what, why and basic how to use it. It is not a place
for notes to yourself and carries no technical implementation details (those go here). Essential sections:
Build status (a short badge table, image by main and testing, directly under the opening paragraph; the NVIDIA images never run on testing, so their testing cell is text), Requirements, Highlights, Install (with the Variants table and the Recipes list: every `ujust` recipe, one line each, no
step lists, the recipes explain themselves), then the closing block Contributing, License, Credits and About this repo
(personal project assisted by Claude, tested only on the owner's setup, not actively maintained beyond the owner's needs,
forks encouraged; its `### Fork it` heading is linked from `AGENTS.md`), disclaimer last. No design rationale, process
history, CI or branching internals, agent instructions or recipe step lists in it. American English throughout. Checked
by hand: no test reads the README (removed 2026-11-16, see "What the tests may assert").

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
- `build_files/build.sh` (log sections as `::group::`, see "Image build steps added 2026-11-14"): guard against secrets in `system_files`, rename the base recipe files `10-update.just` and
  `30-distrobox.just` to `*-base.just` (our files of the same names import them; a missing one fails the build), copy
  `system_files` (which overwrites the base's `15-luks.just`, `40-nvidia.just` and `50-akmods.just` with ours), fail if a
  `toggle-nvk` recipe is still installed, generate the
  container signature policy from `IMAGE_ORG`/`IMAGE_NAME`/`cosign.pub`, install packages, enable services.
- `system_files/`: files copied onto `/` (PAM, sysctl, firewalld, sudoers, Flatpak preinstall lists, `ujust` recipes).
- `Justfile` (repo root, not in the image): build and release recipes. `just check` runs `just --fmt --check`.
- `.github/workflows/`: `build-dx.yml` (the dx image: a thin caller with the triggers, concurrency, result check and publish, see "Input hashes and dx on testing"), `dx-image.yml` (the reusable plan/build/promote jobs, called by `build-dx.yml` and `build-nvidia-dx.yml`, 2026-11-16), `test.yml` (quick tests and secret scan on dev branches), `build.yml` (plan, build, smoke test, push, then a separate `sign` job in the `signing`
  environment), `require-testing-branch.yml` (details under "CI and
  signing flow").
- `config/`: `image.env` (IMAGE_NAME, REPO_NAME and the label values; the Justfile loads it with `set dotenv-path`, the workflows read it by path; renamed from the template's `image-template.env` on 2026-11-14) and `chunkah.env` (the chunkah pin). Both are image-build inputs (any path outside `docs/`, `tests/` and top-level `*.md` is). `docs/` holds `CONFIG-GUIDE.md` (moved from the root 2026-11-14); `artifacthub-repo.yml` (template stub) was deleted the same day.
- `githooks/pre-push`: gitleaks scan; enable with `just install-hooks`.

## Variant workflows (2026-11-17, Kevin: option (a), "fewer workflow files, each variant still its own run")

**Model (one sentence):** one parametrized caller per tier, one RUN per variant: `.github/workflows/build-variant.yml` (input `variant` dx|gx, the two required images) and `.github/workflows/build-extra.yml` (dispatch only, input `variant` dx-gx|nvidia-dx|nvidia-gx), both thin callers of the reusable `dx-image.yml`. Each variant keeps its own concurrency group (`build-<variant>-...`, `build-extra-<variant>`), `sign` job (`environment: signing`, in the caller), publish of its own `latest`, failure issue (`ci-failure-dx`, `ci-failure-gx`) and result, so one variant failing or being cancelled never blocks the other. The required names do not change: check run and commit status `Build dx and push image` and `Build gx and push image` (computed from `inputs.variant`; `Build <variant> (older commit)` and `Build <variant> (dry run)` for the non-tip and dry cases), run-name `<variant> <channel> <sha>`.

- **Two stages, because GitHub dispatches a workflow only from a file that exists on the default branch (`gh workflow run` answers HTTP 404 "not found on the default branch" for a new file, found 2026-11-17).** Stage 1 (this change) adds the two new files beside the old callers (`build-dx.yml`, `build-gx.yml`, `build-dx-gx.yml`, `build-nvidia-dx.yml`, `build-nvidia-gx.yml`), which still do the real work; nothing dispatches the new files; `build-extra.yml` has no `workflow_run` trigger yet (otherwise the old NVIDIA callers and the new file would both start after an NVIDIA build). After the promotion that puts them on `main`, stage 2 switches `build.yml` to ONE `dispatch_variant` job (matrix `variant: [dx, gx]`, `fail-fast: false`, replacing `dispatch_dx` and `dispatch_gx`) running `dispatch-variant.sh` (the renamed `dispatch-dx.sh`), adds the `fanout` job to `build-extra.yml`, deletes the five old callers and updates README (one badge for dx and gx, one for the extra variants), docs and zizmor ignores. Doing it in one step would 404 the testing dispatch and leave the promotion PR without the required `Build dx and push image` status.
- **Dry runs of the new files (possible only once they are on `main`).** Both files allow `-f dry_run=true` on any branch: `gh workflow run build-variant.yml --ref <branch> -f variant=dx -f channel=testing -f dry_run=true` (gx likewise), `gh workflow run build-extra.yml --ref <branch> -f variant=<dx-gx|nvidia-dx|nvidia-gx> -f dry_run=true`; the result job is then `Build <variant> (dry run)` and posts no status. Never dispatch them without `dry_run` in stage 1: they would share concurrency groups, tags and statuses with the old callers.
- **Input hashes.** `build-variant.yml` is in `is_variant_shared` (editing it rebuilds dx AND gx, never the default image); `build-extra.yml` is pipeline-only (editing it rebuilds nothing; a changed layer is picked up by the plan job's label comparison). Test: `tests/pipeline/inputs-hash.sh`.

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
  keys/ublue-os-brew-cosign.pub ghcr.io/ublue-os/brew@sha256:...` (the key is vendored, see `docs/signing-keys.md`) and only then
  writes tag and digest; `just brew-tags` lists the newest tags and the current pin. CI no longer resolves or verifies
  per build: the build job's "Check the brew image pin" step only logs
  `Brew image pinned: ...` (the record of what a build used; a malformed pin fails the build itself, the format regex check was removed 2026-11-16); the plan job output `brew_pin_changed` is true when the
  push changed `BREW_TAG`/`BREW_DIGEST` (or there is no usable before-commit: schedule, dispatch, new branch) and then the
  build job runs `cosign verify` on the pinned digest, so a hand-edited digest cannot ship unverified.
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

## Pin bumps (`bump-pins.yml`, one weekly workflow, ONE INDEPENDENT pull request PER PIN; 2026-11-16, Kevin: any subset can be merged in any order and the rest closed; it replaced the one combined weekly PR of the same day)

- **One workflow, one job per pin (a matrix, `fail-fast: false`, the only list of pins; `BUMP_PINS` is required by the script, no default; 2026-11-17), one PR per pin:** `.github/workflows/bump-pins.yml`, Monday 07:00 UTC plus `workflow_dispatch` (scheduled workflows run only from `main`, so the schedule starts after the first promotion). each job runs `.github/scripts/bump-weekly.sh` for its own pin (chunkah, brew, bins, bins-dx, bins-gx; five jobs dispatch `Test` on testing at once without colliding: the Test run is found by its title `Test of <sha>` and the check runs sit on the commit sha): it cuts the branch `bump/<pin>-YYYYMMDD` (`-2`, `-3` when the name exists: a new name instead of a force-push, which is never used) from current `testing`, runs `bump-run.sh <pin>` (the decision scripts per kind and the pin writers; a failing pin changes nothing and turns the run red, which `scripts/scheduled-runs.sh` reports, the other pins still go in), which makes ONE COMMIT (its message ends with the pin's table row: pin | from | to | what changed upstream | days the new value has existed), pushes the branch and opens its own PR `Bump <pin>: <from> to <to>` (at most 140 characters; the body: what changed, old to new, what it was verified with, what is not verified, the owner merges, the Generated-with line). The branches all start from `testing`, never from each other, and the pins are different lines (`config/chunkah.env`, the `BREW_*` lines and the `BINS_*` lines of the `Containerfile`, the `BINS_DX_*` lines of `variants/dx/Containerfile`, the `BINS_GX_*` lines of `variants/gx/Containerfile`), so the PRs do not conflict (the brew and bins pins share a FILE, different lines, which git merges). **At most one open bump PR per pin:** an open PR of the pin that already proposes the same value (its commit's `to`) stays and nothing new is made (idempotent reruns); an open PR with an OLDER value (upstream moved again) is closed with a comment and branch deletion once the new PR is open (no force-push is possible, so the update is a replacement); an open PR whose value `testing` already has (the pin equals upstream, or it was merged another way) is closed as stale. Nothing moved: no branch, no PR. A leftover `bump/weekly-*` PR from the combined design is not touched (close it by hand). **Drop a pin:** close its PR. **Rerun by hand:** `gh workflow run bump-pins.yml --ref testing` (also the recovery when a PR's checks are missing: the PR is replaced); `-f dry_run=true` from any branch prints, in the job summary, what it would open, keep or close per pin and pushes and opens nothing. A real run refuses to start from a checkout that is not `origin/testing`. Test: `tests/supply/bump-weekly.sh` (real git in temp repos, stub `gh` and writer).
- Pins bumped by bump-pins.yml: chunkah, brew, bins (the octarine-bins image digest, default image), bins-dx and bins-gx (the octarine-bins-dx and -gx image digests: the dx and gx package lists and installer, later their binaries). The `dev-packages` and `gaming-packages` kinds were replaced by these two on 2026-11-16 (the lists moved from octarine-images into octarine-bins). `datastore-images` is the other repository's image and still floats at its promoted `latest` (see "Dependency inventory" below); the scx, extest, Ghostty, Zig and builder pins moved to the octarine-bins repository on 2026-11-16 (its own bump).
- **The checks of a bump PR (2026-11-15).** The bump branch is pushed with `GITHUB_TOKEN`, so no push run starts. Dispatching `Test` on the branch did not help: a `workflow_dispatch` run is not part of a PR's status rollup (found on #137: check runs on the commit, `gh pr checks` empty, GraphQL `statusCheckRollup` null, PR BLOCKED on the required `test` and `secrets`; the same for a dispatch by a person), and check runs posted through the API join the commit's GitHub Actions suite when one exists and are not counted there. What counts: check runs of the Actions app on a commit that has no Actions suite (an experiment PR went BLOCKED to CLEAN). So `bump-weekly.sh` calls `bump-checks.sh <branch> <sha>` once per PR, for that PR's one commit (the Test run is named `Test of <sha>`, so parallel PRs never collide in its lookup): it dispatches `test.yml` on the `testing` ref with the input `ref=<sha>` (the run is named `Test of <sha>`, its jobs check that commit out; its suite belongs to testing's commit), waits for it and posts `test` and `secrets` on the bump commit with the real conclusions (marker title `Reported by bump-checks.sh`; a run that did not finish posts nothing). If the checks are missing, rerun the workflow: it makes a new branch and PR and closes the old one. Jobs need `checks: write`. No PAT, no app. The PRs are checked one after the other, and the one job has `timeout-minutes: 60` because it waits for each Test run.
- **brew** (new): the newest 8-digit dated tag of `ghcr.io/ublue-os/brew` (the rule of `just brew-bump`), only when newer than `ARG BREW_TAG`; `just brew-bump <tag>` IS the pin writer (digest and the cosign check against `keys/ublue-os-brew-cosign.pub`).
- **bins** (2026-11-16): `bump-run.sh bins` resolves `ghcr.io/redcodeworks/octarine-bins:latest` to a digest (`skopeo inspect --raw | sha256sum`); equal to `ARG BINS_DIGEST` in the Containerfile: nothing to bump; different: `just bins-bump latest` IS the pin writer (it verifies the digest with `keys/octarine-bins.pub`, reads the image's `org.opencontainers.image.version` label for `ARG BINS_TAG` and writes tag and digest; one commit, like brew). The PR body says: a new octarine-bins digest, verified with `keys/octarine-bins.pub`, and that the testing build of the merge is the FIRST OS build with those binaries (the installer's ldd, 32-bit, terminfo and file-conflict checks run there). Unverified on the real registry until the first bump after the first promotion in octarine-bins.
- **bins-dx and bins-gx** (2026-11-16, replacing dev-packages and gaming-packages): `bump-run.sh bins-dx|bins-gx` resolves `ghcr.io/redcodeworks/octarine-bins-dx:latest` (or `-gx`) to a digest (`skopeo inspect --raw | sha256sum`); equal to `ARG BINS_DX_DIGEST` in `variants/dx/Containerfile` (`BINS_GX_DIGEST` in `variants/gx/Containerfile`): nothing to bump; different: `cosign verify` with `keys/octarine-bins.pub` (retried), then the digest and the image's `org.opencontainers.image.version` label (`<date>-<sha7>`, for humans; no usable label fails the run) are written into `ARG BINS_DX_TAG`/`BINS_DX_DIGEST`; one commit, one PR, one independent PR per pin as for every kind. The writer is inline in `bump-run.sh` (no just recipe, so a bump never touches default-image inputs: the variant Containerfile is a variant input and its testing build is the first with the new lists). The pin covers the lists, the installer and the variant's binaries (none yet); the packages themselves still float through dnf at build time. The PR body says so. Test: `tests/supply/bump-bins-images.sh` (stub skopeo and cosign, real git).
- The datastore-images pin was removed on 2026-11-16 (item 15): the datastore bundle is fetched on demand by `ujust datastore-install`, see "Datastore containers". It floats at `latest` (nothing in the build uses it).
- Stay MANUAL by the owner's decision: the tool versions (cosign, just, gitleaks, zizmor in `setup-tool` and the workflows), the runner label, the repository variables and the signing key. `tests/supply/bump-weekly.sh` covers the orchestration and `tests/supply/bump-bins-images.sh` the bins-dx and bins-gx kinds (one body, run per kind); the other kinds have no test (cut 2026-11-16: sanity only); `bump-weekly.sh` has a dry run (`-f dry_run=true`).

### Dependency inventory (2026-11-16)

Rule (Kevin, revised 2026-11-16): "Anything that comes from another repository is pinned by digest and changes only through a bump PR Kevin approves (into `testing`, then the promotion PR); only the base image and the dnf installs float." Pinned that way: the brew image, chunkah, `octarine-bins`, `octarine-bins-dx` and `octarine-bins-gx`. Still floating at `latest` for now (decision pending): `datastore-images` of octarine-images.

| Dependency | Class | Treatment |
|---|---|---|
| `ghcr.io/ublue-os/silverblue-main:45` (and the repository variables `BASE_IMAGE`, `FEDORA_VERSION`) | base | floats at the tag, resolved to a digest once per run and verified with the Universal Blue key (`base-pin.sh`); no own soak |
| Fedora packages of the lists in the pinned octarine-bins, -dx and -gx images (required and optional) | dnf | float (live repositories at build time) |
| negativo17 `fedora-multimedia` (the `codecs` group), the base's akmods COPR | dnf | float with the base; `validate-repos.sh` allow-list |
| COPR or vendor repositories | dnf (external) | only the gx image uses one: the LizardByte COPR for Sunshine, at the exact version of `required-copr.txt` in the pinned `octarine-bins-gx` image, enabled for that one install and disabled again by the installer (the exact version is the pin; the COPR itself floats). Steam comes from negativo17 (`required-negativo17.txt`), not from RPM Fusion (see "gx image") |
| `ghcr.io/redcodeworks/octarine-bins` | other repository | pinned by digest (`ARG BINS_DIGEST` in the `Containerfile`, verified with `keys/octarine-bins.pub` on every build, recorded in the label `io.github.redcodeworks.octarine-os.binaries`), weekly bump PR (`bins` kind) |
| `ghcr.io/redcodeworks/octarine-bins-dx` (octarine-bins) | other repository | pinned by digest (`ARG BINS_DX_DIGEST` in `variants/dx/Containerfile`, verified on every dx build with `keys/octarine-bins.pub`, recorded in the label `io.github.redcodeworks.octarine-os.bins-dx`), weekly bump PR (`bins-dx` kind). The pin covers the lists and the installer (and later dx binaries); the packages float via dnf |
| `ghcr.io/redcodeworks/octarine-bins-gx` (octarine-bins) | other repository | pinned by digest (`ARG BINS_GX_DIGEST` in `variants/gx/Containerfile`, verified on every gx build with `keys/octarine-bins.pub`, recorded in the label `io.github.redcodeworks.octarine-os.bins-gx`), weekly bump PR (`bins-gx` kind). The pin covers the lists, the installer and the exact Sunshine version (and later gx binaries); the packages float via dnf |
| `ghcr.io/redcodeworks/datastore-images` (octarine-images) | owned | floats at `latest`, pulled at runtime by `ujust datastore-install` (container policy checks the signature); no build input |
| `octarine-os:latest` / `octarine-os-nvidia:latest` under the dx images | owned | the default image is handed over by DIGEST (the one the base build just published); the NVIDIA build reads `octarine-os:latest` |
| `ghcr.io/ublue-os/brew` | external | pinned by digest (`ARG BREW_DIGEST` in the `Containerfile`), weekly bump PR |
| `quay.io/coreos/chunkah` | external | pinned by digest (`config/chunkah.env`), weekly bump PR |
| `ghcr.io/ublue-os/akmods-nvidia-lts` (NVIDIA variant) | external | resolved per build to the digest of the tag for the base image's exact kernel (`nvidia-akmods-ref.sh`); floats with the base, cannot be pinned apart from the kernel |
| GitHub Actions (`uses:` by commit sha) | external | pinned, moved by Dependabot pull requests into `testing` |
| cosign, just (`setup-tool`), gitleaks, zizmor, the runner label `ubuntu-26.04`, vendored public keys in `keys/` | external | pinned (or a floating label) in the files, changed by hand |

Does not fit the rule as written: the akmods image (cannot be pinned); the tool versions and keys (pinned but not moved by the weekly bump PR; Dependabot is a second PR channel for Actions); the base floats; extest is built from the owner's fork, which is a plain mirror, so it is treated as external.

## Prebuilt binaries (the octarine-bins image)

**Model (2026-11-16, Kevin):** the OS image installs the octarine-bins image it pins by digest; octarine-bins builds, signs and promotes `latest`; the weekly bump proposes the new digest. The scx schedulers, the extest libraries and Ghostty are built in the separate repository `redcodeworks/octarine-bins` (sources, builder, workflows and their tests live there; this repository no longer has `binaries/`, `binaries.yml`, `binaries-*.sh`, `upstream-check.sh`, `ghostty-check.sh` or `bump-ghostty.sh`). That repository publishes the signed `FROM scratch` image `ghcr.io/redcodeworks/octarine-bins` with its OWN cosign key; `keys/octarine-bins.pub` is the vendored copy (its `cosign.pub`; this repository's own `cosign.pub` signs the OS images and is NOT used for it). nvidia and the dx and gx variants inherit the binaries of the default image; the dx and gx layers read their OWN pinned octarine-bins-dx / -gx image (package lists and installer, zero binary components so far, `BINARIES_REQUIRED=""`; since 2026-11-16, see "Package lists"), nvidia reads none.

- **The pin.** `ARG BINS_TAG` (the image's `<date>-<sha>` version, for humans), `ARG BINS_DIGEST` and `ARG BINS_IMAGE=ghcr.io/redcodeworks/octarine-bins:${BINS_TAG}@${BINS_DIGEST}` in the `Containerfile`, next to the brew pin (same style). `just bins-bump [tag]` (default `latest`) resolves the digest, runs `cosign verify --key keys/octarine-bins.pub`, reads the version label and writes tag and digest. The `build.yml` step "Verify the pinned binaries image" verifies the PINNED digest on every build (retried) and logs `Binaries image pinned: ...`; `just build` reads the digest from the Containerfile for the label `io.github.redcodeworks.octarine-os.binaries` (`octarine-bins@<digest>`, the exact binaries of the image, for a rollback) and passes no build argument. There is no `latest` read, no key or tree check and no `testing`-reads-`testing` branching for the binaries: a testing build with a bump PR tests the exact binaries before they can reach `main`, and the daily `main` build floats only on the base image and dnf. The pin is an ordinary image input (`inputs-hash.sh`), so a bump rebuilds the image.
- **Contract and layout changes.** The layout (`/binaries/COMPONENTS`, `<component>/`, `LICENSES/`, `scx/schedulers.tsv` with four tab separated fields, `ghostty/FILES`) is mirrored in octarine-bins's CLAUDE.md ("The image layout"). A layout change and the pin bump ship in ONE OS pull request: the installer accepts the new layout and the pin moves to an image that writes it. `tests/image/install-binaries.sh` runs the real installer against a fixture in the documented layout (the fixture lives in the test; no network).
- **Installation.** The build step bind-mounts the pinned image at `/binaries` (its `packages/` directory is the package lists, installed by `/binaries/packages/install.sh` from `build.sh` before this step; `install-binaries.sh` allows `packages/` at the top level, and for dx/gx accepts an EMPTY `COMPONENTS` when called with `BINARIES_REQUIRED=""`, the required-component list being per image: unset means `scx extest ghostty`); `build_files/install-binaries.sh` (called by `build.sh`; `BINARIES_ROOT` and `DESTDIR` exist for tests) reads `COMPONENTS` (its `required` list is `scx extest ghostty`: a missing, unknown or uninstallable component fails the build), checks that `schedulers.tsv` and `bin/` agree both ways (awk, four fields), then installs the schedulers to `/usr/bin/`, the manifest to `/usr/share/octarine-os/schedulers.tsv`, the extest libraries to `/usr/lib/extest/lib/libextest.so` and `lib64/libextest.so`, Ghostty's tree under `/usr` (never over a file the image already has; the terminfo entries the base already ships stay), and the license texts, `SOURCE` and `BUILDINFO` to `/usr/share/licenses/octarine-binaries/<component>/` (the path name is kept; it fails when the GPL or MIT text is missing). Nothing is enabled or started: no unit, no preset.
- **Runtime libraries.** Build dependencies never travel (FROM scratch), so after installing, in a real image build (empty `DESTDIR`; `BINARIES_CHECK_NEEDED=1` forces it in tests, `BINARIES_LDD` replaces ldd), every ELF file must find its libraries in THIS image: a 64-bit file must resolve with `ldd`, a 32-bit file (libextest in 32-bit Steam) may need only libc, libgcc_s, libm, libdl, libpthread, librt, ld-linux. A component that fails FAILS the build (add the package to `build.sh`).
- **Icon and desktop caches (2026-11-15, Kevin's VM: Ghostty needed an icon):** the base's `icon-theme.cache` and `/usr/share/icons/hicolor` share the normalized epoch mtime of an ostree image, so GTK trusts a STALE cache that lists no new icons; `install-binaries.sh` therefore runs `gtk-update-icon-cache -f -t /usr/share/icons/hicolor` (or the gtk4 tool) and `update-desktop-database` after installing Ghostty in the real build and warns when the cache does not list `com.mitchellh.ghostty`; the smoke test checks the 256x256 icon file and that the cache lists it.
- **Smoke test** (`default-smoke.sh`, run by `build.yml`): the manifest exists; per scheduler it is executable, `--version` runs, and `ldd` shows no `not found`; the extest libraries are executable and `file` shows a 32-bit and a 64-bit ELF; the GPL-2.0 and MIT texts and the `SOURCE` and `BUILDINFO` records ship.
- **Failure the owner sees.** A pinned digest that does not verify or cannot be pulled fails "Verify the pinned binaries image" (or the build): fix the pin through a bump PR, never by editing around the check. A new octarine-bins digest whose binaries do not install fails the testing build of the bump PR, which is where it should fail.
- **Fedora major upgrade.** Bump `src/builder.env` in octarine-bins FIRST (its builder must match `FEDORA_VERSION`), let it build and promote, then bump the pin here (`just bins-bump`) in the same PR as the `FEDORA_VERSION` testing build; binaries built for release N-1 may not link on N.
- **Token (bump).** Only the default `GITHUB_TOKEN` (see "The checks of a bump PR" above); the setting "Allow GitHub Actions to create and approve pull requests" must be on.
- **Unverified.** The first testing build of the PR that introduced the pin (image build with the pinned digest in CI), the `bins` bump kind against the real registry beyond a read-only check, that a scheduler loads on a real kernel (CI cannot load BPF), and the `$LIB` expansion inside Steam's Flatpak. The old package `ghcr.io/redcodeworks/octarine-binaries` and its tags are no longer read; deleting them is the owner's.
- **Undo.** Restore `binaries/` and `binaries.yml` from git history (pull request that introduced the pin), the `BINARIES_IMAGE` argument and `latest-ref.sh` step, and drop `BINS_*`, `keys/octarine-bins.pub` and the `bins` bump kind.

## sched_ext schedulers (`scx@`, `ujust scheduler`)

The seven shipped schedulers (`scx_rusty`, `scx_lavd`, `scx_cake`, `scx_bpfland`, `scx_cosmos`, `scx_flash`, `scx_p2dq`, sched-ext/scx v1.1.4,
built in the octarine-bins repository (`src/scx`), see "Prebuilt binaries"; Fedora's own old `scx_rusty` package is not used) are BPF schedulers that replace the
kernel's default (EEVDF) while loaded. EVERYTHING SHIPS OFF: no preset enables one (`00-octarine-scx.preset` says `disable scx@*.service`), none runs
after install; the owner decides default-on after a soak. Whatever fails, the machine stays on EEVDF. Adding a scheduler later = one line in
`src/scx/schedulers.tsv` in octarine-bins plus a new pin of its image; the registry, drop-ins, menus and tests derive from it.

- **Registry.** `build_files/gen-schedulers.sh` (called by `build.sh` after `install-binaries.sh`) reads `/usr/share/octarine-os/schedulers.tsv`
  (four tab-separated fields: name, `bin/<name>`, minimum kernel (EMPTY for all seven today), description up to 120 characters; read with
  `awk -F'\t'` or `cut -f`, never `IFS=$'\t' read`) and writes `/usr/share/octarine-os/schedulers.d/<instance>.conf` (`NAME`, `INSTANCE`, `BINARY`,
  `DESCRIPTION`, `MIN_KERNEL`, `FLAGS`; parsed with awk, never sourced). The **instance name is the scheduler name without `scx_`**: `rusty`, `lavd`, `cake`,
  `bpfland`, `cosmos`, `flash`, `p2dq` (it equals the scheduler's `sched_ext_ops` name, which `/sys/kernel/sched_ext/root/ops` shows). It also writes per
  instance `scx@<name>.service.d/10-conflicts.conf` (`Conflicts=` AND `After=` on every other instance, see "Switching between instances") and, only when the registry has a minimum kernel,
  `20-kernel.conf` (`ConditionKernelVersion=>=<min>`).
- **Unit** `system_files/usr/lib/systemd/system/scx@.service`: `Type=simple`, `ConditionPathExists=/sys/kernel/sched_ext`, `StartLimitIntervalSec=0`
  (user-triggered start/stop cycles never trip systemd's start limit), `Restart=on-failure`, `RestartSec=5`, `ExecCondition=` `scx-preflight %i`,
  `ExecStart=` `scx-run %i`, `ExecStartPost=` `scx-verify %i`, `[Install] WantedBy=multi-user.target`. No hardening directives, as in upstream's own
  `services/scx.service` (which has none either): loading a BPF scheduler needs root and a sandbox that blocks `bpf()` would stop it; whether stricter
  settings still load is UNVERIFIED. Helpers in `/usr/libexec/octarine-os/` (`scx-lib.sh`, `scx-preflight`, `scx-run`, `scx-verify`):
  `scx-preflight` refuses quietly (exit 1, the unit is skipped, not failed) when `/sys/kernel/btf/vmlinux` is missing or the marker
  `/var/lib/octarine-os/scx-disabled/<name>` holds the running `uname -r`; `scx-run` runs the registry's binary (must be `/usr/bin/scx_*`) with the
  registry's flags and a cleared environment; `scx-verify` waits up to 5 s until `/sys/kernel/sched_ext/state` is `enabled` and
  `/sys/kernel/sched_ext/root/ops` BELONGS to the instance (the root directory exists only while a scheduler is loaded). **The kernel reports the ops
  name with a version suffix, e.g. `rusty_1.1.4_x86_64_unknown_linux_gnu`, not the bare instance name** (first real start on nox, 2026-11-14: the busy
  rule read our own scheduler as foreign and failed the start): `scx_ops_instance` (scx-lib.sh), `active_instance` (gamemode-lib.sh) and
  `ops_inst`/`active_sched` (the recipe) match an instance when the string equals its name or starts with `<name>_`, longest match wins; a name that merely
  starts with the instance (`rustyfoo_1.0`) does not match. `tests/image/schedulers.sh` fails if a registry name is ever another one followed by `_`. Busy = enabled
  and the ops name is not this instance (another registered one or unknown): the start fails, nothing is counted.
  **libbpf's kernel config.** A scheduler with `CONFIG_*` externs (`.kconfig`) makes libbpf read the kernel config, and libbpf v1.7.0 (the one in the scx
  1.1.4 build, `bpf_object__read_kconfig_file`) tries only `/boot/config-<uname -r>` and `/proc/config.gz`. The image has neither (CONFIG_IKCONFIG off,
  the ostree /boot holds no config), only `/usr/lib/modules/<release>/config`, so such a scheduler failed with "failed to open system Kconfig" / EINVAL (scx_lavd,
  first real start). Static list (Tier 1, per scheduler): needs a config: lavd, bpfland, cosmos, flash, p2dq (`CONFIG_*`); cake has only `LINUX_KERNEL_VERSION`
  (libbpf fills that without a file); rusty has none. `scx-run` therefore runs every scheduler in a private mount namespace (`unshare -m`): tmpfs on /boot,
  `/boot/config-<release>` created and the image's config bound read-only onto it, then `env -i` and the binary; values and flags are positional parameters of
  `sh -c`, never interpolated; skipped when libbpf already finds a config, a warning and a plain start when the image's file is missing, exit 75 when a mount
  fails. Systemd mount properties (`TemporaryFileSystem=/boot` + `BindReadOnlyPaths=`) die with 226/NAMESPACE on the real machine and `%v` is not expanded in
  them: do not use them. The Tier 1 check lists the `CONFIG_*` externs and FAILS the build when a scheduler has some and `scx-run` lacks the mechanism.
  **Restart rule.** `Restart=on-failure` is for a scheduler that was active and then crashed. `scx-run` stays the main process (child + wait), and exits 75
  (`RestartPreventExitStatus=75`) when the scheduler ended without `scx-verify` having left `/run/octarine-os/active-<INVOCATION_ID>` (a load failure, or a start
  that verify judged failed and systemd stopped); a stop of an active scheduler exits 0, a crash keeps its status. Tested on systemd 262: a main process exiting 75
  stops the restart although ExecStartPost failed, exit 1 restarts, and the unit-only options (`Restart=on-abnormal`, `RestartPreventExitStatus=SIGTERM`) also stop a restart in a simulation, but depend on how the real
  binary dies when systemd stops it (unverified), whereas an explicit exit status does not. One user attempt is now ONE counted failure (before: three in sixteen seconds, so the marker
  appeared after one game launch). The GameMode hook's failure message names the marker, the counter and `journalctl -u scx@NAME` when a marker of this kernel
  exists; `ujust scheduler --status` shows the counters and the exact removal command, `--boot` asks before removing marker and counter.
- **Safeguards (each tested in `tests/image/schedulers.sh`).** (a) The polkit rule is GENERATED at image build: `build_files/gen-schedulers.sh` fills the template `usr/share/octarine-os/polkit/50-octarine-scx.rules.in` with the exact alternation of the registry instance names and writes `usr/share/polkit-1/rules.d/50-octarine-scx.rules`. It grants `YES` for
  `org.freedesktop.systemd1.manage-units` ONLY when the `unit` detail matches `^scx@(rusty|lavd|cake|bpfland|cosmos|flash|p2dq)\.service$` (the real instances, nothing else: not `scx@evil`, not `scx@rusty2`, not a hyphenated or uppercase name) AND the `verb` detail is exactly `start` or
  `stop` (not `restart`, `try-restart`, `reload-or-restart`, `kill`, `reset-failed` or `set-property`: the hooks and the recipe only use start and stop, an in-place switch is a start of another instance and `Conflicts=` stops the running one) AND `subject.local && subject.active && subject.isInGroup("wheel")`; a request without those details never matches; nothing else is granted (not
  enable/disable). The test runs the GENERATED rule (built from a fixture registry) in node against simulated actions: each real name for start and stop (restart matches for none), the unregistered and malformed names, other verbs, other subjects (`nodejs` is installed in the `test` job), and shows that one more manifest line adds the instance to the rule. The rule is in `/usr/share`, not `/etc`, so
  the base's `/etc/polkit-1/rules.d` attributes are not touched. (b) The instance name is attacker-chosen: all three helpers match it EXACTLY against the registry
  files (`^[a-z0-9][a-z0-9_]*$` AND a file of that name) before any use and exit 2 for anything else (`../x`, empty, spaces, case, an unregistered name); no path is
  built from an unvalidated name. (c) Root units read only the root-owned registry, `/usr` binaries, sysfs and `/var/lib/octarine-os`; flags come from the registry only;
  no user file or environment. The per-user file is read ONLY by the GameMode hooks (run as the user). (d) `scx-verify` is the crash-loop protection: the marker is written ONLY after a real load
  failure (sched_ext not enabled at all after the timeout), counted in the root-owned `/var/lib/octarine-os/scx-failures/<name>` (never above the threshold), at the third consecutive verified failure; a success removes
  the count and the marker; a stop during the wait (SIGTERM) counts nothing. When sched_ext is enabled but ANOTHER scheduler holds it (for example the user ran `systemctl start --job-mode=ignore-dependencies scx@B.service` while `scx@A` runs, which skips the `Conflicts=` stop), the start fails as "busy" and counts nothing and writes no marker, so that trick cannot disable a scheduler for the kernel. (e) Residual risk in plain words (after the hardening: the rule only matches real instance names, only start and stop are granted, and a busy sched_ext is never counted as a failure): any process running as the logged-in wheel user in an active local
  session can switch among the shipped schedulers without a prompt (an availability and performance risk, not code execution as root, because the unit files, binaries and flags
  are root-owned), the same trust class as the existing tuned rule. Side doors, accepted on purpose: (1) systemd sends the verbs `stop` and `start` for FreezeUnit and ThawUnit too, so the user can also freeze and thaw the cgroup of an scx unit (a short userspace stall, then the sched_ext watchdog ejects the scheduler back to EEVDF). (2) `subject.local` does not stop same-user code that arrives remotely: a process started by `systemd-run --user` or a user unit from an SSH login leaves the session cgroup and takes polkit's Display-session fallback, so it counts as local and active. (3) `StartTransientUnit` with a caller-chosen name `scx@x.service` also matches the rule (polkit sees the verb `start` and that unit name); the ONLY thing that stops a user from creating a transient ROOT unit with an arbitrary `ExecStart` under such a name is systemd's refusal "Unit already loaded or has a fragment file" because the template `usr/lib/systemd/system/scx@.service` exists. The rule must never be shipped without that template: `gen-schedulers.sh` refuses to generate it, and a test and the image smoke test check the file (do not rename or drop it). (4) `Restart=on-failure` with `StartLimitIntervalSec=0` retries every 5 s until the failure marker trips, which the three-verified-failure rule bounds. Comparison: stock Fedora asks for administrator authentication for every unit action; this rule is smaller than the existing `libvirt` group (`org.libvirt.unix.manage`, root-equivalent) and the `gamemode` group exceptions. No systemd sandbox hardening is added to `scx@.service` (loading BPF under it is unverified). UNVERIFIED: whether schedulers expose a stats socket and who can read it. From the scx source (`scx_stats`
  server, v1.1.4) the default is a Unix socket `/var/run/scx/root/stats` created by the root-run scheduler with its umask, so with the usual 022 only root could connect;
  not checked on a running scheduler.
- **GameMode hooks.** `/usr/libexec/octarine-os/gamemode-start` and `gamemode-end` (library `gamemode-lib.sh`) are the `[custom] start=` and `end=` of
  `usr/share/octarine-os/gamemode.ini` (installed as `~/.config/gamemode.ini` by `ujust gaming-setup gamemode`; the image's own `/etc/gamemode.ini` has no `[custom]` on
  purpose), with `script_timeout=20`. They run the two tuned commands as before (`latency-performance` on start, `balanced` on end), independent steps, side by side with the
  scheduler step. The user's choice is `GAMEMODE_SCHED=skip|none|<name>` in `~/.config/octarine-os/scheduler.conf` (parsed, validated against the registry; absent or invalid means skip): `skip` does nothing; a name runs
  `systemctl start scx@<name>.service` and checks `/sys/kernel/sched_ext/root/ops`; `none` stops the active scheduler; `end` restores the boot choice (the instance `systemctl is-enabled` reports
  enabled, else the default scheduler) only when `start` switched something (marker in `$XDG_RUNTIME_DIR/octarine-scx`). If the chosen scheduler fails, the boot choice is restored. A lock serializes overlapping
  games. Each hook always exits 0, logs with `logger -t octarine-scx`, bounds every step, and sends `notify-send` on failure. Kevin's own `~/.config/gamemode.ini` overrides the image file and must be updated by hand.
- **Failure mode and recovery.** If `gamemoded` dies or crashes during a game, `gamemode-end` never runs and the game-time scheduler stays active. `ujust scheduler --restore` puts the machine back on the boot choice (start the enabled instance and stop any other; or stop every running one when none is enabled; the polkit rule applies, otherwise the same command runs once through sudo, never retried; `--no` prints the plan; idempotent), `--status` points at it when the running scheduler differs from the boot choice (it asks `gamemoded -s` with a 2 s timeout and says when it cannot), and `gamemode-start` repairs a stale state itself before it switches (GameMode calls start only for the first game): when a scheduler runs that is neither the boot choice nor the requested one, it restores the boot choice first.
- **Switching between instances (fixed 2026-11-14).** Only one scheduler can be loaded, and a stop returns before the kernel has finished unregistering the old one. The first design had `Conflicts=` only, so `systemctl start scx@B` ran while `scx@A` was still stopping: scx_B printed `another sched_ext scheduler is already running`, `scx-run` exited 75 and the machine stayed on the kernel default (seen twice at GameMode end, lavd -> rusty; the start direction rusty -> lavd happened to work). The earlier "verified working 2026-11-14" covered the START direction only. Two layers now: (1) the generated drop-in adds `After=` on the same list as `Conflicts=`, so systemd finishes the old instance's stop (its main process exits after unregistering) before starting the new one; verified on this machine's systemd with two transient user units that conflict with and are ordered after each other (the start waited for the other's 3 s stop; no ordering cycle). Caveat: stopping TWO instances in one transaction (`systemctl stop scx@a scx@b`) is an ordering cycle and fails ("Transaction order is cyclic"); stop them one at a time, as every recipe and hook does. (2) `ExecStartPre=scx-wait-idle %i` waits up to `OCTARINE_SCX_IDLE_SECONDS` (default 8, inside `TimeoutStartSec=20`) until `/sys/kernel/sched_ext/state` reads `disabled`, covering what ordering cannot see (a scheduler started by hand, `--job-mode=ignore-dependencies`). It always exits 0: if sched_ext stays held the start goes on and fails visibly as before (exit 75, scx-verify "busy", nothing counted). It is ExecStartPre, not part of `scx-run`, because `ExecStartPost` (scx-verify, 5 s) starts as soon as `scx-run` forks and a wait inside `scx-run` would eat the verify budget. Tests: `tests/image/schedulers.sh` (After= in every drop-in, the unit line, `scx-wait-idle` with a stubbed sysfs that still reads `enabled` and flips to `disabled`). UNVERIFIED until a booted GameMode run: the lavd -> rusty restore at GameMode end.
- **Recipe `ujust scheduler`** (group Setup, above `toolbox`, not part of `hardware-setup`): step 1 scheduler at boot (None plus every registry entry, current first; `sudo -v` once, then `sudo systemctl enable --now scx@NAME.service` FIRST and the enabled other instance is disabled only after the new one is verified running (`systemctl is-active` plus `/sys/kernel/sched_ext/state` and `root/ops`, waited up to `SCHEDULER_WAIT` seconds, default 5); "already set" means enabled AND running; a scheduler that does not run is reported FAILED with the reason (no BTF, the crash-loop marker of this kernel, or the last journal lines), the new instance is disabled again if this run enabled it and the old one is started again, and a marker is removed (`sudo rm -- /var/lib/octarine-os/scx-disabled/NAME`) only when the user confirms (default no; never under `--yes`); sharing one security-key touch between the sudo commands is NOT guaranteed (it depends on the sudoers credential cache); never retried; exact command printed on failure), step 2 scheduler while GameMode is active (Skip, None, entries; writes `scheduler.conf`, no sudo). Every option shows its
  description (menu text shortened to 76 characters; `--list` shows the full text). Flags `--boot`, `--gamemode`, `--status`, `--list`, `--restore`, `--yes`, `--no`, `-h`; unknown name or option exits 2; refuses root; "not applicable" without
  `/sys/kernel/sched_ext`. Test hooks `SCHEDULER_REGISTRY|SYSFS|STATE_DIR|USER_CONF|WAIT|BTF|KERNEL`.
- **Tier 1 compatibility check** (`.github/scripts/scx-kernel-check.py`, a step after the smoke test in `build.yml`, run inside the built image; the dx and NVIDIA variants inherit the same kernel and the
  schedulers, so they need none). FEASIBLE and built: the image's `/usr/lib/modules/<kver>/vmlinuz` is an x86 bzImage whose payload offset and length are in the setup header (zstd on Fedora 45); decompressed, the vmlinux has a
  `.BTF` section (159774 types on 7.2.15) which the script parses itself (no bpftool or pahole needed), plus `config` and `System.map` next to it. It checks `CONFIG_SCHED_CLASS_EXT`, `CONFIG_BPF_SYSCALL` and
  `CONFIG_DEBUG_INFO_BTF` are `y`; for each scheduler binary it extracts the embedded BPF object (an EM_BPF ELF inside the Rust binary) and requires that every REQUIRED import (undefined, non-weak ELF symbols; weak
  ones are the scx compat layer's optional kfuncs and are only notes; `CONFIG_*` and `LINUX_KERNEL_VERSION` are libbpf's own `.kconfig` externs, checked against the kernel config) exists in the kernel BTF (functions, variables) or `System.map`,
  and that every `struct sched_ext_ops` member the object sets (found through the `.struct_ops*` relocations and the object's own BTF) exists in the kernel's `struct sched_ext_ops`. Run on 2026-11-13 by hand against
  the 7.2.15 kernel of the image and the seven v1.1.4 binaries: all pass. A failure fails the build, which blocks promoting it. If the kernel image's BTF cannot be read the comparison is skipped with a warning (the config part
  still counts). It does NOT prove the verifier accepts the programs, that a member's meaning is unchanged, or that the userspace side works. Tests: `tests/scx-kernel-check.sh` (synthetic kernel and objects).
- **Smoke test** (both build workflows): the template, the polkit rule and the helpers exist, the registry has one file per manifest line with a conflicts drop-in each, and nothing enables a scheduler.
- **Unverified.** Loading any scheduler on the shipped kernel (only a real machine can), the live switch during a game, SELinux and kernel lockdown effects on loading, the stats socket permissions, the polkit rule
  in a real session (only simulated), and whether `systemctl start` as the user really needs no prompt with the rule installed. The GameMode hooks run from a systemd user service: confirm polkit treats that as local and active, else the hooks need a different subject condition; test with a real GameMode run and `systemd-run --user --pipe systemctl start scx@rusty.service`. Also unverified on a real machine: that a `StartTransientUnit` named `scx@x.service` (for example with `systemd-run --user`'s system-bus counterpart through `busctl`) returns "already loaded"; each scheduler loading under SELinux (the units probably run as `unconfined_service_t`) and under kernel lockdown=integrity; the stats socket mode; the sched_ext watchdog timeout; whether a Flatpak with system-bus access can match the rule; and a `gamemoded`-launched `systemctl start` getting YES.
- **Undo.** `ujust scheduler --boot none --gamemode skip`; remove the units, helpers, rule, preset, `gen-schedulers.sh` and the recipe.

## Datastore containers (dx image only, opt-in, a bundle fetched on demand; item 15, 2026-11-16)

The dx image ships NO datastore unit, image list, helper or pin (removed 2026-11-16; Kevin decided on 2026-11-15 that the services stay Quadlets but leave the image). The Quadlets, their
render step, the secrets, pin, update and backup logic and their tests live in the octarine-images repository (`datastore-images/`), published as the signed `FROM scratch` image
`ghcr.io/redcodeworks/datastore-images` (layout: `/bin/datastore`, `/lib/datastore.sh`, `/lib/render.sh`, `/quadlets/*`, `/images.txt`, `/README`). This repository carries only the thin recipes and the trust.

- **Recipes** (dx file `variants/dx/system_files/usr/share/ublue-os/just/72-octarine-datastore.just`, imported by `dx.sh`, group Setup, all refuse root): `ujust datastore-install [--digest sha256:...]` pulls
  `ghcr.io/redcodeworks/datastore-images:latest` (`podman pull`, so the container policy checks the signature), `podman create` + `podman export | tar -x` into a temporary directory next to
  `~/.local/share/octarine-os/datastore`, refuses a bundle without `bin/datastore` (the old list-only image: it says so and changes nothing), swaps the directory in (the old one is moved away, restored if the move fails, removed afterwards: never half-extracted),
  then runs `bin/datastore install` (renders the units into `~/.config/containers/systemd`, which beats `/usr/share/containers/systemd/users`, so an older image's baked units and user copies keep working; volumes and secrets stay). `ujust datastore ARGS` and `ujust datastore-setup ARGS` delegate to `bin/datastore ARGS` and `bin/datastore setup ARGS`
  with `DATASTORE_UJUST=1` (its messages then name the ujust recipes); without the bundle they say `Run: ujust datastore-install`. `ujust datastore uninstall` removes the units. Test overrides: `DATASTORE_BUNDLE_REF`, `DATASTORE_BUNDLE_DIR`.
- **Trust (container policy on the machine, not cosign).** `variants/dx/dx.sh` (block `datastore bundle signature policy`, same form as the policy block of `build.sh`) installs `keys/redcodeworks-toolbox-cosign.pub` as
  `/etc/pki/containers/redcodeworks-toolbox.pub`, adds a `sigstoreSigned` rule with `matchRepository` for the scope `ghcr.io/redcodeworks/datastore-images` to `/etc/containers/policy.json` (the catch-all stays last) and
  `/etc/containers/registries.d/redcodeworks-datastore-images.yaml` with `use-sigstore-attachments: true` (the org-wide registries.d entry of `build.sh` already covers the path by prefix; the explicit file keeps the dx image independent of it). The key reaches
  `dx.sh` through the `ctx` stage of `variants/dx/Containerfile`. Verified by toolbox-project with skopeo and podman against the published image: the right key is accepted, a wrong key and a missing registries.d entry are rejected.
- **Tests.** `tests/datastore-recipe.sh` (stub podman: the pull, create, export and extract path, `--digest`, the old-bundle message, atomic replace, root refusal, passthrough with `DATASTORE_UJUST=1`), `tests/dx-image.sh` (deleted 2026-11-16; it checked workflow text; the policy block run on a copy of the policy; the smoke script's checks of
  the rule, the key and registries.d; nothing datastore-related left in the dx inputs).
- **Datastore box (added 2026-11-16, beside the Quadlet recipes, which are unchanged).** Model: ONE distrobox with its own systemd running PostgreSQL 17, Valkey, SeaweedFS and Kafka on the host's `lakehouse` network under the aliases pgsql, postgresql, valkey, seaweedfs, kafka; the image `ghcr.io/redcodeworks/datastore` and its `datastore` command come from octarine-images (`datastore/`). Here: dx file `variants/dx/system_files/usr/share/ublue-os/just/73-octarine-datastore-box.just` (group `Datastore box`, imported by `dx.sh` and by the `ojust` root justfile): `datastore-box-create` (podman network step, then `distrobox assemble create --file`, no-op when the container exists) and `datastore-box VERB ARGS` (a whitelist of verbs, then `distrobox enter datastore -- datastore VERB ARGS`; a missing box says `Run: ujust datastore-box-create`). The assemble file is `variants/dx/system_files/usr/share/octarine-os/datastore/datastore.ini`: deliberately NOT in `/usr/share/ublue-os/distrobox`, because `ujust toolbox` lists every .ini there and would create the box without the network. `dx.sh` adds a second `sigstoreSigned` rule (scope `ghcr.io/redcodeworks/datastore`, same toolbox key, `matchRepository`) and `registries.d/redcodeworks-datastore.yaml`; only dx needs it (the box recipes are dx only; the default image's policy lists only the seven octarine-os repositories, its catch-all and the org-wide registries.d entry stay). Checked here: the `.ini` keys against distrobox 1.8.2.5 (`assemble create --dry-run` shows `--network lakehouse`, the aliases and the ports, `--init`, and no `--network host`). Tests: `tests/recipes/datastore-box.sh` (stub podman and distrobox: network before assemble, verbs map to the box command, missing box, unknown verb); dx-smoke asserts both policy rules and the shipped files. Cutover from the Quadlets (backup, stop pods, create, setup, restore, copy directories, `secrets export --replace`) is by hand and documented in `docs/image-variants.md`; not tested against real data, nor with a real image pull.
- **Sequence.** The `latest` tag of the bundle pointed at the old list-only image until the promotion PR (#23) of the repository now called octarine-images (then fedora-toolbox) merged: the promotion PR of this change must not merge before it (until then use `--digest` or the `testing` tag).
- Removed with it: the Containerfile ARGs, stage and bind mount, the image label, the pin check steps of both dx workflows, the `datastore-images` entry of `bump-pins.yml`, `bump-pin.sh` and `bump-run.sh`, `just datastore-images-bump`, `tests/datastore.sh` and its fixture. The dx build pins and verifies only the dev-packages list.

## virthost-setup and wake-on-lan

`ujust virthost-setup` (dx image only, `variants/dx/system_files/usr/share/ublue-os/just/75-octarine-virthost.just`, imported by `dx.sh`, group Setup) turns a dx machine into a KVM/libvirt host; it is the single implementation. `ujust dev --only libvirt` delegates to `virthost-setup --only daemons,connection` (the old libvirt code and its tests are gone; under `--yes` the step still runs only when named); the hardware-setup `virtualization` step is removed and its `iommu` entry only delegates to `virthost-setup --only iommu`. Checklist (menu through `menu.sh`), flags `--yes`, `--no` (plan only), `--only`, `--list`, `--image-dir`, `--nic`, `--bridge`, `--virtio stable|latest`, `--pool`, `--force`, `--yes-remote`, `-h`; refuses root; sudo only where named, one command per call, never retried, the exact command printed on failure. `--yes` runs check, daemons, connection, image-dir, virtio and libvirt-network, never iommu or bridge (name those). Steps and the commands they run:

- **check** (no sudo): `vmx`/`svm` in cpuinfo, `/dev/kvm`, `kvm` modules, `virt-host-validate qemu` summarized (the IOMMU warning points at the iommu step, the AMD Secure Guest line is informational; no flag: "enable VT-x or SVM in the UEFI").
- **daemons**: verifies the modular sockets (`virtqemud`, `virtnetworkd`, `virtstoraged`, `virtnodedevd`, `virtsecretd`, `virtnwfilterd`, each plain, `-ro`, `-admin`) with `systemctl is-enabled`; `sudo systemctl enable --now <missing>`; an enabled `libvirtd.socket` or `libvirtd.service` is disabled (it excludes socket activation of the modular daemons) and never enabled. `virtproxyd` and `virtinterfaced` are left alone.
- **iommu** (reboot): CPU vendor from cpuinfo; AMD `iommu=pt`; Intel `intel_iommu=on iommu=pt` (the Fedora kernel does not enable the Intel IOMMU by default, checked on the owner's kernel config; AMD's is on); only shown when an IOMMU exists (`/sys/class/iommu` or AMD-Vi/DMAR in `dmesg`, else "enable VT-d or AMD-Vi in the UEFI"); `sudo rpm-ostree kargs --append-if-missing=<arg>` once; "already set" from `/proc/cmdline` or `rpm-ostree kargs`; undo `--delete-if-present=<each>` and reboot. `iommu=pt` matters only for device passthrough. No image ships a kernel argument.
- **connection**: `sudo usermod -aG libvirt $USER` and `uri_default = "qemu:///system"` in `~/.config/libvirt/libvirt.conf` (backup first when it differs, other lines kept; never `LIBVIRT_DEFAULT_URI` in a shell file); log in again.
- **image-dir**: default `/var/lib/libvirt/images` or `--image-dir DIR`; `setfacl -m u:$USER:rwx` plus the default ACL (`-d`), no recursion and no `-b`; for a custom directory also `mkdir -p`, `setfacl -m u:qemu:x` on each parent that lacks it, `semanage fcontext -a -t virt_image_t 'DIR(/.*)?'` plus `restorecon -R` (fallback `chcon -R -t virt_image_t`, said not to survive a relabel), and with `--pool NAME` a libvirt dir pool (`pool-define-as`, `pool-build`, `pool-start`, `pool-autostart` through the libvirt group). UNVERIFIED: qemu really opening an image in a custom directory with that label.
- **virtio** (no sudo): `curl -fL --proto =https --proto-redir =https --retry 3 -C -` of the fedorapeople `stable-virtio` link (`latest-virtio` with `--virtio latest`) into the image directory as a `.part` file, renamed to the versioned name from the final URL, a `virtio-win.iso` symlink, a size sanity check, and the sha256 recorded in `<file>.sha256`: no checksum or signature is published, so nothing is verified and the output says so; an existing `virtio-win*.iso` is skipped (`--force`); offline prints the URL to fetch by hand. No RPM or repository is added.
- **bridge** (network blip, asks first, refused over SSH without `--yes-remote`): NetworkManager profiles only, current syntax: `nmcli connection add type bridge con-name br0 ifname br0 bridge.stp no connection.autoconnect-ports yes ipv4.method auto ipv6.method auto`, `nmcli connection add type ethernet con-name br0-<nic> ifname <nic> connection.port-type bridge connection.controller br0`, the old profile `connection.autoconnect no` (kept, not deleted), then `connection up br0` and `up br0-<nic>`; the NIC is the wired device with the default route (or `--nic`; several candidates or none: the list is printed; Wi-Fi only: refused, bridging does not work in station mode); `br0` plus a `br0-<nic>` profile present means already done (the owner's layout); undo printed before applying. UNVERIFIED: the takeover on a live LAN; the `cloned-mac-address` behavior of NetworkManager and whether GNOME Settings lists the bridge (nothing found; it is visible in `nmcli` and `nm-connection-editor`).
- **libvirt-network**: `virsh -c qemu:///system net-define` of `<network><name>nwbridge</name><forward mode='bridge'/><bridge name='br0'/></network>` from a temp file, `net-start`, `net-autostart`; skipped when it exists or when the host bridge is missing; the default NAT network is untouched.

Not included, by decision: a TuneD profile, package installation (dx ships the set), Wi-Fi bridging, spice and nested virtualization.

`ujust wake-on-lan [--yes|--no|--status|--off] [--nic IFACE]` (default image too, `60-custom.just` above `toolbox`) and the hardware-setup step `wake-on-lan` (which only delegates to it, shown only when the wired NIC reports `Supports Wake-on` with `g` in `ethtool`, or when `ethtool` cannot be read as the user and the sysfs `power/wakeup` file exists): the NIC is the default-route device, or the bridge's physical port when that device is a bridge, and the setting goes on the profile that is ACTIVE on the physical device (the port profile `br0-<nic>`, not the bridge profile); `sudo nmcli connection modify "<profile>" 802-3-ethernet.wake-on-lan magic` then `sudo nmcli device reapply <nic>` (`--off` sets `ignore`); idempotent; prints the MAC, the BIOS or UEFI reminder (Wake on LAN or Power On By PCI-E, ErP or EuP off) and that only the OS side is configured and the wake test is the user's (`wakeonlan <MAC>` or `etherwake`). Detection when `ethtool` cannot be read (found on nox 2026-11-13: as a normal user `ethtool enp8s0` prints `netlink error: Operation not permitted` and no `Supports Wake-on` line): that is "support unknown", NOT "unsupported". Unprivileged evidence decides: the sysfs `power/wakeup` file of the NIC or an NM value `magic` on its port profile makes the step "available (support not readable without root: `sudo ethtool NIC` shows it)"; with neither the step is hidden. The apply step then runs ONE `sudo ethtool NIC` (read only, shown in the plan, never retried, the exact command printed on failure) and writes only when the output shows `g`; `--list`, `--status` and `--no` never use sudo; an already-set `magic` is "done" without any sudo; `--off` needs no read. The `nmcli` property value table is from blog sources and unverified; some drivers may reset the setting at shutdown (not verified).

Tests: `tests/virthost-setup.sh` (every step fresh, done and failing; Intel and AMD; NIC detection; nox bridge layout; SSH, Wi-Fi and root refusals; ACL, SELinux and pool; virtio download, existing, forced, offline; `nwbridge`; Wake-on-LAN with and without a bridge), `tests/recipes/hardware-setup.sh`, `tests/dev-setup.sh`. Only a real machine can verify: the bridge takeover, qemu with a custom directory and its label, WoL waking the machine, the group re-login, and the virtio download from a network that blocks scripts.

## Image build steps added 2026-11-14 (repository validation, compilers, log groups)

Compared with Bluefin's `build_files/` (shared/validate-repos.sh, base/04-packages.sh, shared/clean-stage.sh); the owner approved three items.

- **Repository validation** (`build_files/validate-repos.sh`, run by `build.sh`, `dx.sh` and `nvidia.sh` after the last install and before `final-cleanup.sh`; the dx and NVIDIA `Containerfile`s copy it into their `ctx`). It FAILS the build when a repository other than the base's is enabled.
  An ALLOW-LIST, not Bluefin's deny-list, because the base legitimately enables several: read from `dnf5 repolist --enabled` in a container of the testing image on 2026-11-14 (Fedora 45 base `silverblue-main`): `fedora`, `updates`, `updates-archive`
  (Fedora's own, in `/usr/share/dnf5/repos.d` on Fedora 45), `fedora-cisco-openh264` (Fedora's file), `fedora-multimedia` (negativo17; its file says `enabled=0`, the base enables it through `/etc/dnf/repos.override.d/99-config_manager.repo`, so a check of the `.repo` files alone
  would be wrong both ways) and the akmods COPR `copr:copr.fedorainfracloud.org:ublue-os:akmods`. No RPM Fusion repository is installed in the base. Two sources are compared with the list: dnf5's own enabled list (applies the override directory) and every `[section]` with
  `enabled=1` in `/etc/yum.repos.d`, `/usr/share/dnf5/repos.d` and `/etc/dnf/repos.override.d`; a missing directory is fine. A new enabled id fails with its name; fix it at the step that added it (`dnf5 config-manager setopt <id>.enabled=0`) or, when the base
  meant it, add the id to `ALLOWED`. The NVIDIA layer's `nvidia-install.sh` (akmods, read 2026-11-14) re-enables `fedora-multimedia` and disables the cisco, nvidia and staging repositories itself, so it ends inside the list (UNVERIFIED until the next NVIDIA build).
  Tests: `tests/image/validate-repos.sh` (stub dnf5 and directories).
- **Compilers on the default image** (reverses the earlier rule that the image has none; the owner, 2026-11-14): `gcc gcc-c++ make binutils` are in `required-fedora.txt` of the octarine-bins image (Fedora vendor, a missing name fails the build) and in the required list of both smoke tests
  (`build.yml`). `binutils` is already in the base and a dependency of gcc; it is named so it stays. Measured with `dnf5 install --assumeno` on the testing image: 7 packages, 221 MiB installed (70 MiB download): gcc 121.8, gcc-c++ 46.8,
  libstdc++-devel 41.3, kernel-headers 7.1 (surprising on a non-dev image, a gcc dependency through glibc-devel), glibc-devel 2.3, make 1.8, libxcrypt-devel 0.03 MiB. dx and the NVIDIA images inherit them; nothing in `variants/dx` listed any of them, so nothing was removed there.
  The step `Compiler smoke test` (`.github/scripts/compiler-smoke.sh`, mounted into the built image by both workflows) compiles, links and runs a C and a C++ program, links through `ld` (`-fuse-ld=bfd`), runs `make` and assembles, links (`ld`) and runs a tiny program (`as`, `ar`).
  Tests: `tests/compilers.sh` (the lists agree, the script and its wiring). Still absent from the default image: clang, cmake, ninja, meson, gdb, the development-tools group and `-devel` libraries.
- **One smoke script for the default image (2026-11-15, item 14).** The in-image smoke test of `build.yml` is `.github/scripts/default-smoke.sh` (mounted into the built image and run with bash; env `REF`, `BASE_TAG`): one copy, no drift test needed. `tests/check-call-shape.sh` still guards joined `check "a" "b"` strings. `check` runs its command in a subshell: an `exit 1` inside a command (the `for ... || exit 1` forms) used to end the whole script silently at the first failure, with no FAIL line; now every failure is listed. To try the script by hand against a pulled image: `podman run --rm -v <copy of the script>:/default-smoke.sh:ro,z -e REF=... -e BASE_TAG=45 -e VERSION_RE=... <image> bash /default-smoke.sh` (older images fail the checks they predate). The default-enabled extensions must each have a directory in the image or the build must have recorded a missing optional package. Dropped as pure restatements: checks that `build.sh` already asserts during the build (PRETTY_NAME, IMAGE_ID, the plymouth theme file and selection, zsh in `/etc/shells` and not the useradd default), the sudo timeout literal, file-exists checks of files that tests/ read from the tree, and the dconf mtime comparison (the chunkah rechunk normalizes mtimes: the compiled database must hold the keys instead). The iommu check is one assertion: no `kargs.d` file mentions iommu.
- **Grouped build logs.** Every section of `build.sh`, `dx.sh` and `nvidia.sh` and each of `install-binaries.sh`, `gen-schedulers.sh`, `final-cleanup.sh` and `validate-repos.sh` prints `::group::<name>` ... `::endgroup::` (folded in the GitHub Actions log; plain text elsewhere, and
  `just build` output is only decorated). GitHub does not nest groups, so a script that runs another is called BETWEEN two of its own groups. The helper scripts open one group at the top and close it from an `EXIT` trap; `build.sh` and the layers also set an `EXIT` trap that
  prints `::endgroup::` and then `::error::<script> failed (exit N)` outside the group, so a failure is not folded away; exit status, `set -x` and trap order are unchanged. Tests: `tests/build-log-groups.sh` (balanced and not nested per script, a failing script closes its group and prints the error).

## Branches and releases

`testing` builds the `testing` image (once per merge, no build on pull requests); `main` is protected, changes only by pull request from `testing`
(merge commit), and publishes `latest`. `just release` opens or merges that pull request.

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
  `testing`, `test` and `secrets`; into `main`, `Build and push image`, `require-testing-branch`,
  `Sign and verify images`, `Build dx and push image` and `Build gx and push image` (the live main ruleset, checked 2026-11-16). Agents may merge their own feature pull request into `testing` once the required checks
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
  cancel-in-progress only for `testing` (see "Cancelling"). The workflow must exist on that branch.
- The owner's other repos (candy-for-gnome, octarine-images, dot-files) still commit straight on `testing`.

## Test workflow

`.github/workflows/test.yml` (name `Test`) is the fast lane for dev branches (the image build takes about ten
minutes). Triggers: `push` with `branches-ignore: [main]` (testing included since 2026-11-15: a non-required result; since 2026-11-16 a newer push to testing cancels the older still-running Test run, so a burst of merges leaves one run on the final tip) and `workflow_dispatch` (input `ref`: the bump workflow tests a bump commit from the testing ref); no `pull_request`
(the push check run is reported on the commit, so the pull request shows it and nothing runs twice) and nothing on
`testing` or `main` (those run `build.yml`). One concurrency group per ref (a dispatched run: per tested commit, so a push never cancels it and it never cancels a push), cancel in progress, `contents: read`.
Jobs `test`, `plan-tests`, `suite (<group>)` and `secrets`; `test` and `secrets` have these exact names because they are required checks (`suite` is not):

- `test` (Kevin, 2026-11-16, two stages; "we are over-engineering to catch errors that will be shown later"): stage 1 is the fast required `test` check, only the cheapest obvious things, on the host runner without a container (about 10 s): `.github/scripts/sanity.sh` runs `bash -n` on every tracked shell script and parses the workflow files (a broken one gives a "workflow file issue" with no job and no message). Since 2026-11-16 (Kevin, after a format nit failed a 15-minute image build) the `test` job also runs `just check` (pinned `just` through the setup-tool action; the build jobs of `build.yml`, `build-dx.yml` and `build-nvidia-dx.yml` no longer repeat it). No shellcheck, no JSON/TOML parse and no path check: each shows where it matters. Stage 2 is the image build on `testing` (the smoke test of the image build); a problem that needs the real image is not for the initial CI. It runs for every push, documentation-only ones included, and for the dispatched `Test of <sha>` runs of the bump workflow (`bump-checks.sh` posts the conclusions of `test` and `secrets` from that run).
- `plan-tests` and `suite` (2026-11-17): the behavior tests live in four group directories, `tests/pipeline/` (the decisions that first run on main, schedule or publish: plan, promote, publish-latest, prune, aggregate, inputs-hash, move-tags, ci-issue, transient-reads), `tests/supply/` (pins and bumps: base-pin, bump-bins-images, bump-weekly, chunkah), `tests/image/` (what the image build and its runtime helpers do: install-binaries, validate-repos, secureboot-check, schedulers) and `tests/recipes/` (the ujust recipes: datastore-box, gaming-setup, hardware-setup, luks-tpm-unlock, switch-image, user-setup). The directory tree is the one list: `.github/scripts/plan-tests.sh` (job `plan-tests`, host runner, checkout only, skipped for dispatched runs like `suite`) prints the groups as JSON and FAILS when a `tests/*.sh` sits outside a group or a group directory has no `*.sh`. `suite` is a matrix over that list (`suite (<group>)`, `fail-fast: false`); each job runs `tests/<group>/*.sh` one after the other by a plain shell loop (`timeout` 600 s per test, PASS or FAIL per test, a failing test prints its output) in a plain `registry.fedoraproject.org/fedora:45` container (floating tag on purpose: a Fedora change that breaks a script shows here); not a required check, and there is no aggregate `suite` result job (add one only if `suite` ever becomes required, since the matrix names are not a stable check name). A new test goes into a group directory (a new group is a new directory with at least one test); no workflow change. Every test finds the repository root with `git rev-parse --show-toplevel` from its own location, so the depth of a test never matters; `tests/**` stays docs-only for the image build (`docs-only.sh`). The tests make their own temp directories and run as an ordinary user (the container runs as root; some recipes and tests refuse root).
  No documentation-only shortcut (removed 2026-11-16, Kevin: the fast `test` makes it redundant; the image build's own docs-only plan, `plan-build.sh` and `docs-only.sh`, is a different thing and stays): a documentation push runs `test`, `suite` and `secrets` like any other. The loop unsets `GITHUB_OUTPUT`, `GITHUB_ENV`, `GITHUB_STEP_SUMMARY` and `GITHUB_PATH` (the runner points them at files the test user cannot write); tests set the ones they need themselves. The tests use stubs for podman,
  skopeo, cosign, brew and the network, so none is skipped in CI. The `suite` container runs as root, so the tests run as an ordinary user (some recipes and tests refuse root). A new test script needs no workflow change.
- `secrets`: gitleaks over the full history, pinned release and sha256, `curl --retry`.

Run the same locally: `just check; for t in tests/*/*.sh; do bash "$t" || echo "FAIL $t"; done` (one group: `tests/<group>/*.sh`).

Status: done in two parts. The `testing` ruleset requires `test` and `secrets`, and `build.yml` has no `pull_request`
trigger, so the image builds only on `testing` and `main` pushes, the schedule and a manual dispatch.

## What the tests may assert (Kevin, 2026-11-16: "many of the tests are over-sensitive to things that will not result in a failed build; we should be okay with the actual error revealing itself at build-time; the initial CI should be for just obvious sanity checks")

The initial CI keeps only syntax, lint and parse checks, cheap obvious smoke checks, and behavior tests with stubs for logic that first executes on main, schedule or publish and could not otherwise be seen before it breaks production (promotion retag, publish-latest ordering and the base rule, prune-daily deletion rules, sign and verify decisions, the luks-tpm-unlock SIGPIPE case, registry-read behavior). Tests must NOT assert workflow YAML text, README or doc prose, comment content, exact messages, file lists, or version, digest and count literals. When such an assertion fails, delete or loosen it (never move content to satisfy it, never add code to satisfy it); an error that a real build shows by itself needs no test.

Interactive recipes (menus, checklists, wizards) are covered by a thin smoke only, kept for what is silent or irreversible (kernel arguments, TPM and Secure Boot, the security-key file, root refusal, the plan modes); the rest shows when the recipe is run (2026-11-16: `tests/toolbox.sh`, `gaming-setup.sh`, `niri-setup.sh` and `niri-keybinds.sh` deleted, `hardware-setup`, `virthost-setup`, `user-setup`, `dev-setup`, `update-services`, `scheduler-recipe` and `sensors-setup` thinned).

Cut in the combined batch of 2026-11-16 (accepted by Kevin, no replacement checks): `tests/readme-defaults.sh` and `tests/test-workflow.sh` are deleted; the workflow, Containerfile, Justfile and script-text assertions of `binary-images.sh`, `binaries-validate.sh`, `bump-pins.sh`, `bump-checks.sh`, `bump-run.sh` and `ghostty-component.sh` are gone (their stub behavior tests stay). Invariants that are now unguarded by any test: nothing that publishes has a `pull_request` trigger; login, push and sign steps are gated on publish; sign runs in the `signing` environment; the `daily-*` tag is written only by the scheduled run; the default image must not install libvirt or QEMU; the personal-names grep (gitleaks still scans for secrets). A wrong edit shows on the first real run.

## Keeping the tests fast (2026-11-16)

The suite is four parallel group jobs (since 2026-11-17), so its length is the slowest group (the sum of its tests) plus the container setup. Three tests used to take 76, 48-62 and 37 s in CI; measured with `PS4='+T${EPOCHREALTIME} ' bash -x tests/<name>.sh` and a look at the biggest gaps between traced lines, nearly all of it was waiting, not work. Rules that came out of it: a test exports `RETRY_DELAY=0` whenever a stub makes `registry-read.sh`, `cosign-check.sh` or `retry.sh` fail (their pauses are 5 s, then 10 s, per call), sets `OCTARINE_SCX_VERIFY_SECONDS=0` for `scx-verify` (one probe instead of a 1 to 2 s wait; `tests/image/schedulers.sh` 35 s to 7 s), and runs an independent matrix of many `just` starts four at a time with `xargs -P` and one private HOME per combination (the niri keybind matrix, `tests/niri-keybinds.sh`: 18 s to 6 s on 16 cores, the same CPU time, so on the 4-core runner it only helps when other tests are done). Nothing shipped changed.

## Runner disk space (2026-11-14)

The image workflows used to start with `ublue-os/remove-unwanted-software` (38 s on the default build, 73 s on dx). Measured on `ubuntu-26.04` with two non-publishing dispatches of `build.yml` from `exp/disk-a` and `exp/disk-b`: the root disk is 145 GB with 57 GB used and 88 GB free BEFORE any cleanup; after the action 26 GB used and 119 GB free; after the default image build and rechunk 44 GB used and 102 GB free, so the whole build needs about 18 GB on top of the cleaned runner (about 5 times less than the free space at the start). A targeted removal of the biggest directories (dotnet, android, ghc, CodeQL, swift...) instead of the action was measured too and was SLOWER (119 s against 85 s for the action in the same measurement), so not deleting at all is the fast choice. Every image workflow (`build.yml`, `build-dx.yml`, `build-nvidia.yml`, `build-nvidia-dx.yml`) therefore runs a step `Check disk space` (id `disk`) and the action only as `Maximize build space (fallback, only when the disk is low)` when fewer than 60 GiB are free at the start. `build.yml` and `build-dx.yml` also print the free space after the build (job summary) and warn below 15 GiB. Only the default image was measured on a branch (dx and the NVIDIA builds publish, so they are only measured by their own runs: the summary line of the first dx build after this change is the number to look at). If a build ever fails with "no space left on device", lower nothing: remove the `if:` of the fallback step (the old behavior) and read the summary lines.

## Rules

- Home- or user-level configuration (themes, icons, dotfiles) never goes in the image. It lives in its own
  repo and is pulled in by a `ujust` recipe, such as `ujust gnome-candy <recipe>`. System-level files
  (PAM, sysctl, firewalld, `/etc` defaults) are fine in `system_files/`.
- Podman only; no Docker daemon.
- `sshd`, `tailscaled`, `cockpit.socket` and the snapper timers stay off by default. `mcelog.service` is NOT masked any more: the packaged unit skips itself without `/dev/mcelog` and when `edac_mce_amd` is loaded, and our drop-in `mcelog.service.d/50-octarine-intel-only.conf` (`ExecCondition` on `GenuineIntel`) skips it on any other CPU, so Intel keeps machine-check logging and AMD gets no failed unit (checked 2026-11: the kernel has `CONFIG_X86_MCELOG_LEGACY=y`; behavior on an Intel machine is untested).
  The image enables staged automatic updates by default: the base image's `ublue-os-update-services` enables
  `rpm-ostreed-automatic.timer` and ships `/etc/rpm-ostreed.conf` with `AutomaticUpdatePolicy=stage` (our `build.sh` adds
  nothing; the smoke test checks both). Image changes must not disable or alter that default. `ujust toggle-updates` is the
  user's own switch for it, one source among the others, and `ujust update` follows that switch.
  The base's `rpm-ostreed-automatic.service.d/override.conf` already has `Wants`/`After=network-online.target` (and a metered-connection
  `ExecCondition`); that cannot help after a wake from sleep (the target is already reached), where the run failed with
  "pinging container registry". Our separate drop-in `50-octarine-retry.conf` adds a bounded retry (`Restart=on-failure`,
  `RestartSec=60`, five starts per hour); the policy stays untouched. `NetworkManager-wait-online.service` is enabled; the smoke test checks both.
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
- Tests (cut on 2026-11-16 from about 60 files and 6,700 lines to the 24 files below; Kevin: robust, simple, minimal maintenance, the initial CI is sanity only). `tests/<group>/*.sh` is what the non-required `suite` runs; older sections of this file that name a test file not in this list describe a test that was deleted that day. Kept, because the logic first runs on main, schedule or publish and could not otherwise be seen before it breaks production: `aggregate-result`, `plan-promote`, `prune-daily`, `publish-latest` (one image at a time: the image signed, a variant's base a signed default image from main, revision an ancestor of main, no backwards move per image, read-back mismatch, an unreadable registry is a failure), `bump-bins-images` (the bins-dx and bins-gx kinds), `gaming-setup` (the native Steam skip), `plan-skip`, `plan-dx` (a few cases, dx and gx), `inputs-hash` (what counts as an input, the testing reuse), `install-binaries` (the real installer against a fixture in the octarine-bins layout, added 2026-11-16 when `binary-images` and `binaries-promote` left with the binaries pipeline), `transient-reads` (registry-read and cosign-check exit codes), `base-pin`, `chunkah`, `secureboot-check`, `validate-repos`, `luks-tpm-unlock` (wipe and lockout guards), `hardware-setup`, `switch-image`, `user-setup`, `schedulers` (the root helpers and the polkit rule), `binary-images` (lookup, layout, installer), `ci-issue` (`optional-packages` was removed 2026-11-16 with the package lists). `tests/binary-images.sh` is the writer-to-reader test of the binaries pipeline: the real `binaries/lib/assemble.sh` writes `COMPONENTS` (names, one per line) and the combined `LICENSES`/`SOURCE`/`BUILDINFO` for the real `install-binaries.sh` (the binaries-decide test and `tests/lib/components.sh` were deleted with the per-component pipeline, 2026-11-16). A test is worth keeping only if it runs the real writer into the real reader (a hand-written copy of a file format hid the COMPONENTS bug of #206 to #209).
  Deleted without replacement: `plan-build`, `dispatch-dx`, `push-tags`, `retry`, `run-tests`, `upstream-check`, `bump-run`, `bump-checks`, `bump-pins`, `brew-bump`, `compilers`, `check-call-shape`, `containerfile-from-args`, `build-log-groups`, `binaries-validate`, `binaries-build`, `ghostty-component`, `scx-kernel-check`, `scheduler-recipe`, `hardware-targeting`, `image-version`, `nvidia-variant`, `nvidia-dx-image`, `sensors-setup`, `virthost-setup`, `update-services`, `kargs`, `dev-setup`, `menu`, `ojust`, `datastore-recipe`, `flatpak-preinstall`, `just-recipes`, `motd`, `emoji`, `system-defaults`, `publish-latest-workflow`, `build-triggers` and `dx-image` (workflow-text tests, 2026-11-16); the real `fetch-zig.sh` checks run at build time. The `suite` job no longer installs fish, zsh, niri, shellcheck, dconf, bash-completion or zstd, and it does not repeat `bash -n` and `just check` (`sanity.sh` does the `bash -n` and the workflow parse).
- The default image carries `gcc`, `gcc-c++`, `make` and `binutils` (`required-fedora.txt` of the octarine-bins image, the owner's decision of 2026-11-14, which reversed the earlier rule that the image has none; 221 MiB installed, dependencies glibc-devel, libstdc++-devel, libxcrypt-devel and kernel-headers) but no clang, cmake, ninja, meson or -devel libraries (the dx image has the full toolchain); the toolbox the definition describes is
  the image `ghcr.io/redcodeworks/fedora-toolbox` built from its own repo (`TOOLBOX_IMAGE` overrides the tag). The host recipe is `ujust toolbox <name>`; to add a toolbox ship a
  definition `<name>.ini` (section `[<name>]`), an optional `<name>.conf` (TOOLS, EXPORT_BINS, IDES as plain data) and
  an image from the octarine-images repo.

## CI and signing flow

- **Tags.** `testing` pushes publish `testing-<sha>` and `testing-<date>-<sha>` first (immutable); `testing` and `testing-<date>` move only after the digest is signed and verified (`move-tags.sh` in the sign job, see "Cancelling").
  `main` publishes (build, or promote of the tested `testing` digest) `latest`, `latest-<date>-<sha>`, `latest-<sha>`, `latest-<date>`, `<date>`, `<date>-<sha>`
  (`just generate-build-tags`). A daily schedule on `main` (11:00 UTC, GitHub may delay on-the-hour runs by several minutes) refreshes `latest`. Pull requests
  into `testing` build without publishing. Dependabot proposes changes to `testing`.
- **Promotion.** `main` merges only when `Build and push image` passed on the tip of `testing` and
  `require-testing-branch` passes (it rejects any other source branch). Use a merge commit so `testing`
  stays in line with `main`. Pin or roll back by switching to a dated tag; `bootc rollback` boots the previous
  deployment.
- **Build job.** Choose channel, a base-pull step (pulls the base named by
  the workflow env, where repository variables override, logs its digest and fails naming the tag if it does not exist), `just build`, an image-size guard
  (15 GiB), the smoke test, `just rechunk`, tags, push. The smoke test runs the image and checks
  units, packages, PAM fallbacks, the signature policy, os-release (`ID=fedora`, and `VERSION_ID` against
  a numeric base tag), sudoers, firewalld, the toolbox definition `dev-toolbox.ini`/`dev-toolbox.conf` and the preinstall
  list. Add new packages and units to it.
- **Package lists (moved into octarine-bins on 2026-11-16, Kevin: "what goes into each image" lives with the image's binaries).** One-sentence model: each octarine-bins image (`octarine-bins`, `-dx`, `-gx`) carries `/packages/install.sh` plus `required-<source>.txt` and `optional-<source>.txt` lists (`fedora`, `negativo17`, `copr`) and its binaries (none yet for dx and gx); octarine-os pins ONE digest per variant, bind-mounts it at `/binaries` and calls its installer, so the lists no longer live in this repository (the contract is in octarine-bins's CLAUDE.md, "The package lists"; the default image's lists are `src/packages/` there, dx's `dx/packages/`, gx's `gx/packages/`). `build.sh` empties `/usr/share/octarine-os/optional-packages-missing` once and runs `MISSING_FILE=<that file> NO_CLEANUP=1 bash /binaries/packages/install.sh`; `dx.sh` and `gx.sh` run the installer of their own image with the same `MISSING_FILE` (the installer APPENDS, never truncates, so the file lists the misses of the whole image). The installer's order: required-fedora, required-negativo17, required-copr (each file ONE strict dnf5 transaction, any failure fails the build), then optional-fedora, optional-negativo17, optional-copr (best effort: one transaction per file, retried once as a whole, then package by package; misses are printed as `OPTIONAL PACKAGE MISSING: <name>` and written to the missing file; the smoke job turns each into a CI warning). NOT in the installer and still OS-side: the niri/noctalia hard failure (`check_session_packages` in `build.sh`, after the install), the smoke test's vendor check (every REQUIRED package of the default image must have the RPM vendor `Fedora Project`; the smoke test repeats the required list by hand, keep it in step with `src/packages/required-fedora.txt`), `validate-repos.sh`, `dnf5-plugins` (gx.sh installs it for the COPR list) and the zsh `/etc/shells` step. **Behavior change for the base's optional packages:** the five Fedora groups (misc, cockpit, pcp, containers, libguestfs) are now ONE transaction (`optional-fedora.txt`), so one unavailable name makes the whole file fall back to the whole-file retry and then package by package (it used to cost only its group the first try); the result is the same set of installed packages, only slower on a failure. `tests/optional-packages.sh` was removed (the installer and its tests live in octarine-bins). Add a package: in the right list file in octarine-bins, then bump the pin here (the `bins`, `bins-dx` or `bins-gx` bump PR), and add it to the smoke test's required or informational list.
- **Cancelling (revised 2026-11-16).** `build.yml` has `cancel-in-progress: ${{ github.ref == 'refs/heads/testing' }}`: a newer push to `testing` CANCELS the older run (the group is workflow plus ref, so main push and schedule runs share a group and queue behind each other, never cancelling; #204 had turned cancelling off because a cancelled testing build could leave `testing` on an unsigned digest). That hazard is gone by ORDER, the order octarine-bins uses: a testing build's `build_push` pushes only the immutable tags `testing-<sha7>` and `testing-<date>-<sha7>` (output `alias_tags`); the `sign` job signs that digest, verifies the immutable tags, and only THEN runs `.github/scripts/move-tags.sh` (registry-side copy, digest kept, `registry-settled.sh` read-back, then a `cosign verify` of the moved tags) for the moving tags `testing` and `testing-<date>` (output `moving_tags`, empty on main and schedule: their `latest-*` tags are immutable per build and bare `latest` moves only in Publish latest after signing, per image). A cancel therefore leaves, at each stage: during the build, nothing new published, `testing` on the previous signed image; between the push and the signing, an unsigned `testing-<sha7>` that nothing trusts (reuse and promotion verify the signature and build instead when it does not verify, `plan-dx.sh` verifies the base) and `testing` still previous; during the signing, the same, possibly with a signature but without the move; during the move, `testing` still on the previous signed image or already on the new signed one (a copy is one registry call, and the next run signs and moves again). `build_result` (`Build and push image`) has `if: !cancelled()`: when the run is cancelled the job does not run (it shows as skipped), so a superseded run reports no failure and testing has no alert; the check that counts is the newest tip's own run. Unverified: how GitHub reports that skipped required check on the superseded commit (only the tip matters for the promotion pull request). The dx build for `testing` is dispatched only after `build_result` succeeds, so a cancelled run starts none.
- **Labels.** `just build` sets the OCI labels (source `https://github.com/<owner>/<image>`, licenses,
  title, description, created, version, artifacthub keys). chunkah (`just rechunk`) starts from the image's own config
  (`podman inspect`), so every label stays; it drops only `ostree.commit` and `ostree.final-diffid`. (The earlier
  `rpm-ostree compose build-chunked-oci` started from the rootfs and had to re-pass the labels one by one.)
- **Secure Boot check of the kernel (2026-11-14, Bluefin's way).** After the rechunk, `build.yml` and (after its smoke test) `build-nvidia.yml` run
  `.github/scripts/secureboot-check.sh <image>`, the same as Bluefin's and Aurora's `secureboot` recipe: the single kernel of the image is copied out, Universal Blue's kernel signing key is downloaded
  (`fetch_key`, curl with 3 retries, from `https://github.com/ublue-os/akmods/raw/main/certs/public_key.der`; a failed download fails the check clearly), converted DER to PEM, `sbverify --list` is printed
  and `sbverify --cert` must accept the kernel, otherwise the build FAILS ("Secureboot Signature Failed"). The Fedora signature is not checked. The earlier attempt to pin Fedora's leaf or CA certificate was dropped (Kevin,
  2026-11-14: the leaf is one signing builder's, the CA is not in the image, and Bluefin's mechanism is proven). The key is read LIVE from the `main` branch of `ublue-os/akmods` on every run, so that repository's
  controllers decide what passes (nothing is pinned, so key rotation needs no change here); `docs/signing-keys.md` has the fingerprint. What it proves: the kernel carries the signature that the Universal Blue MOK
  (enrolled on nox) accepts; it does NOT prove the kernel boots on a stock Secure Boot machine. Facts from the real image (octarine-os:latest, kernel 7.2.15-300.fc45, checked 2026-11-14): THREE signatures, Fedora's
  `kernel-signer` (bkernel01, Fedora Secure Boot CA 20200709), Universal Blue's `ublue kernel` and `ublue akmods`; the downloaded key is byte-identical to `/etc/pki/akmods/certs/akmods-ublue.der` of the image. The
  runner has no sbverify: the step installs `sbsigntool` (apt); no alpine fallback (Bluefin needs one for its own runners). The first CI run was the old branch's discovery run, which failed on purpose for want of a pin.
  The NVIDIA smoke test (`nvidia-smoke.sh`) also requires every NVIDIA module's `sig_key` to equal the subject key identifier of `/etc/pki/akmods/certs/akmods-ublue.der` of the image (the key
  2026-11-15 (the first scheduled NVIDIA failure after ublue-os/akmods #632 retired the legacy 2023 key): the modules' `sig_key` became `7D:F8:7A:F5:...`, which is the SERIAL NUMBER of the published 2024 certificate (`certs/public_key.der`, subject key identifier `2C:25:06:15:...`, same subject CN `ublue kernel`), not a new key: the signer now encodes the same certificate by serial instead of by subject key identifier. The smoke test accepts the subject key identifier OR the serial number (the latter only together with the certificate's common name as the module's signer); any other id still fails. Evidence: `openssl x509 -inform DER -noout -text` of `certs/public_key.der` on ublue-os/akmods main shows both values.
  `ujust hardware-setup` enrolls), `vermagic` to start with the installed kernel release, and, when `keys/secureboot.env` pins `NVIDIA_MODULE_SIGNER`, the signer name. dx and nvidia-dx inherit the kernel unchanged (their smoke tests check it did not change). NOT verifiable in CI: a real boot (Kevin boots testing on nox, Secure Boot on).
  Tests: `tests/image/secureboot-check.sh`, `tests/nvidia-variant.sh`.
- **zizmor (`zizmor.yml`, 2026-11-14).** Audits `.github/` on pull requests that touch it, pushes to `testing`, weekly (Wednesday 06:00 UTC) and by dispatch; job and check name `zizmor`, NOT a required
  check (the ruleset is the owner's). The binary is zizmor 1.32.0, the release asset verified by its sha256 (like the gitleaks job); `.github/zizmor.yml` holds the narrow ignores with a reason each (the local
  `./.github/actions/setup-tool` self-repository style hints, the two bump workflows that push with the persisted token, the `$GITHUB_ENV`/`$GITHUB_PATH` writes of setup-tool and `build-nvidia-dx.yml`, and its `workflow_run` trigger). The first run found
  156 findings (all 97 pinnable `uses:` were already pinned by commit SHA; the "31 unpinned" count was the local `./.github/...` ones, which cannot be); fixed: `persist-credentials: false` on every checkout that does not push,
  `secrets: inherit` replaced by the named `SIGNING_SECRET`, template expansions moved into `env`, read-only workflow permissions for `build.yml`, a Dependabot cooldown.
- **Strict lint (2026-11-14).** Every Containerfile ends with `RUN --network=none bootc container lint --fatal-warnings --no-truncate` (Aurora's last step). The first full output showed three
  warnings on the default image: a non-empty `/boot` (extlinux), content in `/run` (cockpit, dnf, selinux-policy, setroubleshoot) and 493 `/var` entries missing tmpfiles.d (libvirt, pcp, iscsi,
  dnf state, PackageKit ...). `build_files/final-cleanup.sh`, the last step of `build.sh`, `dx.sh` and `nvidia.sh`, empties `/boot`, `/run` and `/tmp`, drops dnf and PackageKit state and crash dumps, and moves
  what the packages put in `/var` into `/usr/lib/tmpfiles.d/octarine-var.conf` (`d` for directories with their mode and owner, `C` copies of files from `/usr/share/factory/var`, `L+` for symlinks), so the
  directories and files come back at boot (a later layer appends). No warning is silenced. The dx and NVIDIA layers use the same script; UNVERIFIED until their first CI build with it.
- **Rechunk with chunkah (2026-11-14; Kevin's rule: adopt it when Universal Blue does, and Aurora and Bazzite's main repo do).**
  `just rechunk` (every image workflow: default, dx, nvidia-dx; the NVIDIA variant is a layer and is not rechunked) runs the chunkah image
  with Aurora's flags (`--compressed --max-layers 256 --prune /sysroot/ --label ostree.commit- --label ostree.final-diffid- --config <podman inspect>`).
  The image is pinned by digest in `config/chunkah.env` and `.github/scripts/chunkah-ref.sh` verifies its keyless cosign signature (GitHub Actions OIDC issuer,
  identity regexp `^https://github.com/coreos/chunkah/`) before every use and fails closed; `bump-pins.yml` (matrix entry `chunkah`, `bump-pin.sh chunkah`)
  moves the digest to `latest` weekly, after the same verification, as a pull request into `testing`. The recipe prints and writes to the job summary the time,
  the layer count and the size. Measured before (last green testing run 43615118757, rpm-ostree): rechunk step 300 s, job `Build image` 674 s, dx job 920 s,
  up to 127 layers. Measured after (non-publishing dispatches 43637709422 and 43638625094 on the branch): rechunk step 150 to 159 s, job `Build image` 468 s, 256 layers, 7035 MiB; the cosign verification of the pinned digest passed. UNVERIFIED: a real boot of a chunkah image (Kevin boots the testing image on nox before promoting).
  Undo: `git revert` the commit; `rpm-ostree compose build-chunked-oci` came back from git history.
- **Version.** Every build, testing or main, stamps `org.opencontainers.image.version` (what `bootc status`
  shows as the version) with `<YYYYMMDD>-<short sha>` from `.github/scripts/image-version.sh`, never a channel
 . A promoted image keeps the version it was built with, which is why it must
  be channel-neutral: the retag cannot change it. After the rechunk the build checks, with
  `check-version-neutral.sh`, that the version label (and any other `*version*` label) is present and contains
  neither `testing` nor `latest`. Image tags are unchanged.
- **Signing.** A separate `sign` job in the `signing` environment (limited to `main` and `testing`) signs
  every distinct pushed digest with cosign (old bundle format, `--use-signing-config=false`) and verifies
  each tag against `cosign.pub`. Pull request builds never reach it. `build.sh` generates the container
  signature policy (a `sigstoreSigned` scope for `ghcr.io/<org>/<image>`, a `registries.d` entry, the key under
  `/etc/pki/containers`) from `IMAGE_ORG`, `IMAGE_NAME` and `cosign.pub`, keeping the catch-all last (rules for the default, `-nvidia`, `-dx` and `-nvidia-dx` repositories).
  `just build` passes `IMAGE_NAME=${target_image##*/}` so a `localhost/` prefix does not leak into it.
- **Daily tag and a small prune (2026-11-16, replaces the big prune workflow).** The scheduled daily build of `build.yml` (event `schedule` only: not pushes, promotions or dispatches) adds the tag `daily-YYYYMMDD` (UTC) next to the dated aliases, in the same push (one digest for every tag). The dx image built right after it gets the same tag when the default image it is built on (its base digest) is the digest of `octarine-os:daily-<today>` (`build-dx.yml`, step Tags; no new input). A daily run that skips because nothing changed makes no new image and no tag, so the 14 are the last 14 daily-tagged images, not 14 days. `prune-daily.yml` (Sundays 05:00 UTC, `.github/scripts/prune-daily.py`) works on `octarine-os`, `octarine-os-dx` and `octarine-os-gx`, one matrix job per package (2026-11-17; job `plan` is the one list of names and passes the names and the protect list on, so a new image is one name there): of the versions with a `daily-*` tag it keeps the newest 14 and deletes older ones whose tags are all `daily-*` or dated aliases (`latest-<sha>`, `latest-<date>[-<sha>]`, `<date>[-<sha>]`), with their cosign signature version (`sha256-<digest>.sig`); a signature whose digest is not a version of the package is deleted too. Never deleted: a version with any other tag (the bare `latest`, `testing*`, ...), and the digest behind `latest` and the base of the dx `latest` (the `plan` job reads each variant's `org.opencontainers.image.base.digest` label and passes the digests as `PROTECT`; a failed lookup stops the run). A plan over 30 versions is refused (the run fails, nothing deleted). Scheduled runs delete; a dry run is `gh workflow run prune-daily.yml -f dry_run=true`. There is no alert job (a failed prune is a red scheduled run). Testing builds, `testing-<sha>`, the NVIDIA images and everything else accumulate (public GHCR storage is free); delete old versions by hand in the GitHub packages UI if ever needed. Test: `tests/pipeline/prune-daily.sh`. UNVERIFIED until a scheduled main run: the daily tag on both images, the first real prune.
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
  `.github/scripts/plan-skip.sh` (pure function of its environment; tests: `tests/pipeline/plan-skip.sh`). The labels are set by
  `just build` and re-passed by the rechunk. Failure modes: a stale or unavailable registry lookup builds (costs minutes,
  never skips wrongly); a base digest label from a different lookup method would build every day (the build computes the
  label the same way the plan does).
- **Runners and cache.** Every job runs on the pinned `ubuntu-26.04`, not
  `ubuntu-latest`, so the toolchain (podman, skopeo, just) changes only when this repo changes it. No layer or registry
  cache: the image is one large `RUN build.sh` after `COPY system_files`, whose cache key changes with every commit and
  with the daily base, so a layer cache would almost never hit, and the rechunk step rebuilds the layers anyway; the
  scheduled skip removes the repeated identical builds instead. Tool installs go through the composite action
  `.github/actions/setup-tool` (`tool: cosign` or `tool: just`, versions pinned inside it): it restores the binary from
  `actions/cache` (key `octarine-tool-<tool>-<version>-linux-amd64`, path `~/.cache/octarine-tools/<tool>-<version>`),
  skips the download on a hit, and on a miss runs the SHA-pinned installer (`sigstore/cosign-installer`,
  `extractions/setup-just`) with `continue-on-error`, waits 60 s and tries once more if it failed (GitHub release
  downloads return 504 now and then), failing only when both attempts fail; the cache is saved after a successful install
  (the binary is copied there). cosign is cached everywhere except the signing steps (input `cache: "false"` in `sign-images`, and the `sign` jobs of `build.yml` and `build-nvidia.yml`): where the signing key is present it is installed and verified fresh, never restored (Kevin, 2026-11-16). Cache scoping: a run can read caches of its own branch and of the default branch, but
  not those of another branch, so `testing` and pull request runs fall back to `main`'s cache and `main` never sees
  `testing`'s: the first run on each branch downloads, then it is a hit. A cached binary that does not run is ignored
  and reinstalled. Bumping a tool means changing the version in the action (and the installer's `with:`).
- **No debounce (removed 2026-11-16).** The 90 s wait at the start of the `plan` job is gone; a newer push to `testing` cancels the older run again since the tags are moved after signing (see "Cancelling"), so a burst builds the newest tip.
- **Docs-only skip.** A `plan` job always runs `.github/scripts/plan-build.sh` (tested by
  `tests/plan-build.sh`). When every file changed in the range (push: `github.event.before` to the sha; pull
  request: base to head) is docs-only, it sets `build=false`: top-level `*.md`, `docs/**`, `LICENSE`, `.gitignore`
  (the list is `is_docs` in `.github/scripts/docs-only.sh`, one place, sourced by the plan scripts). The heavy `build_push` job (named `Build image`) and
  `sign` are then skipped, and the aggregate `build_result` job, named exactly `Build and push image`, passes.
  An unknown or all-zero before-SHA, the schedule, `workflow_dispatch` and any other changed file always build.
  Exception (2026-11-16): a push to `testing` is never skipped by its own diff (`plan-build.sh` gets `github.ref` as a fourth argument and prints
  `true`): after a batch of back-to-back merges the last push was tests and notes only, the builds of the earlier pushes had been cancelled by the newer
  pushes, and the tip had no image (the plan said `only docs changed`). With `build=true` the reuse step (`plan-vanilla-reuse.sh`) decides: it reuses a
  signed image only when its default-image inputs equal the tip's (so a docs-only or dx-only tip still reuses), otherwise the build runs. The diff of one
  push may confirm a reuse, never skip a build whose inputs have no image. Batch rule: merging several PRs into `testing` back to back leaves ONE build, on
  the final tip, which covers all of them; check that `octarine-os:testing-<short sha>` of the tip exists afterwards.
  Required checks are `Build and push image`, `require-testing-branch` and `Sign and verify images`; do not
  rename them (a skipped `sign` job counts as passing).
- **Promotion (build once, promote).** A merge into `main` retags the already tested and signed `testing`
  image as `latest` instead of rebuilding. Off unless the repository variable `PROMOTE_ENABLED` is `true`
  (the owner sets it; the workflow never does). `plan-promote.sh` (tests: `tests/pipeline/plan-promote.sh`, with a fake
  registry lookup) promotes only when the push is to `main`, the commit is a merge (two parents), `vanilla_inputs`
  (see "Input hashes and dx on testing") of `HEAD^2` (the testing tip) and of `HEAD` are equal, and walking first-parent history back
  from `HEAD^2` reaches a commit C with a published `testing-<short sha>` tag without crossing a commit whose
  `vanilla_inputs` differ (so a docs-only or dx-only testing tip, which has no image of its own, promotes the image of the commit behind
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
  aggregate means built, signed and published. `aggregate-result.sh` (tested by `tests/pipeline/aggregate-result.sh`)
  accepts a skipped `sign` only when nothing was published and fails when sign was expected and did not succeed.

## Input hashes and dx on testing

- **Three hashes, one script.** `.github/scripts/inputs-hash.sh` (tests: `tests/pipeline/inputs-hash.sh`) hashes the sorted
  `git ls-tree -r` entries (mode, blob id, path) of a commit that pass a filter, so the result does not depend on commit ids or
  dates. `dx_inputs` covers the dx-only paths (`is_dx_only`): `variants/dx/**`, `.github/workflows/build-dx.yml`,
  `.github/scripts/dx-smoke.sh`, `.github/workflows/build-nvidia-dx.yml`, plus the paths both variants share (`is_variant_shared`: `.github/workflows/dx-image.yml`,
  `.github/scripts/{plan-dx,aggregate-dx}.sh`, `keys/redcodeworks-toolbox-cosign.pub`). `gx_inputs` (third kind, 2026-11-16) is `is_gx_only` (`variants/gx/**`,
  `.github/workflows/build-gx.yml`, `.github/scripts/gx-smoke.sh`) plus the same shared class; the shared paths count in both variant hashes and never in `vanilla_inputs`,
  and `vanilla_inputs` excludes every gx-only path, so a gx-only change rebuilds neither the default nor the dx image (`tests/pipeline/inputs-hash.sh`).
  `vanilla_inputs` covers every other tracked file except the docs-only ones (`is_docs`, `docs-only.sh`: top-level `*.md`, `docs/**`, `LICENSE`, `.gitignore` and, since 2026-11-14, the whole test suite `tests/**`: nothing in the image build copies or runs it, so a test-only push builds nothing and a test edit rebuilds neither image; the first push with this change rebuilds once because five tests used to be dx-only inputs and the rest default-image inputs; `.github/scripts/*.sh` and the workflows stay inputs). A new dx-only file must be
  added to `is_dx_only` (its test checks that each listed path exists); a file in neither group is a default-image input.
  Why hashes and not a `paths:` filter: a path filter on `build.yml` would leave the required check `Build and push image`
  missing on a dx-only commit and block the promotion pull request.
- **Default image (`build.yml`).** Still runs on every push, and the `plan` job decides. `just build` labels the image
  `io.github.redcodeworks.octarine-os.vanilla-inputs` (inside the clean-tree block, next to `revision`; the rechunk passes it on; the dx
  build unsets it). On a push to `testing` the step `Look for an identical default-image build on testing`
  (`plan-vanilla-reuse.sh`) walks first-parent history back from the commit to the nearest one with a published `testing-<short sha>`
  tag; if its `vanilla_inputs` equal the commit's (and the signature verifies, and the image's label, when present, is equal), the plan ends with
  `build=false promote=false`, "default-image inputs unchanged, nothing to build", the aggregate `Build and push image` passes
  (sign skipped, as for a docs-only push) and the `testing` tag stays on the earlier image. A commit between them that changes
  `vanilla_inputs` stops the walk (build). Images from before the label have none: the commit decides. The scheduled skip compares
  `vanilla_inputs` of the `latest` revision with HEAD instead of the git tree, so a dx-only change does not rebuild `latest` the next day.
- **dx on testing (`build-dx.yml`).** Since 2026-11-13 dx is DISPATCHED (bullet "How dx is started" below), no longer started by `workflow_run`; the plan, tags and channels below are unchanged. Channels: `testing` (after a testing build; base
  `octarine-os:testing-<sha7>` of the triggering commit, see below; tags `testing` and `testing-<sha7>`; no `-<date>-` tag), `latest` (after a main build). Every checkout is `inputs.sha`, the commit the pipeline built (a manual dispatch without it: the ref's tip).
  `.github/scripts/plan-dx.sh` (tests: `tests/pipeline/plan-dx.sh`) decides per channel from the published `octarine-os-dx:<channel>` labels
  `org.opencontainers.image.base.digest` and `io.github.redcodeworks.octarine-os.dx-inputs` (new; `dx-tree` is still written but no longer compared):
  skip only when BOTH equal the current base digest (raw manifest digest of the verified base, see "Base of the testing channel" below) and `dx_inputs` of the
  commit; on `latest` otherwise look for a promotable testing image (candidates `testing`, then `testing-<sha7>` of the newest 60 commits of
  HEAD; both labels must equal the current ones and the signature must verify) and retag it (job `promote`: `skopeo copy --all --preserve-digests`
  to `latest` and `latest-<date>-<sha7>`, digest compared before and after; the `sign` job verifies, it does not sign again);
  else build. After a vanilla promote the base digest of `latest` equals the tested digest, which is what makes the labels match.
  Force always builds. Decision table (build / promote / skip), testing: nothing published or any label differs or force = build, both equal = skip
  (the base digest is that of `octarine-os:testing-<sha7>`, walk-back or fallback below);
  latest: both equal = skip, a matching tested testing image = promote (its base digest equals `octarine-os:latest`, which after the default promote
  is the digest of the tested `testing-<sha7>`), else build.
  Change combinations on `testing`: dx-only = vanilla `reuse` (no vanilla build), dx builds; vanilla-only = vanilla builds, the new base digest
  makes dx build; both = both; nothing/docs-only = vanilla skips, dx skips (labels equal); first run = both build.
- **Base of the testing channel.** `plan-dx.sh` for `testing` does not read the floating `octarine-os:testing` tag: it resolves
  `octarine-os:testing-<short sha7 of HEAD>` (HEAD = `inputs.sha`, the commit of the default build that just finished), verifies
  its signature and records that digest as `base.digest`. If the tag does not exist (the default build was reused for a dx-only or docs-only
  change) it walks back with `nearest_image_for_inputs` (the `plan-vanilla-reuse.sh` logic: first-parent history, stops at a commit whose
  `vanilla_inputs` differ) to the nearest earlier `testing-<sha>`; if there is none either it falls back to the floating `testing` tag with
  a `::warning::` (the old behavior). `base_tag` in the plan output is the tag actually used (`testing-<sha7>`), and the dx image's `base.name`
  label records it. `latest` still resolves `octarine-os:latest`.
- **One manifest digest per build (`push-tags.sh`).** Why the dx image never promoted (found 2026-11-10): every image workflow pushed each
  tag with its own `podman push` of the same local image, and the pushes did not produce one manifest: `octarine-os:testing` and
  `testing-cc213cb` of one build had different digests. The default promote copies `testing-<sha7>`, so `latest` had that digest, while the
  dx testing image had recorded the floating `testing` digest as its base; the `latest` plan then never found a matching tested image and built
  (about 21 minutes per promotion). The fix: `.github/scripts/push-tags.sh <local image> <registry image> <tag>...` pushes the first tag once
  (`podman push --digestfile`), makes every other tag a registry-side `skopeo copy --all --preserve-digests` of that digest, and reads each
  tag's digest back from the registry (a mismatch fails the step; the read-back POLLS, 6 reads 5 s apart, because GHCR answered a read right after a copy with the previous manifest of the tag on 2026-11-14 and failed a green dx push of `testing`, leaving an unsigned `testing` image until a re-run); it writes the single `digests=` output the sign job signs. `build.yml`,
  `build-dx.yml` and `build-nvidia.yml` all use it; a workflow must not `podman push` twice (tested in `tests/push-tags.sh`,
  with the stub podman/skopeo registry, plus the `dx-image` workflow checks). Images published before the fix still have
  two digests; the first promotion after it builds dx once because no tested dx image on a matching base exists yet.
- **How dx is started (2026-11-13) and the result check.** dx stays a SEPARATE workflow (re-runnable on its own, own badge; a reusable-workflow attempt, #66 and #67, was reverted for that reason). Since 2026-11-16 its plan, build and promote jobs are the reusable `dx-image.yml` (shared with `build-nvidia-dx.yml`); `build-dx.yml` itself is still the separately dispatched, re-runnable workflow and keeps the trigger, concurrency group, run-name, the result job named `Build dx and push image` (the required check; it builds its inputs from the called workflow's `plan`/`build`/`promote` outputs and the caller's own `sign` job result) and the commit status, `publish` and `alert`. `build-dx.yml` has ONE trigger, `workflow_dispatch` (inputs `channel` testing|latest, `sha`, `force`; `run-name: dx <channel> <sha>`). The LAST job of `build.yml` (`dispatch_dx`, `needs: build_result`, `if: always() && build_result success`, main and testing only, `actions: write`) runs `.github/scripts/dispatch-dx.sh <channel> <github.sha>`: `gh workflow run build-dx.yml --ref <same ref> -f channel -f sha`, then waits until a run titled `dx <channel> <sha>` EXISTS (12 tries, 10 s; it does not wait for the dx run) and fails otherwise, so a refused or lost dispatch makes the final job red while the base stays green (re-run that job alone to dispatch again; tests: `tests/dispatch-dx.sh`). A dispatched run uses the workflow file of the ref and is recorded ON that branch, so a change to `build-dx.yml` runs on `testing` before promotion and the README has dx badges for `main` and `testing`. The plan job refuses a `sha` that is not a full sha or not an ancestor of the ref. Concurrency group `build-dx-testing` for the testing channel (a newer tip's run CANCELS the older one since 2026-11-16: a superseded tip needs no dx image, and the cancelled run posts no commit status, so nothing red stays on its commit; `dispatch-dx.sh` only needs the run to appear, it never waits for it), and `build-dx-latest-<sha>` per commit for the latest channel, which is never cancelled. The aggregate job is the check `Build dx and push image` ONLY when `inputs.sha` equals the ref's tip (a check run attaches to the tip; for an older commit it is named `Build dx (older commit)`, so a green check never appears on a commit whose own dx build has not run); the commit status of the same name is ALWAYS posted on the built commit from the same result (they never disagree). Main's ruleset lists the context without an integration id, so a status or a check run satisfies it: no ruleset change. `aggregate-dx.sh` is unchanged (green when built and signed, promoted and verified, or legitimately skipped). `plan-dx.sh` skips only when the published dx image's digest also verifies with `cosign.pub`. **Tag order for testing (2026-11-16):** the dx `build` job pushes only `testing-<sha>` (output `alias_tags`); the caller's `sign` job (the composite `sign-images`, input `moving-tags` from the output `moving_tags`) signs that digest, verifies the tag, and only then moves `octarine-os-dx:testing` with `move-tags.sh` and verifies it, so the cancel of `cancel-in-progress: true` (testing channel) leaves `testing` on the previous signed image. Because every published dx tag is now a signed image, `plan-dx.sh` no longer verifies the signature of the published image before skipping (that branch and its test case are removed; promotion candidates and the base are still verified). The NVIDIA dx caller is unchanged: it runs only on main with channel `latest`, never cancels, and pushes bare `latest` at build time (a pre-existing order, signed right after by its sign job; not touched here).
- **Transition (2026-11-13).** Until the promotion that brings this to `main`, `main` still has the OLD `workflow_run` file, which starts after each successful testing run and builds dx for the same commit. The new dispatched run finishes before the old one starts (the old one waits for the whole base run), the shared group `build-dx-testing` serializes them, and the old run's plan (same `plan-dx.sh`) sees a signed image with equal base digest and dx inputs and skips. Residual risk: a pending concurrency slot replaced by a newer one. The promotion removes the trigger.
- **NVIDIA dx.** `build-nvidia-dx.yml` calls the reusable `dx-image.yml` (inputs `base_name`, `dx_name`, `promote_from_testing: false`, `tags`, `extra_smoke`; it runs `plan-dx.sh` with `BASE_NAME`, `DX_NAME`, `PROMOTE_FROM_TESTING`) and builds the same `variants/dx` layer on `octarine-os-nvidia`; see "NVIDIA dx image and the CUDA toolbox".
- **Dry run and finding the run (2026-11-14).** `build-dx.yml` has the inputs `dry_run` (plan and report only: build, promote and sign are skipped, no commit status, the aggregate job is named `Build dx (dry run)` so it can never satisfy the required `Build dx and push image` on a tip) and `base_digest` (declared for channel `latest` on main, wired by the part that publishes `latest` through `Publish latest`). The commit status of the required name is posted for channel `testing` only. `dispatch-dx.sh` takes the run from the URL that `gh workflow run` prints (the dispatch API returns the run id when the request sets `return_run_details`, `gh` 2.87.0 and later sends it and prints the URL when stdout is not a terminal; the job prints `gh --version`: the runner had 2.103.3 on the first real run), checks event and branch (NOT the title: a fresh run is still titled with the workflow name for a few seconds, and the first real run was rejected by a title check), and falls back to a snapshot of the run ids taken BEFORE the dispatch when no URL is printed (a new run on the branch titled with the run-name or the workflow name; the title never fails the step). `dispatch_dx` turns the whole `Build container image` run red when it fails; that is meant for "no dx run appeared" or "the run is not a dispatch on this branch" (re-run the job alone), and was wrongly triggered once by the title race of the first version; no clock. A failure to write the step summary never fails the step (the first version failed in CI because the runner's summary file is not writable for the test user; `tests/dispatch-dx.sh` isolates `GITHUB_STEP_SUMMARY`).
- **First runs.** The dispatch path first runs on the first `testing` build after the merge (the file on the ref is used, no wait for a promotion). Only that run shows: that a `GITHUB_TOKEN` dispatch starts a run, the run-title lookup, the dynamic check name, and the old `workflow_run` run skipping.

## Recipe idempotency rules found by the audit (2026-11-14)

- A second run changes nothing and says so; interrupted runs leave nothing behind (temp files removed by an EXIT trap with `exit 130`/`143` for INT/TERM: `flatpak-preinstall`, `gaming-setup` gamemode, `scheduler`).
- A step NAMED on the command line means "run it", never "replace my edited file": the replace question stays (default no); `--yes` answers the default. `gaming-setup gamemode` keeps the FIRST backup pointer (`gamemode.backup`), so `reset` restores the original file after any number of replacements.
- `toolbox`: the FIRST `conf ...` record is kept (it is what `--remove` restores), only `conf-value` follows later changes; a directory is recorded as created only after the installer succeeded and the directory exists (`note_dirs` / `confirm_dirs`); `--recreate` validates the definition and pulls the new image before it removes the box.
- `dev --only java` sets the SDKMAN default only when none exists (a dangling `current` counts as none); `sensors-setup` does nothing (no sudo, no probe) when its module list exists, `--redetect` probes again, `--yes` never moves a hand-made `nct6775.conf`, and `hardware-setup` counts only `octarine-sensors.conf` as done; `toggle-updates enable` completes a half-enabled source (flatpak has two timers); `hardware-setup` treats `amd-cpu-gaming` as done only when `gamemode.ini` equals the shipped tuning.
- `gnome-candy` runs recipes of the `main` branch of candy-for-gnome (the repository gnome-themes was renamed; the old URL redirects) as the user, so a new revision is shown (commit, date, author, subject) and approved once (default no; the approved sha is `~/.local/state/octarine-os/gnome-candy-approved`); `CANDY_FOR_GNOME_REF=<full sha>` pins, `CANDY_FOR_GNOME_TRUST=1` skips the question (automation), `CANDY_FOR_GNOME_URL` overrides the repository (default `https://github.com/redcodeworks/candy-for-gnome`); the old `GNOME_THEMES_*` names are gone, no alias; without a terminal and without either it stops and says how. An old `~/.cache/gnome-themes` is unused after the rename (the checkout lives in `~/.cache/candy-for-gnome/repo`) and can be deleted.
- Deliberately NOT changed: the `fido-key` probe (a non-empty `u2f_keys` counts as done): the step writes the file by replacing it, so a stricter probe would make it overwrite another key's entries.
## Kernel arguments are pending until the reboot (and an image update drops them)

Seen on nox 2026-11-14: `sudo rpm-ostree kargs --append-if-missing=ARG` creates a PENDING deployment of the booted image that carries ARG. A later `bootc upgrade` stages the new image from the BOOTED deployment (without ARG) and replaces the pending one, so ARG was gone after the reboot (mechanism inferred from the journal and the boot entries). Rule: reboot between applying a kernel argument and the next image update. Implementation (`system_files/usr/share/octarine-os/lib/kargs.sh`, sourced the way `menu.sh` is, tests `tests/kargs.sh` and the cases in `hardware-setup.sh`, `virthost-setup.sh`, `switch-image.sh`, `update-services.sh`): `hardware-setup` (amd-kargs) and `virthost-setup` (iommu) print `kargs_notice` after a successful apply (reboot first, why, the exact `grep` on /proc/cmdline); `kargs_pending_change` reports a pending change by comparing the running arguments (/proc/cmdline) with `rpm-ostree kargs` (the next boot's) and, when `rpm-ostree status --json` has `.deployments[0].booted`, requires that the newest deployment is not the booted one; the JSON exposes no per-deployment kernel arguments, so nothing else is read, and without the field the comparison alone decides (BOOT_IMAGE=, initrd= and ostree= are ignored; a one-boot edit in the GRUB menu only counts while a pending deployment exists). `ujust update` (image source; new `--yes`) and `ujust switch-image` print a WARNING with the change and ask (default no; `--yes` goes on with the warning printed; `--no` is the plan); a declined image update skips only the image source. `hardware-setup --list` shows a karg step that is in the next boot's arguments but not the running ones as `pending reboot`, `virthost-setup` says so in its iommu step. Not covered: the automatic update staging (a timer) cannot ask, only the notice warns about it; a `bootc upgrade` typed by hand.

## Publishing latest (one image at a time)

Revised 2026-11-16 (Kevin, decision A; it replaced the design of 2026-11-14 that moved the default and dx `latest` as ONE pair, so that a dx build that failed on a new
base held the default image back). Model in one sentence: **each image publishes its own `latest` after its own signed build (or its own promotion by retag on
main); the images never wait for each other.** The default image (`octarine-os`), the dx image (`octarine-os-dx`) and the gx image (`octarine-os-gx`) are the three, `octarine-os-gx` is the newest
(variant PR of 2026-11-16); the NVIDIA images are untouched (they have their own bare `latest` in their own workflows, and the NVIDIA build reads `octarine-os:latest`).

- **Tags.** A build or promotion on main publishes only `latest-<sha7>`, `latest-<date>-<sha7>`, `<date>-<sha7>` and the same-day aliases `<date>` and
  `latest-<date>` (`just generate-build-tags <image> latest false` is that list: the third parameter drops the bare `latest`). The dx run on channel `latest` pushes and
  promotes `latest-<date>-<sha7>` only. `<sha7>` tags are not immutable (a daily rebuild of the same commit rewrites them), which is why every hand-over is by DIGEST.
- **Hand-over to dx (and gx, the `dispatch_gx` job beside it with the same digest).** The `dispatch_dx` job of `build.yml` passes the digest this run published or promoted (`needs.build_push.outputs.digests ||
  needs.promote.outputs.digests`; empty for a docs-only merge or an unchanged scheduled run) to `dispatch-dx.sh latest <sha> <digest>`, which sets the `base_digest` input of
  `build-dx.yml`; `plan-dx.sh` with `BASE_DIGEST_PIN` builds on exactly that digest (exists, hashes to itself, signed); without a pin it uses the digest of the
  current default `latest` (nothing new: the plan normally skips). dx is dispatched at once, it does not wait for the default image's `publish`.
- **`Publish latest`** (`publish-latest.yml`, `publish-latest.sh`, test `tests/pipeline/publish-latest.sh`): ONE script, ONE image per call (`IMAGE` default|dx|gx), a reusable
  workflow plus `workflow_dispatch`. Callers: the `publish` job at the end of `build.yml` (main only: `needs: [build_result, build_push, promote, sign]`, `if` a green
  result and a digest from this run; it is skipped for a docs-only merge, an unchanged scheduled run and on testing, so `latest` moves under the same conditions as before:
  a push to main (promotion or build), the daily schedule and a dispatch on main) and the `publish` job of `build-dx.yml` (main, channel latest, not a dry run, green
  `dx` and `dx_result`, a dx digest from this run). Dispatch: `gh workflow run publish-latest.yml --ref main -f image=<default|dx> [-f tag=<dated tag>] -f reason=...` (the
  default image without a tag takes the newest main commit that has a published `latest-<sha7>`; a variant needs its tag); `dry_run` plans only.
  What it verifies, with `cosign.pub` (a read error is a failure, not "unsigned"): the candidate digest is signed; for the default image its `revision` label is a commit
  of main (an ancestor of `origin/main`); for a variant its `org.opencontainers.image.base.digest` label is a SIGNED default image (checked at that digest) whose
  `revision` is a commit of main. Then the ordering guard, then `skopeo copy --all --preserve-digests` to `:latest` (retried), a read-back with `registry-settled.sh` and a
  signature check of the moved tag. Idempotent: `latest` already on the digest is a green no-op. No `signing` environment (it never signs, so no secret is needed), writes
  only on main (any other ref is forced to a dry run), one concurrency group PER IMAGE (`publish-latest-<image>`, shared with `rollback-latest.yml`), never cancelled; in a
  called workflow `github.event_name` is the CALLER's event, so the triggers are told apart by input names.
- **Independence, on purpose.** The variant's base need NOT be the default image's `latest`: a dx publish can find a default digest that is not under `latest` yet (the default
  `publish` has not run, failed or was held) and still moves dx; and a default publish never looks at dx. The only requirement is that the base is a signed default image built
  from main. Consequence accepted by Kevin: for a short time (or until a failed default publish is re-run) `octarine-os-dx:latest` can stand on a newer default image than
  `octarine-os:latest`.
- **Ordering guard (per image).** A re-run of an old green run must not move `latest` backwards: the candidate is held (a notice, exit 0) when its `revision` is an ancestor
  of the one under that image's `latest`, or the same commit built earlier (label `created`). It compares the labels, no walk through the tags. An unreadable `latest` or label
  fails the run.
- **First run and failure modes (not seen on main yet).** After the promotion that carries this change: (1) the first main run builds or promotes the default image, its
  `publish` moves `octarine-os:latest`; `dispatch_dx` and `dispatch_gx` start dx and gx at the same time, and dx's own `publish` moves `octarine-os-dx:latest` when dx is built or promoted, in either
  order, because neither looks at the other `latest`. (2) `latest` under both images is on a pair from the old design: the guard compares each image with its OWN
  `latest`, so nothing is held wrongly. (3) A dx publish whose base default image was not yet `latest`: moves (see Independence). (4) The reverse (default published, dx not):
  the default `latest` moves, dx stays on the previous image until a green dx run (dx's plan sees its `latest` has another base and builds). (5) Default build fails: no
  `publish`, no dispatch; the `alert` job (label `ci-failure-default`) opens an issue. (6) Default `publish` fails (an unreadable registry, an unsigned digest): the build job
  is green, `publish` is red, the `alert` job (it also needs `publish`) opens the issue, re-run the failed jobs (idempotent). (7) dx build or `publish` fails: `ci-failure-dx`
  issue, the default image is NOT held back, re-run the failed dx jobs. (8) Old green run re-run later: held by the guard. (9) A publish that cannot run on a stale `main`
  checkout: the workflow fetches `origin/main` itself. The daily schedule: `plan-skip.sh` reads the default `latest`, so a default publish that failed is retried by the next
  daily run.
- **Issue on failure, no duplicates.** The `alert` job of `build.yml` (label `ci-failure-default`) and the one of `build-dx.yml` (`ci-failure-dx`) each run `ci-issue.sh fail`
  on any `failure` among their needs (which now include their image's `publish`) and `ci-issue.sh recover` (comment, close) when their run is green and nothing failed or
  was cancelled; one open issue per label, a comment per further failure. The old `recover` job of `publish-latest.yml` was removed (it closed one label for either image).
  A failed `dispatch_dx` (no dx run exists) is not covered: the red job on the base run is the signal.
- **Consumers.** `ujust switch-image` and `bootc upgrade` see `latest` after the image's own publish; `build-nvidia.yml` uses `octarine-os:latest`; `plan-skip.sh` reads
  `latest`. The hub's `scripts/scheduled-runs.sh` judges the newest `build-dx.yml` run on main and the age of `latest`.
- **Pipeline-only files** (`dispatch-dx.sh`, `publish-latest.sh`, `ci-issue.sh`, `publish-latest.yml` and their tests) are in neither input hash
  (`is_pipeline_only` in `inputs-hash.sh`): changing them rebuilds neither image. The prebuilt binaries are no special case: the octarine-bins digest pin in the Containerfile is an ordinary default-image input, so a bump rebuilds the image on testing (the hash is the same one main compares to promote the tested image, so main only promotes it; `latest` of the binaries moves only in the promote job).
- **Prune.** `prune-daily.yml` protects the digest behind EACH image's own `latest` (octarine-os, -dx, -gx) and the default digests that the variants' `latest`
  stand on (their base label); a failed lookup stops the run.
- **Unverified until a real run:** every publish on main (first run of the single-image rule and the per-image groups), that `workflow_call` with `inputs.image` in the
  concurrency group works as expected, the alert and recover steps, and the dispatch inputs.

- **Rollback of `latest` (`rollback-latest.yml`, 2026-11-14, per image since 2026-11-16).** Publish latest never moves `latest` backwards, so the sanctioned rollback is a dispatch on main:
  inputs `image` (default|dx), `tag` (a dated tag OF THAT IMAGE: `latest-<sha7>`, `latest-<date>-<sha7>`, `<date>-<sha7>`), `reason` (required) and
  `dry_run` (default TRUE; any ref but main is a dry run whatever the input says). First job `Cancel window`: 30 seconds (none in a dry run), cancel the run to stop it. Then
  `publish-latest.sh` with `ALLOW_BACKWARDS=true` (same script, same verification; only the ordering guard is skipped and the summary says `ROLLBACK`), the concurrency group
  `publish-latest-<image>`. Only that image moves: to roll back both, run it twice. A failed rollback raises no issue (the red run is the signal). The next green build of that image on main moves `latest`
  forward again: after a rollback fix main, or hold the daily build. Tests: `tests/pipeline/publish-latest.sh` (ALLOW_BACKWARDS case). UNVERIFIED: a real rollback. GitHub only runs `workflow_dispatch` for a workflow file that exists on the default branch, so the first dry run is possible after the promotion that
  carries the file: `gh workflow run rollback-latest.yml --ref main -f image=default -f tag=latest-<date>-<sha7> -f reason=trial -f dry_run=true`.

## Base image and Fedora major upgrade

- The base is `${BASE_IMAGE}:${FEDORA_VERSION}`, default `ghcr.io/ublue-os/silverblue-main:45`. The defaults are in the
  workflow `env:` block (`.github/workflows/build.yml`) and repeated as `ARG` defaults in the `Containerfile` (keep
  them in sync); the repository variables `BASE_IMAGE` and `FEDORA_VERSION` override the workflow defaults. CI and
  `just build` pass both as build args; for a local experiment `FEDORA_VERSION=46 just build` works.
- **Floating base with safeguards (2026-11-14; Kevin chose to keep the base FLOATING so `latest` keeps getting base fixes daily).** `.github/scripts/base-pin.sh`
  (step `Check the base image can be pulled` of `build.yml`) resolves `${BASE_IMAGE}:${FEDORA_VERSION}` to a manifest digest ONCE at the start of
  the run (sha256 of `skopeo inspect --raw`), verifies its cosign signature with the vendored `keys/ublue-os-main-cosign.pub` (the key of github.com/ublue-os/main, compared
  with the upstream file on 2026-11-14: identical; the list digest, or for a manifest list the linux/amd64 child) and FAILS the build if it does not verify, with an error that
  names a rotated key as a possible cause. The build is FROM that digest (`Containerfile`: `FROM ${BASE_IMAGE}:${FEDORA_VERSION}${BASE_PIN:+@}${BASE_PIN}`, `BASE_PIN` passed by
  `just build`; a local build without it uses the tag), the pull is by digest, `BASE_INDEX_DIGEST` is the pin, and the image carries the new labels
  `org.octarineos.upstream-base=<digest>` and `org.octarineos.upstream-base-verified`; the job summary names the digest and what verified. The dx labels
  `org.opencontainers.image.base.digest` and `dx-inputs` are untouched (dx builds on OUR default image, nvidia on ours too). UNVERIFIED until the first CI run: that the base
  images of Universal Blue verify with this key at the digest the tag names. Tests: `tests/supply/base-pin.sh`.
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
  (5) FIRST bump `src/builder.env` in octarine-bins (its builder, `registry.fedoraproject.org/fedora:<N>@sha256:...`, must match `FEDORA_VERSION`), let it build and promote, and move the
  octarine-bins pin here (`just bins-bump`) in the same change. Otherwise the binaries are built against the old release's libraries; one built for release N-1 may not link on N, and only a rebuild in octarine-bins fixes that.

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
  password still works when no key is registered; no PIN is required. Enrollment and the second key are under "Security key mechanics" below.
- **Firewall:** the default zone allows named services for Sunshine, Steam streaming, GSConnect and
  Tailscale's UDP port, with the wide high-port range of the stock zone removed. A zone that names a service that does not exist makes firewalld silently fall back to the wide stock config: check a change with `firewall-cmd --check-config`.
- **sshd:** off by default; `45-hardening.conf` disables root login, X11 forwarding and TCP forwarding. Key-only login (`PasswordAuthentication no`) is not shipped: the user sets it once their `authorized_keys` works.
- **sysctl:** `vm.overcommit_memory=1`, `kptr_restrict`, `ptrace_scope`, a very high `vm.max_map_count`, SysRq enabled.
- **Kernel argument:** none in any image. `iommu=pt` used to ship in the dx image (`kargs.d/10-iommu.toml`); since 2026-11-13 it is opt-in, through `ujust virthost-setup` (it matters only for machines that pass devices through to VMs). A machine that had it from an older dx image loses it on the first image that drops the file until the step is run (`sudo rpm-ostree kargs --append-if-missing=iommu=pt`, reboot; undo `--delete-if-present=iommu=pt`). `tests/readme-defaults.sh` and `dx-smoke.sh` assert that no tree ships a `kargs.d` file with iommu, and the smoke tests of `build.yml` assert the file is absent.
- **Size and compilers:** the default image carries only `gcc`, `gcc-c++`, `make` and `binutils` since 2026-11-14 (the base had none; about 221 MiB); the dx image provides the full toolchain, and `ujust toolbox` can still create a toolbox. ROCm was removed from the image (2026-11-08): GPU compute tooling lives in a rootless distrobox, created by the `rocm` step of `ujust hardware-setup` (the dx images exclude it from the shared list too, see below).
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
- **Login shell:** zsh is installed and listed in `/etc/shells`, but it is NOT the default of new users any more
  (2026-11-10: `build.sh` no longer patches `/etc/default/useradd`, and fails the build if that file names zsh; the smoke tests of
  `build.yml` and `dx-smoke.sh` assert `SHELL=/usr/bin/zsh` is absent). Choosing it is opt-in through the `shell`
  step of `ujust user-setup` (`usermod -s`, copies `/etc/skel/.zshrc` when the user has no zsh files); `shell-setup` is planned
  to replace that step. Accounts created while zsh was the default keep it; rolling back to an image without zsh breaks them.
  Distrobox copies the host login shell, so every toolbox image a zsh user enters needs zsh (`dev-toolbox` has it; check the `gaming` one).
- **Flatpaks:** a preinstall list of apps (`system_files/usr/share/flatpak/preinstall.d`), installed by `ujust flatpak-preinstall [--dry-run]` run as the user from a desktop session (checks: not root, session bus, flathub remote, network; test `tests/flatpak-preinstall.sh`). The former root boot unit `flatpak-preinstall.service` was removed: a root service has no session bus, and on a machine installed from stock Silverblue the enabled `fedora` OCI remote asks for a token over the session bus, so `flatpak preinstall -y` failed with `Cannot autolaunch D-Bus without X11 $DISPLAY` and left a failed unit on every boot (`flatpak remote-add --disable` does not disable an existing remote; `dbus-run-session` is not shipped). The smoke test asserts the unit is not enabled and the recipe exists. Unverified: the polkit behavior for a user running it. Themes and icons are not in the image. Virtual machines: the default image preinstalls GNOME Boxes (`gnome.preinstall`; its `org.gnome.Boxes.Extension.OsinfoDb` extension has no `no-autodownload` in the app's metadata, so Flatpak pulls it with the app and no entry is needed; unverified on a fresh install) and no virt-manager Flatpak (removed 2026-11-10); the dx image has virt-manager only as the RPM (`variants/dx/packages/extras.txt`) and no Flatpak copy.

## Recipe conventions (ujust recipes in `60-custom.just` and `10-update.just`, and `70-octarine-dev.just` in the dx image)

- Every public recipe has `[group('...')]` (Setup, Gaming, Toolbox, Appearance, System; Developer in the dx image) and ONE `#` comment line that is
  its `ujust --list` description; usage text goes into `help`, `--help` or `-h` output of the recipe, not the comment.
- Body: `#!/usr/bin/env bash`, `set -uo pipefail` (`-e` only where a failing step should stop). Positional arguments only
  (`[positional-arguments]` with `*args`). Unknown option or step: usage on stderr, exit 1 (2 for option errors in the
  checklist recipes). Fail soft inside checklists: report a failed step, go on, exit non-zero at the end.
- Emoji: `lib/emoji.sh` (sourced by `menu.sh`, and by hand in recipes that do not source it, such as `base-pieces.just` and `motd.just`) redefines `echo` so a
  line that starts with a message word (ERROR, WARNING, Needs:, Done, Removed, Updated, "... is now ..." and so on, see the mapping in the file) gets one
  emoji first. Only on a terminal (stdout `-t 1`); off for a non-empty `NO_EMOJI` (an empty one does nothing, like NO_COLOR), non-empty `OCTARINE_PLAIN` other than 0,
  and TERM empty or dumb. Never touches menus, pickers, data lines, indented lines, `--help` (printf) or captured output. `OCTARINE_FORCE_EMOJI=1` skips only
  the terminal test (tests/emoji.sh). It is launcher-neutral: any launcher that runs the recipes gets it.
  Without it by design (2026-11-16): `logs-this-boot`, `logs-last-boot`, `changelogs`, `update-firmware` (pass-through of journalctl and tools), the empty or wrapper-only
  `15-luks`, `40-nvidia`, `50-akmods`, `00-default`, `10-update`, `30-distrobox` files (no message lines of ours), and the output of the datastore bundle (octarine-images repo); `72-octarine-datastore.just` loads it for its own lines.
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
  Esc at any menu or an empty checklist exits 0 with "nothing changed" (tested for `switch-image` and `luks-tpm-unlock` with a
  fake `ugum`/`gum` that returns nothing). No aliases when a recipe is renamed or merged (the two LUKS names are gone).
- The `#` description must sit directly above the `[group(...)]` line of its recipe: a recipe inserted between them leaves
  the other recipe without a description (`toolbox` lost its once). `tests/just-recipes.sh` assembles the image's just files
  like the base `justfile` does and fails on any public recipe without a description.
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
  | (image only, 2026-11-15) | `[org/gnome/desktop/wm/preferences] button-layout='appmenu:minimize,maximize,close'` | included | owner wants minimize and maximize by default (stock GNOME: `appmenu:close`); a user-set value wins, the owner's own `icon:...` layout is personal and not copied |
  | | `color-scheme`, `gtk-theme`, `icon-theme`, `monospace-font-name` | excluded | visual theme and font taste, themes come from candy-for-gnome |
  | | `font-antialiasing='rgba'`, `font-hinting='full'` | excluded | depend on the display, differ from the GNOME default |
  | | `enable-animations`, `text-scaling-factor`, `toolkit-accessibility` | excluded | equal to the GNOME default, no effect |
  | `30-enable-extensions.sh` | AppIndicator, GSConnect | included | shipped RPMs, GSConnect has a firewall service in the image |
  | | caffeine, dash-to-dock, auto-move-windows, user-theme | excluded | shipped but change the look or need personal data (Auto Move needs an app list, the dock is visual, caffeine adds a panel icon, user-theme is useless without a theme) |
  blur-my-shell is no longer shipped at all (removed 2026-11-13; the owner installs the upstream release as a user extension, which shadows a system copy and which Extension Manager refuses to install over). On an existing machine the system copy disappears with the image update; a user copy and the dconf settings under `/org/gnome/shell/extensions/blur-my-shell/` stay untouched, and if it was enabled from the system copy with no user copy GNOME just lists it as missing. Nothing else in the image referenced the package (no dconf default, schema override, extension-enable list, preset or test).
  | | GPaste (`gpaste`, `gnome-shell-extension-gpaste`, extension `GPaste@gnome-shell-extensions.gnome.org`) | shipped, not enabled | optional `misc` group; the daemon is D-Bus activated (no unit to enable); switch on with `gnome-extensions enable GPaste@gnome-shell-extensions.gnome.org`; default shortcuts Ctrl+Alt+H (history) and Ctrl+Alt+G (UI) |
  | | Just Perfection, ddterm, Freon (`gnome-shell-extension-just-perfection`, `-ddterm`, `-freon`) | removed 2026-11-13 | no longer shipped (the owner installs them as user extensions, which shadow a system copy); nothing else in the image referenced them (no dconf default, enable script or helper text; `lm_sensors` stays for `ujust sensors-setup`); the smoke tests assert they are NOT shipped; user copies and their dconf settings stay untouched on existing machines |
  | | arcmenu, hotedge, coverflow, tiling shell | excluded | not shipped |
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
  | | `desiredgov=performance`, `[custom]` tuned profile | excluded from `/etc` | governor choice and AMD amd-pstate behavior and needs tuned; stays in the `gaming-setup` user file |

- **User-facing notes (formerly in the README's "Defaults" section).** GNOME: hot corners off, minimize and maximize buttons, AppIndicator and GSConnect on;
  `gsettings reset <schema> <key>` returns a key to the image default. fish: a user file of the same name disables a snippet (see
  Paths). GameMode needs the user in the `gamemode` group (`ujust user-setup` adds it). The files are `/etc/dconf/db/distro.d`,
  `/etc/gamemode.ini` and `/usr/share/fish`.
- **Refreshing a default from dot-files.** Read the dot-files file, apply the selection rule again, edit the shipped file
  by hand (nothing is generated), run `tests/system-defaults.sh`. The image never copies dot-files wholesale.
- Tests: `tests/system-defaults.sh` (placement and modes, `dconf compile`, `fish --no-execute`, snippet behavior in a temp HOME,
  INI parse, build step, smoke checks in `build.yml`, and a grep that no excluded category is shipped).
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
- **Promoted defaults (2026-11-15, Kevin's list from his own niri files).** `20-input.kdl`: niri's tap and natural scroll plus `drag-lock`, `click-method "clickfinger"`, `scroll-factor 0.3`.
  `30-layout.kdl`: centered focus on overflow, `always-center-single-column`, presets 0.25/0.33333/0.5/0.66667/0.75, third-width default column, shadow on with `draw-behind-window`, 32 pixel struts,
  the left tab indicator (hidden with one tab), `hotkey-overlay { skip-at-startup }`, an empty `animations {}`; the COLORS stay niri's own (focus ring `#7fc8ff`, default insert-hint color, no Gruvbox gradient:
  the image is theme neutral; the owner can ask for his gradient). New `35-gestures.kdl` (edge scroll, edge workspace switch, hot corners off) and `45-workspaces.kdl` (named workspaces General, Web, Media, Games).
  `50-noctalia.kdl` keeps the shipped binds and adds the Noctalia look (rounded corners with clipping, blur without xray, the settings window rule, the wallpaper on the backdrop, transparent workspace
  background, no overview workspace shadow, the layer rules, the global blur fine-tuning, and `debug { honor-xdg-activation-with-invalid-serial }`, which weakens niri's focus-steal protection and is commented as such);
  everything is documented in niri 26.04's wiki (`/usr/share/doc/niri/wiki`) and accepted by `niri validate`; Noctalia's own docs were not read. `60-window-rules.kdl`: niri's two defaults, the dialog-title float rule, block-out-from
  screen-capture for KeePassXC and GNOME Secrets, and a routing rule per app of the Flatpak preinstall lists (Web: Firefox; Media: Thunderbird, Calendar, Contacts, Music, Decibels, Podcasts, Showtime, Loupe, Snapshot,
  Weather, Maps; General: Boxes, Builder, Connections, Deja Dup, File Roller, Firmware, Logs, Papers, Simple Scan, Text Editor, Disk Usage, Clocks, Flatseal, Extension Manager, Bazaar; floating utilities: Calculator, Characters,
  Font Viewer, the Nautilus previewer), the Games launchers of `gaming-setup` (Steam, Lutris, Bottles, ProtonUp-Qt) and floating pavucontrol, blueman and nm-connection-editor. UNVERIFIED app ids: no id was checked under niri
  except Firefox, Steam and WezTerm (the owner's earlier checks); the GNOME apps follow "a GTK app reports its application id"; Vorta (Qt) is deliberately unrouted (`// unrouted: com.borgbase.Vorta`). Not promoted: outputs,
  `debug.kdl`, keybinds, the HHKB layer, Gruvbox colors, the owner's Mod+Comma and Mod+D, his personal apps, the terminal opacity rule, the gamescope and `steam_app` rules. `tests/niri-setup.sh` checks every
  preinstall app has an entry in the rules part, so a new preinstall app cannot be forgotten.
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
- **Recipe.** Group Setup; steps `niri`, `portals`, `polkit` and the experimental `keybinds` (own bullet below); `--yes`, `--no` (plan only), `--only STEP[,STEP]`, `help`; the shared
  checklist helper (a step chosen in it is not asked "Apply?" again); each file is idempotent (identical = "already done"), a different
  existing file shows a diff, the replace question defaults to keep (also under `--yes` and with no answer to read) and a yes saves
  `<file>.bak-YYYYMMDD-HHMMSS` first; the `polkit` step skips without `noctalia` on PATH; a failed step is FAILED with its re-run command, exit 1;
  option errors exit 2; no sudo. Test hook: `OCTARINE_NIRI_SETUP_SRC` (a tree with `niri/*.kdl`, `niri-portals.conf`, `10-octarine-os.toml`).
  Test: `tests/niri-setup.sh` (fake gum, ugum, noctalia, sudo, temp HOME; `niri validate` of every include combination when niri exists; a guard
  that `ghostty` and `ptyxis` appear in no shipped niri file). The smoke checks in `build.yml` look for the files.
- **User-facing notes (formerly the README's "Niri session" section).** Without a user config niri falls back to the shipped files. To
  drop the shipped key bindings delete the `include "40-binds.kdl"` line of `~/.config/niri/config.kdl` (any other include line drops that part).
  A different existing file is never replaced silently: the user sees a diff, the default is keep, and a replacement saves
  `<file>.bak-<date>-<time>` first. Undo: delete the files the recipe printed; niri then uses the shipped fallback again.
- **Keybind wizard (EXPERIMENTAL, step `keybinds`; Kevin 2026-11-10).** Never part of the default run: `--yes` alone and the checklist
  (entry "Keybind wizard (experimental)", not preselected unless wizard flags were given) leave niri's default binds
  (`40-binds.kdl`) alone; the opening question is "Start the keybind wizard (experimental)?" (default NO) after one experimental notice;
  help text, menu entry, question, notice and this file say experimental (layouts and generated files may change between image versions; the
  result is checked with `niri validate`, the previous files are restored on failure, niri's defaults are one `include` away).
  - **Flow.** Layout (single choice): Standard (always included), Compact (adds vim-style hjkl and u/i) or HHKB (mutually exclusive
    extras), then the modifier for SWITCHING (focus; default Ctrl+Alt), for MOVING (default Ctrl+Super, or Ctrl+Alt when switching is
    Ctrl+Super; the same modifier as switching is refused with a message and asked again) and for OTHER actions (default Super, written
    `Mod`). Options: `ctrl-alt`, `ctrl-super`, `meh` (`Ctrl+Alt+Shift`), `hypr` (`Ctrl+Alt+Shift+Super`), `super` (other actions only).
    MEH and HYPR are custom QMK mappings most keyboards lack: they carry the note "needs these keys mapped in your keyboard firmware (a custom
    QMK mapping); most keyboards do not have them" in every menu and are NEVER the default, also not for HHKB (the defaults do not depend on
    the layout). niri has no MEH or HYPR token, so they are plain modifier strings. Esc cancels (exit 0, nothing changed); plain numbered
    prompts replace the `ugum` menu without a terminal.
  - **Non-interactive.** `--keybinds standard|compact|hhkb`, `--switch-mod`, `--move-mod`, `--other-mod` (`ctrl-alt|ctrl-super|meh|hypr`,
    `super` for `--other-mod` only; `--name=value` works), `--no-wizard`; any wizard option runs the wizard without questions (missing ones take
    the defaults, a missing one avoids the other's value). `--yes` alone = NO. Unknown names, an equal switching and moving modifier and
    `--no-wizard` with options exit 2. `--no` prints the plan only.
  - **Templates** `system_files/usr/share/octarine-os/niri-setup/keybinds/{standard,compact,hhkb}.kdl.in` with `@SWITCH@`, `@MOVE@`,
    `@OTHER@` replaced by `sed`. Key-partition rule that makes duplicates impossible by construction: SWITCH and MOVE own arrows, Page_Up/Down,
    Home, End, 1-9 and the wheel (Standard), h j k l u i (Compact) or Semicolon Slash P Apostrophe K L J U (HHKB); OTHER uses only keys outside
    those sets (T O Q R B Y X F G M N C Z A V W E, brackets, Comma, Period, Minus, Equal, Backslash, Grave, Escape, Backspace), so the roles
    may share a modifier without sharing a key combination; a new bind must stay inside its role's key set. If an extra layout ever collided
    with Standard, the extra layout changes, never a silent drop.
  - **Deviations of the wizard's Standard part from niri's defaults.** F1 shows the hotkey overlay (not Mod+Shift+Slash); Shift and Ctrl variants
    of the `Mod` binds got their own keys (fullscreen G, preset width back B, preset height Y, reset height X, expand column N, center visible Z,
    window height A and Backslash, floating focus switch Grave, quit E, power off monitors Backspace); the monitor binds (focus or move to a
    monitor, move workspace) and the Shift+wheel binds are not generated (a modifier that already holds Shift cannot take another Shift; use niri's
    defaults for them); Noctalia's binds stay on `Mod` (`50-noctalia.kdl` is unchanged and comes after the generated parts, its keys Space D S
    Shift+S never overlap).
  - **HHKB layout, derived from the owner's dot-files `config.example.kdl` (keys and roles only).** Included: the focus and move cross on the
    right hand (Semicolon left, Apostrophe right, Slash down, P up; the owner has `[` up, which Standard's consume-or-expel keeps), first and last
    column on K and L, workspace down and up on J and U (owner: Period and L). Excluded: ghostty, yazi, helix, btop, zellij, nvtop, lnav, lazydocker,
    gdu, ipython, Firefox and fuzzel launches, the volume and media keys on Super+Alt letters, swaylock, workspace names and routing, window rules,
    Mod+G, Mod+Delete/Backspace close, the owner's MEH/HYPR fixed assignments (now the three placeholders).
  - **Output.** `~/.config/niri/40-binds-standard.kdl` and `41-binds-compact.kdl` or `41-binds-hhkb.kdl`; the `include "40-binds.kdl"` line of
    `config.kdl` (or the generated lines of an earlier run) becomes `include "40-binds-standard.kdl"` plus the extra include, backup
    `config.kdl.bak-<date>-<time>`; a `config.kdl` without such a line gets the lines before `include "50-noctalia.kdl"` only after a diff and a
    question (default keep, also under `--yes`). A re-run regenerates: identical = already done, a different generated file shows a diff (default
    keep, backup on yes), and a kept file leaves `config.kdl` alone. A previous `41-binds-*.kdl` of another layout is left in place, unincluded.
    With no `~/.config/niri/config.kdl` yet the step is skipped (run the `niri` step first). After writing it runs `niri validate -c
    ~/.config/niri/config.kdl` when niri is on PATH; on failure it restores every touched file from a snapshot, removes this run's backups,
    reports FAILED (exit 1, re-run hint); without niri it says validation was skipped.
  - **Terminal for Mod+T (step `terminal`, 2026-11-15, Kevin: Alacritty stays the default).** The shipped `/etc/niri/40-binds.kdl` and the templates keep Alacritty (the
  guard in `tests/niri-setup.sh`: no ghostty, ptyxis, kitty or foot in any shipped niri file; `60-window-rules.kdl` has niri's own default rule for the WezTerm app-id, the one exception). The step
  (`--terminal alacritty|ptyxis|ghostty|kitty|wezterm|foot`, `--force`, or a picker in the checklist; `--yes` alone and `--no` change nothing) edits ONLY the user's copies: the one uncommented
  `<modifier>+T ... spawn` line of `~/.config/niri/40-binds.kdl` and of `40-binds-standard.kdl` (the wizard's file), and records `terminal=<name>` in `~/.config/octarine-os/niri-terminal`
  (a state file, because the wizard has to know the choice before any bind line exists; without it the choice is read back from the bind line). Detection: the binary on PATH, else
  `/home/linuxbrew/.linuxbrew/bin`, else `~/.local/bin`; the picker lists only found terminals (Alacritty always, first) and names the missing ones; a terminal found outside PATH is spawned by
  absolute path (the niri session may not have those directories on PATH). A not-installed terminal asks (default no) or needs `--force`; unknown names exit 2. The line is rewritten only when it is
  exactly one the recipe writes (title `Open a Terminal: <name>`, `spawn "<name>"`, plus `"--new-window"` for Ptyxis); any other `+T` line is the user's: left alone, the exact line is printed,
  the step is "skipped (your Mod+T line is customized)", not a failure. Templates use `@TERMINAL_NAME@` and `@TERMINAL_SPAWN@` (only `standard.kdl.in` has the terminal bind).
  Spawn commands: `alacritty`, `ptyxis --new-window` (verified in `ptyxis --help`: "New terminal window"; the behavior with a running instance is not verified, `--new-window` makes
  a window explicit), `ghostty` (the wrapper in `~/.local/bin` or the image's future `/usr/bin/ghostty`; not verified: single-instance behavior), `kitty` (not verified here: not installed),
  `wezterm` (verified in wezterm's `main.rs`: no subcommand means `start`; Wayland on by default in its config), `foot` (not verified: the project is on Codeberg). Tests: `tests/niri-setup.sh`
  (all six, detection, unknown and missing names, `--force`, `--no`, `--yes`, idempotence, switching, the protection of a user's line, no copy yet, `niri validate` when niri exists) and
  `tests/niri-keybinds.sh` (the wizard uses the recorded choice, the step also edits the generated file).
- **"NO" is verifiable.** `40-binds.kdl` equals the `binds` block of `/usr/share/doc/niri/default-config.kdl` except Mod+D (fuzzel) and Super+Alt+L
    (swaylock) removed (the image ships neither) and the playerctl and brightness keys guarded with `command -v`; Alacritty is niri's own default
    terminal. `tests/niri-keybinds.sh` fails on any other difference.
  - **Tests** `tests/niri-keybinds.sh`: the matrix (3 layouts x 12 ordered switch/move pairs x 5 other modifiers = 180 runs of the real recipe against
    the shipped tree, each checked with the real `niri validate` and a duplicate-key parser that normalizes `Mod` to `Super`; generated plus Noctalia
    may repeat only XF86 keys), refusal and re-ask (menu and plain), never-preselected MEH and HYPR with the note, `--yes` alone, the experimental
    wording (help, menu entry, question), existing files, keep and replace with backups, restore on a failing stub niri, niri missing, the upstream
    comparison above.
  - **Unverified.** niri reading the generated files in a live session, MEH and HYPR strings on a keyboard that sends them, the HHKB key positions
    on a real HHKB, how Noctalia's `Mod` binds feel next to a non-`Mod` "other" modifier.
- **Unverified.** niri and Noctalia reading the copied files in a session, Noctalia's `msg` subcommand names (taken from the owner's dot-files),
  the portal actually attaching oo7, `alacritty` on a booted image.

## Image identity (`IMAGE_ID`, `IMAGE_VERSION`) and the fastfetch default

- Read the identity on a machine with `grep IMAGE_ /etc/os-release` (formerly a README section "Which image is this?").

- `PRETTY_NAME` stays `octarineOS` in EVERY image (default, nvidia, dx); `NAME`, `ID`, `VERSION_ID`, `VARIANT_ID` are
  untouched. The image identity goes only into `IMAGE_ID` and `IMAGE_VERSION` of `/usr/lib/os-release` (`/etc/os-release` is a
  symlink), written as quoted lines by `set_os_release_field` (replace the line if it exists, append otherwise; the same
  function is in `build_files/build.sh`, `variants/nvidia/nvidia.sh` and `variants/dx/dx.sh`, and `OS_RELEASE_FILE` is a test-only
  override of the path).
- Field values:

  | Image | `IMAGE_ID` | `IMAGE_VERSION` | Set in |
  |---|---|---|---|
  | `octarine-os` (`latest`, `testing`) | `octarine-os` | `<YYYYMMDD>-<short sha>` | `build.sh` |
  | `octarine-os-nvidia` | `octarine-os-nvidia` | its own build's `<YYYYMMDD>-<short sha>` | `nvidia.sh` |
  | `octarine-os-dx` (`latest`) | `octarine-os-dx` | its own build's version | `dx.sh` |

- The version string is `.github/scripts/image-version.sh`, the same string as the `org.opencontainers.image.version` label (the
  label). It reaches the build as the build argument `IMAGE_VERSION` (`just build` passes it; the nvidia and dx
  workflows pass `--build-arg IMAGE_VERSION`). The variants override both fields with
  their OWN build's version, never the base's. A promoted image (testing to `latest`) is a retag of the tested digest, so it keeps
  exactly the fields it was built with: that is why the version names no channel.
- Checks: the smoke tests of `build.yml`, `dx-smoke.sh` and
  `nvidia-smoke.sh present` assert `PRETTY_NAME="octarineOS"`, the right `IMAGE_ID` and the `IMAGE_VERSION` format
  (`[0-9]{8}-[0-9a-f]{7,}`). `check-version-neutral.sh` also reads the image's os-release
  `IMAGE_VERSION` (the workflows append it to the label lines): required, no `testing`/`latest`. The format is checked by the smoke scripts (the test files `image-version.sh`, `dx-image.sh` and `nvidia-variant.sh` were deleted on 2026-11-16).
- fastfetch: OUR build does not install it and must not (owner's rule; a Homebrew install is the owner's way); only a default configuration ships. On the owner's machine `/usr/bin/fastfetch` exists anyway (fastfetch-2.68.1-1.fc45, not layered): it is not in `build.sh`, the dx lists or the `packages.json` of ublue-os/main, so it comes with the upstream Fedora Silverblue set that the base image carries (to confirm with `rpm -qf /usr/bin/fastfetch`: open item for the hub); the motd script works with and without it. Default configuration:
  `system_files/etc/xdg/fastfetch/config.jsonc` (a plain file; fastfetch reads `~/.config/fastfetch/` first, then `/etc/xdg/fastfetch/`,
  so the user's own file wins). Its `Image` line prints `IMAGE_ID IMAGE_VERSION`, falls back to the booted rpm-ostree deployment where
  they are missing, and `n/a` elsewhere. Check: `default-smoke.sh` parses it in the built image (strips the `//` lines, then `jq`); the separate test file was removed (it could not catch a wrong command). Never add fastfetch to
  `build.sh` or a Brewfile.

## The motd: one script, one switch for every shell

- `/usr/libexec/octarine-os/motd` (`system_files/usr/libexec/octarine-os/motd`) is the only motd code: silent (exit 0) without a terminal on stdout, with the flag `~/.config/no-show-user-motd` (file present = off; the base image's flag), without `$HOME` or with `OCTARINE_MOTD_SHOWN` set; otherwise `fastfetch` when on PATH (it reads `~/.config/fastfetch/config.jsonc` then `/etc/xdg/fastfetch/config.jsonc`; no `--config`), else ONE random line of the base tip files `/usr/share/ublue-os/motd/tips/*.md` (one tip per line, markdown markup removed; the base's `/usr/libexec/ublue-motd` picker no longer exists in this base, so the picker is ours and reuses only the files), else `/etc/user-motd`. Never fails, no network. Test hooks `OCTARINE_MOTD_FORCE_TTY|TIPS|FILE`.
- `/etc/profile.d/user-motd.sh` (ours, same name as the base file, so the `cp` of `system_files` replaces it) calls it for INTERACTIVE shells with a terminal only (`case $- in *i*)`, `[ -t 1 ]`), once (`USERMOTDSOURCED` guard): bash and zsh login shells. `bash -lc`, scripts and `ssh host cmd` never print it.
- fish is NOT a login shell in the owner's terminals and never sources profile.d: it calls the script from the user's own greeting function, for example `~/.config/fish/functions/fish_greeting.fish`: `function fish_greeting` / `  test -x /usr/libexec/octarine-os/motd; and /usr/libexec/octarine-os/motd` / `end` (the flag is honored inside the script; the image ships no fish greeting).
- The switch: `ujust toggle-motd` ("Toggle the motd (fastfetch summary or tips) in every shell"; prints "motd is now on/off") and `ujust toggle-user-motd` (the base recipe's name, a dependency on `toggle-motd`). `build.sh` keeps the base `00-default.just` as `00-default-base.just` (the way `10-update` and `30-distrobox` are kept); our `00-default.just` imports it and defines both names (a recipe of the importing file beats the imported one); the smoke tests check that each name is listed once. Tests: `tests/motd.sh`, `tests/just-recipes.sh`.
- Only a real login shell can verify: an SSH login, a bash and a zsh login on a terminal, the fish greeting, and that the recipe wins over the base file in a real `ujust --list`.

## Failure alerts (issues) (2026-11-16: only the two that matter)

`ci-issue.sh` (one issue per streak of failures, deduplicated on the LABEL, a comment per further failure, closed by the next green run; labels are created on first use) serves exactly two alerts: the `alert` job at the end of `build.yml` (label `ci-failure-default`: the daily and promotion builds on main; the job needs plan, build_push, promote, build_result and publish, so a failed move of the default `latest` is reported there) and the `alert` job of `build-dx.yml` (label `ci-failure-dx`: a red dx run or a failed dx publish on main holds dx `latest` back silently). Each runs only on main (`github.ref`), has `issues: write` only, a `fail` step on any `failure` among its needs and a `recover` step (comment plus close) when the run's main job succeeded and nothing failed or was cancelled: a cancelled run raises nothing and closes nothing. The alert jobs of the NVIDIA build, `publish-latest.yml` (its `recover` job too: it closed one label for either image), `rollback-latest.yml`, the beta build and the prune were removed (a red run is the signal there, and the hub's `scripts/scheduled-runs.sh` lists failed newest scheduled runs). Test: `tests/alert-jobs.sh`, `tests/pipeline/ci-issue.sh`.

## Testing the next Fedora (replaces the beta channel, 2026-11-16)

The `octarine-os:beta` channel (a weekly build on Universal Blue's beta base) was removed: it was an early warning nobody read. To try the next Fedora release by hand:
`gh variable set FEDORA_VERSION --body <n> -R redcodeworks/octarine-os`, then `gh workflow run build.yml --ref <any branch other than main or testing>` (a dispatch from such a branch
builds as validation only: nothing is pushed or signed; `testing` itself publishes the `testing` image), watch that run, and `gh variable delete FEDORA_VERSION -R redcodeworks/octarine-os`
afterwards. The variable is read by every run, the daily `main` build and `test.yml` included, so do not leave it set unless the next scheduled build should use it. A real upgrade
also needs `src/builder.env` of octarine-bins bumped first and the octarine-bins pin moved (see "Base image and Fedora major upgrade").

## Overriding the base image's ujust recipes

- **Between two imported files the FIRST import wins** (just 1.59, `set allow-duplicate-recipes := true` in the base
  `justfile`, which imports `00`..`50`, then `60-custom.just`, then `70-octarine-dev.just`); a recipe of the importing file
  beats the imported one. So a recipe in `60-custom.just` can NOT replace a base recipe with the same name. Three patterns
  work: (1) ship a file of the same name that replaces the base file (`15-luks.just`, `40-nvidia.just`, `50-akmods.just`);
  (2) wrap it: `build_files/build.sh` renames the base file to `<name>-base.just` before copying `system_files`, and ours
  (`10-update.just`, `30-distrobox.just`) `import`s it and redefines single recipes (a missing base file fails the build, the
  signal that the base changed its layout); (3) a new recipe name. Aliases of the base (`upgrade`, `auto-update`) keep
  working because they resolve after all imports.
- **Our files that stand in for base files (hub-facing, recorded 2026-11-09).** `10-update.just`, `15-luks.just`,
  `30-distrobox.just`, `40-nvidia.just` and `50-akmods.just` under `system_files/usr/share/ublue-os/just/` are OUR files, not
  the base's. On the image the base's `10-update.just` and `30-distrobox.just` are renamed `10-update-base.just` and
  `30-distrobox-base.just` (build.sh) and imported by ours; the base's `15-luks.just`, `40-nvidia.just` and `50-akmods.just`
  are overwritten by ours (not renamed, so nothing of them survives): `15-luks.just` and `40-nvidia.just` are empty on
  purpose (the base's `setup-luks-tpm-unlock`, `remove-luks-tpm-unlock` and `toggle-nvk` are gone, no aliases, no stub),
  `50-akmods.just` is comment-only too (the base's `configure-broadcom-wl` and its `broadcom-wl` alias are gone: the image ships no `wl` module). The base package builds `/usr/share/ublue-os/justfile`
  with one `import` per file name it ships, so the same names keep being imported. Do not tell people to edit the base's
  versions of these five files; verify with `just --justfile /usr/share/ublue-os/justfile --summary` (the smoke test does).
- **EXPERIMENTAL second launcher `ojust` (maintainer note only; deliberately undocumented elsewhere, Kevin 2026-11-15; a test checks that no README, doc or user-facing text mentions it).** `/usr/bin/ojust` runs
  `just` with `JUST_JUSTFILE=/usr/share/octarine-os/justfile` (the mechanism `ujust` uses) and sets `OCTARINE_UJUST=/usr/bin/ojust` so `hardware-setup`'s self-calls stay in ojust. Its root justfile imports
  ONLY our files, never one of Universal Blue's `ublue-os-just` package, so it works on a base without that package: `15-luks`, `40-nvidia`, `50-akmods`, `60-custom` and the dx files (same files as ujust), plus
  `/usr/share/octarine-os/just/{motd,update,base-pieces}.just`. To make that possible the image's own `toggle-motd`/`toggle-user-motd` and `update`/`toggle-updates` moved out of the wrapper files
  `00-default.just` and `10-update.just` into `motd.just` and `update.just`; the wrappers now import those FIRST and the renamed base file second (first import wins), so ujust resolves exactly the same
  recipes (verified by comparing `just --dump --dump-format json` of the assembled root before and after: identical). `base-pieces.just` is ojust-only: copies of the package's `bios`, `bios-info`,
  `logs-this-boot`, `logs-last-boot`, `enroll-secure-boot-key`, `check-local-overrides`, `device-info`, `changelogs`, `update-firmware`, `clean-system` and the aliases (Apache-2.0, attribution in its header);
  NOT copied: `check-idle-power-draw`, `distrobox-assemble`, `distrobox-new`, `install-resolve`, `setup-distrobox-app` (they need `/usr/lib/ujust` helpers). The three helper libraries are NOT copied: no file
  ojust imports sources them, and `ugum` is only an optional menu helper (`menu.sh` falls back without it). Keep new recipes free of `/usr/lib/ujust` sourcing and of imports of base files.
  `30-distrobox.just` stays a ujust-only wrapper. Smoke (`build.yml`): `ojust --list` works, lists `toggle-motd` and `niri-setup`, no `-base.just` import.
- **Hiding** a base recipe: redefine it `[private]` (hidden from `ujust --list`, still runnable) in a file that wins:
  `setup-distrobox-app` (its only entry is an NVIDIA PyTorch container) in `30-distrobox.just`, (`configure-broadcom-wl` is removed outright, see above). `enroll-secure-boot-key` stays visible: the NVIDIA variant needs it.
  `install-resolve` stays: it asks for no host `sudo` (the only `sudo` in the pinned davincibox script runs inside the
  rootless container).
  `tests/toolbox.sh` requires that no executable `sudo` appears after the `toolbox` recipe in `60-custom.just`, so new
  recipes go BEFORE the `[group('Toolbox')]` line.

## `ujust toggle-updates` and `ujust update`

- Both live in `system_files/usr/share/octarine-os/just/update.just` (imported by the wrapper `10-update.just` and by ojust's root) and share `system_files/usr/share/octarine-os/lib/update-services.sh`, the one table of
  sources: `image` (`rpm-ostreed-automatic.timer`, stages the image), `flatpak` (system `flatpak-system-update.timer` plus
  user `flatpak-user-update.timer`), `distrobox` (user `octarine-distrobox-upgrade.timer`, shipped here, off by default),
  `brew-update` (`brew-update.timer`), `brew-upgrade` (`brew-upgrade.timer`, off by default by `00-octarine-brew.preset`).
  A source is on when any of its timers is enabled.
- `toggle-updates` is a checklist (`menu_multi`, ticked where on; unticking everything asks first) or
  `enable|disable|status [SOURCE...]`; system timers need sudo (one call per direction), user timers do not.
  `update` runs exactly the sources that are on (`--all` runs every source, naming sources runs those, `--no` prints the
  plan), a failing source does not stop the others. The image step is `sudo bootc upgrade`, or `sudo rpm-ostree upgrade`
  when the booted deployment has layered packages (bootc does not know about layering).
- The base `update` also ran `rpm-ostree update`, `flatpak update` and `distrobox upgrade -a` unconditionally and checked
  for `uupd` (not installed here); both are replaced.

## Hardware targeting (what is set only where the hardware is)

- `system_files/etc/profile.d/proton.sh` exports `PROTON_FSR4_UPGRADE=1` only when a DRM card has vendor `0x1002` (AMD), by a bash
  glob loop with no subprocess (it runs at every login shell; `OCTARINE_SYSFS_DRM` redirects sysfs in tests). `PROTON_ENABLE_WAYLAND=1`
  stays for everyone but is experimental and reported rough on NVIDIA. fish has no equivalent file (fish does not read `profile.d`).
- GameMode's `desiredgov=performance` (the packaged default; Kevin, 2026-11-14) replaces the `powersave` workaround for upstream gamemode#419: the shipped `gamemode.ini` carries it and `gaming-setup gamemode` writes the same file on every CPU and driver, with no pstate-dependent step. Known issue kept as a comment in the file: with amd-pstate in active mode the performance governor also forces EPP to `performance` and GameMode may not restore it (reproduced upstream on 1.8.2, not confirmed here); undo is `desiredgov=powersave`. No `[gpu]` pinning. `GAMING_SETUP_PSTATE_STATUS` is now read only by `hardware-setup` (its `amd-cpu-gaming` step still hides without amd-pstate active).
- `switch-image nvidia|nvidia-dx` without an NVIDIA GPU (`0x10de`): says so and asks (default No); `--yes` alone refuses, `--force` proceeds.
- `luks-tpm-unlock` exits 0 with a message when `/dev/tpmrm0` is missing (`OCTARINE_TPM_DEVICE` in tests).
- `luks-tpm-unlock` is idempotent by END STATE (Kevin, 2026-11-14), not by detect-and-skip: every apply runs ONE call, `systemd-cryptenroll DEV --tpm2-device=auto --tpm2-pcrs=... --wipe-slot=tpm2 [--tpm2-with-pin=yes]` (enrollment first, then the old TPM2 slots are wiped and the new one is excluded: `man systemd-cryptenroll`), whether or not a TPM2 key exists. A probe (a `systemd-tpm2` token in `cryptsetup luksDump`) only sets the DEFAULT of the checklist: enrolled volumes are not ticked and `enroll --yes` without devices leaves them alone; naming a device or `--force` (every volume) re-enrolls. NEVER a wipe other than `tpm2` (no `--wipe-slot=all`, no keyslot numbers): two of Kevin's volumes were once left TPM-only by an `all` wipe. The recipe REFUSES (before running anything, per volume, exit 1) to enroll or remove on a volume whose keyslots all belong to a `systemd-tpm2` token, or whose header is not LUKS2 (cannot be checked), and prints `sudo systemd-cryptenroll DEV --recovery-key --unlock-tpm2-device=auto`. PCR choice unchanged: 7+14 by default (Secure Boot state plus the MOK keys, so any MOK change breaks the unlock until re-enrolled), `--pcrs=7` for Secure Boot only; the finishing note says which. `hardware-setup`'s `tpm-luks` step passes `enroll --yes` with `--yes`, `enroll --force` when named with `--only`, else opens the menu. Tests: `tests/recipes/luks-tpm-unlock.sh`, `tests/recipes/hardware-setup.sh`.
- Tests: `tests/hardware-targeting.sh` and the cases added to `gaming-setup.sh`, `switch-image.sh`, `luks-tpm-unlock.sh`.
  Only real hardware shows: Wayland and FSR4 behavior in games, amd-pstate states, the mcelog unit on Intel, the retry after a wake.

## ROCm is opt-in (not in the dx images)

- The dx lists (the `octarine-bins-dx` image, pinned by digest) do not carry `rocminfo rocm-smi rocm-hip rocm-opencl hipcc` (the old shared `dev-packages` list did, because it also built the owner's `fedora-toolbox`, and dx.sh excluded them with `EXCLUDE`; the exclusion went with that list on 2026-11-16). `variants/dx/dx.sh` fails the build if any of the five is installed afterwards. `dx-smoke.sh`
  (shared by dx and nvidia-dx) asserts the five are NOT installed. Measured on the owner's machine with `dnf5 remove --assumeno`: 21 packages
  leave with them, about 3 GiB (rocm-llvm-static 2.2 GiB, rocm-comgr, rocm-llvm-libs, rocm-clang*, rocm-runtime); nothing else in
  the dx extras depends on them. The default image never had ROCm.
- The `rocm` step of `ujust hardware-setup` (shown with an AMD GPU and `/dev/kfd`) runs `ujust toolbox rocm`, which assembles
  `system_files/usr/share/ublue-os/distrobox/rocm.ini`: image `registry.fedoraproject.org/fedora-toolbox:45` (the tag exists; bump it with the
  base), `additional_packages` the five packages from Fedora's repositories (no extra repository), `init=false`, `nvidia=false`. No group is
  needed: udev makes `/dev/kfd` and `/dev/dri/renderD*` mode 0666 on Fedora (`50-udev-default.rules`, verified on the owner's machine).
  Whether Fedora's ROCm build covers an RX 9070 XT (gfx1201) is UNVERIFIED. The toolbox recipe was reused for creation and removal
  (`ujust toolbox rocm --remove`); the CUDA box keeps its direct `distrobox create` in `ujust dev` because it needs the CDI device flag, NVIDIA's
  repository file and `gcc15-c++` installed inside the box, which an assemble file cannot express.

## Opt-in export of box binaries (`--export`)

- Kevin's decision (2026-11-13): the `cuda` and `rocm` boxes export NOTHING by default (the old host wrapper scripts are gone and stay gone).
  `--export` (on `ujust dev --only cuda` and on `ujust hardware-setup`, also as the steps `cuda-export`, `rocm-export`) runs
  `distrobox-export --bin <path> --export-path ~/.local/bin` inside the box for a short list: CUDA `nvcc`, ROCm `hipcc rocminfo rocm-smi`
  (never `nvidia-smi`, the host has it). `--unexport` removes only wrappers of that box. Shared code: `system_files/usr/share/octarine-os/lib/box-export.sh`
  (`box_export <box> <dir> export|unexport <bin>...`): the real path is resolved in the box with `bash -lc 'command -v X'` (so
  `/usr/local/cuda*/bin` and `/usr/bin/hipcc` are found, not guessed); a missing binary is skipped with a message; a file in `~/.local/bin`
  is ours only when it carries `# distrobox_binary` and `# name: <box>`; anything else is shown and left alone; an existing own
  wrapper reports "already exported". Tests: `tests/dev-setup.sh` and `tests/recipes/hardware-setup.sh` (stub `distrobox`).

## `ujust hardware-setup`

Plan modes are pure (`--list`, `--no`, for `ujust dev` `--no`): no distrobox is entered or started, because `distrobox enter` starts a stopped container. The `rocm` probe in hardware-setup and the existing-box check of the dev `cuda` step say "not checked in plan mode" instead; a real run probes as before. Tests: `tests/recipes/hardware-setup.sh`, `tests/dev-setup.sh` (no `distrobox enter` or `podman start` in the log).

- One recipe in `60-custom.just` (group Setup, above the `toolbox` recipe: `tests/toolbox.sh` scans everything after it for `sudo`).
  A checklist of hardware steps; each has a detection that HIDES it when the machine lacks the hardware. The standalone recipes it
  calls stay unchanged and visible (it runs `ujust <recipe>`; `OCTARINE_UJUST` replaces the command in tests); only `amd-gpu`,
  `amd-kargs` and `fido-key` have code of their own (plus the export steps, which use `box-export.sh`). Flags: `--yes` (ticked-by-default available steps that are not done; never
  `amd-kargs`), `--no` (plan), `--list` (state per step: `available`, `done`, `not applicable (reason)`), `--only a,b` (a hidden step
  prints `not applicable: <step> (<reason>)` and the run exits 0), `--help`. No terminal and no flag: one question per step; a gum
  terminal: the shared checklist (done steps unticked and marked); Esc exits 0.
- Steps and detection (paths are environment variables in tests): `sensors` (not a VM, `sensors-detect` present; done when
  `octarine-sensors.conf` or `nct6775.conf` exists in `/etc/modules-load.d`), `amd-gpu` (vendor `0x1002` and `/sys/module/amdgpu`;
  installs the LACT Flatpak system-wide and runs it with `LACT_UNATTENDED_SETUP=true`, UNVERIFIED without an AMD machine; done when
  `lactd` is enabled), `amd-kargs` (same detection; `sudo rpm-ostree kargs --append-if-missing=amdgpu.ppfeaturemask=0x<current | 0x4000>`,
  optional, never default; done when the command line or `rpm-ostree kargs` has it; the argument is NOT shipped), `amd-cpu-gaming`
  (`amd_pstate/status` is `active`; calls `gaming-setup gamemode`), `nvidia` (`0x10de`; `switch-image nvidia`, or `nvidia-dx` when
  `IMAGE_ID` ends in `-dx`; done when `/sys/module/nvidia` exists), `cuda` (driver loaded and the dx recipe file exists; `dev --only cuda`),
  `secure-boot` (EFI, `mokutil --sb-state` enabled, the key file present; ticked by default only on an NVIDIA image whose key
  `mokutil --test-key` does not report enrolled), `tpm-luks` (`/dev/tpmrm0` and a `crypto_LUKS` volume; never reported done, since
  reading the headers needs root), `fido-key` (`lsusb -d 1050:` or a hidraw with `ID_SECURITY_TOKEN=1`; runs
  `pamu2fcfg -o pam://sudo -i pam://sudo` into a temp file, mode 600, moved into `~/.config/Yubico/u2f_keys`; an existing non-empty file
  means done and is never overwritten; the PAM `nouserok` behavior is untouched), `rocm` (AMD GPU and `/dev/kfd` and distrobox; `ujust toolbox rocm`; not ticked by default; done when the box has `rocminfo`) with `rocm-export` and `cuda-export` (opt-in, never ticked; see "Opt-in export"), `virtualization` (dx image only, because only dx has libvirt, and `/dev/kvm`;
  `dev --only libvirt`; done when the user is in `libvirt`).
- Adding an entry: add its id to `valid_steps` and `step_ids`, its text, and a case in `reason_of`, `done_of`, `default_of`, `undo_of`
  and `run_of`, then cases in `tests/recipes/hardware-setup.sh`. Skipped for now: firmware and laptop power. Unverified without hardware:
  every detection on a real machine, the LACT unattended setup, `pamu2fcfg` with a key, the kargs change.

## `ujust sensors-setup`

- Opt-in recipe in `60-custom.just` (group System): the Super I/O driver is chip-specific (nct6775, it87, ...), so the image
  never forces a module on (a missing chip would make `systemd-modules-load` log errors). It runs `sudo sensors-detect --auto`
  (Fedora's `lm_sensors`; `--auto` writes `/etc/sysconfig/lm_sensors` with `BUS_MODULES`/`HWMON_MODULES`,
  `/etc/modprobe.d/lm_sensors.conf` and enables `lm_sensors.service`, and leaves out autoloaded drivers), parses the two
  variables from `/etc/sysconfig/lm_sensors` (module names validated), treats "no sensors were detected" and "No modules to load"
  in the output as nothing to do, and writes `/etc/modules-load.d/octarine-sensors.conf` (static header, so an identical file means
  "already done"). A different existing file: diff, default keep, `.bak-<timestamp>` on replace; the older hand-made
  `nct6775.conf` is offered for a move to `.bak-<timestamp>`. `--no` is a plan and changes nothing (detection needs root), `--yes`
  asks nothing. The files persist across image updates, so no re-run after an update. `acpi_enforce_resources=lax` is not set.
  Tests: `tests/sensors-setup.sh` (fake `sudo`, `sensors-detect`, `modprobe`, `sensors`). Not verifiable in CI: a real chip.

## `ujust luks-tpm-unlock`

- One recipe in `60-custom.just` replaces the base's `setup-luks-tpm-unlock` and `remove-luks-tpm-unlock` (which handled the
  root device only, from `rd.luks.uuid`): `15-luks.just` is empty and both names are gone (no aliases). It lists every `crypto_LUKS` device
  (`lsblk`), reads the TPM2 token state with `sudo cryptsetup luksDump`, asks enroll or remove and then a checklist of
  devices (preticked: unenrolled ones for enroll, enrolled ones for remove), or takes `enroll|remove DEVICE...` (path or
  UUID). Enroll is ONE `systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7+14` call (default:
  Secure Boot state plus the MOK list; `--pcrs=7` binds Secure Boot only, `--pin` adds a PIN); a re-enroll adds `--wipe-slot=tpm2` to that same call, because systemd-cryptenroll(1) (systemd 262 in
  this image) says: "in combination with any of the enrollment options ... the enrollment is completed first, and only when
  successful the wipe operation executed -- and the newly added slot is always excluded from the wiping", so a cancelled or
  failed enrollment keeps the old key; remove is `--wipe-slot=tpm2` only, passphrases are never touched.
- Decisions: PCR 7+14 by default (the owner chose it 2026-11-09, as the base helper did; the owner's old script used 7 only; a MOK change
  (`mokutil --import` or `--delete`) or a Secure Boot change breaks the auto-unlock until re-enrolled, the passphrase still works);
  the base helper's AMD faulTPM warning is kept and needs a yes; the root-volume initramfs step of the base helper is a
  printed tip only (its `lsinitrd` test looked inverted, and changing the initramfs is not done silently).
  Tests: `tests/recipes/luks-tpm-unlock.sh` (fake `lsblk`, `cryptsetup`, `systemd-cryptenroll`, `sudo`).

## `ujust switch-image`

- One recipe in `60-custom.just` switches between the images (`default` = `octarine-os`, `dx` = `octarine-os-dx`, `gx` = `octarine-os-gx` (gamer), `nvidia` =
  `octarine-os-nvidia`, `nvidia-dx` = `octarine-os-nvidia-dx`, `nvidia-gx` = `octarine-os-nvidia-gx`, `dx-gx` = `octarine-os-dx-gx` (experimental, `latest` only; alias `fx`); the recipe probes the registry and refuses an image that is not published) and the channels `latest`, `testing`. It replaces the
  base image's `toggle-nvk` (Universal Blue's `40-nvidia.just`), which derived names by string substitution
  (`octarine-os-dx-nvidia-open` does not exist) and rebased without enforcing the signature policy; our `40-nvidia.just`
  overwrites that file and is empty, so `toggle-nvk` is gone (build.sh fails if a `toggle-nvk` recipe is still installed, the
  smoke test checks the assembled `justfile`; `tests/just-recipes.sh`). Open, low priority: the recipe hard-codes the
  `octarine-os*` image names, so on a fork it only works for forks that keep them (the registry is taken from the running image).
- The running image comes from `rpm-ostree status -b --json` (transport prefix and digest stripped), the registry from the
  running image's own reference (so forks work; a foreign image falls back to `ghcr.io/redcodeworks`). With only an image it
  keeps the current channel, `latest` when the tag is pinned. Availability is checked with `skopeo inspect --raw` before
  anything runs: a missing manifest is "not published", a network failure is reported separately and never treated as
  missing. The switch is `sudo bootc switch --enforce-container-sigpolicy <ref>`, the form the README documents.
  `--list` probes all 14 combinations (7 image kinds times the channels latest and testing) in parallel and shows an unpublished one as such; `--yes` skips the question, `--no` prints the plan.
- Which combinations exist is not hard-coded: `nvidia`, `nvidia-dx`, `nvidia-gx` and `dx-gx` have only `latest` (no `testing` tag). `octarine-os-nvidia-dx` is
  built by `build-nvidia-dx.yml` (see "NVIDIA dx image"); its repository is in the signature policy that `build_files/build.sh` generates
  (the smoke tests `dx-smoke.sh`, `gx-smoke.sh` and `build.yml`'s check the policy for each repository), so the recipe needed no change except a hint
  printed for `nvidia-dx` (a machine whose image predates the rule gets a signature-policy error from bootc).
- Staged images: the recipe also reads the STAGED deployment (`rpm-ostree status --json`, `staged: true`; test hook `OCTARINE_SWITCH_STAGED_REF`). When it equals the target (digest ignored) it says "already staged: reboot to use it" and calls nothing (no second `bootc switch`, no second security-key touch); a different staged image is named and replaced. The hardware-setup `nvidia` step goes through this recipe, so its probe (`/sys/module/nvidia`, false until the reboot) cannot cause a second switch.
- Tests: `tests/recipes/switch-image.sh` (fake `skopeo`, `sudo`, `bootc`; the running image from `OCTARINE_SWITCH_CURRENT_REF`).

## NVIDIA variant (`octarine-os-nvidia`)

- User-facing note (formerly in the README): run the default install steps first, then `bootc switch --enforce-container-sigpolicy
  ghcr.io/redcodeworks/octarine-os-nvidia:latest` and reboot; with Secure Boot on, `ujust enroll-secure-boot-key` (from the base).

- **What it is.** A second image, `ghcr.io/redcodeworks/octarine-os-nvidia`, built on request (no schedule since 2026-11-16, Kevin's decision: the NVIDIA chain is a proof of concept; the weekly cron was removed) by `.github/workflows/build-nvidia.yml`, by manual dispatch on `main` only; never on pushes, pull requests
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
- **Policy exception.** NVIDIA's proprietary driver is out-of-tree software (negativo17, NVIDIA's toolkit repository, a COPR at
  build time), accepted only in this opt-in variant; the default image stays Fedora-official packages only.
- **Unverified.** No GPU, no boot test, the akmods kernel-tag form, the driver version, Secure Boot enrollment
  (`ujust enroll-secure-boot-key`, from the base, enrolls Universal Blue's key; MOK password `universalblue`), SELinux module
  detection by `semodule -l` in a build container.

## dx image (`octarine-os-dx`)

- **What it is.** `ghcr.io/redcodeworks/octarine-os-dx`: the published default image plus the developer toolchain of the owner's
  `dev-toolbox` (so the host has compilers, `-devel` libraries, debuggers, `uv`, `rustup`, `fish`; no ROCm, see below), VM tooling,
  tracing tools and a few extras; the VS Code Flatpak is not preinstalled (`ujust dev` installs it on request; Kevin 2026-11-10). Opt-in, for the owner's own
  use. The default image has only gcc, g++, make and binutils (see "Image build steps added 2026-11-14"), not the dx toolchain; nothing in `Containerfile` or `build.sh` installs the dx
  set (the dx smoke test shows a missing package, `default-smoke.sh` has no dx packages).
- **Lineage (the `latest` channel; `testing` follows the testing default image).**

  | Base | Default image | dx image |
  |---|---|---|
  | `ghcr.io/ublue-os/silverblue-main:45` | `octarine-os:latest` | `octarine-os-dx:latest` |

- **Files.** `variants/dx/Containerfile` (ARGs `BASE_IMAGE`, `BASE_TAG`, `BASE_DIGEST`; `FROM ${BASE_IMAGE}:${BASE_TAG}${BASE_DIGEST:+@}${BASE_DIGEST}`,
  so the workflow's digest wins and a bare local `podman build` still works; the `binsdx` stage (the pinned octarine-bins-dx image); `bootc container lint`),
  `variants/dx/dx.sh` (runs the installer of the pinned octarine-bins-dx image, then `install-binaries.sh` with an empty required list, copies `variants/dx/system_files/`, enables
  `podman.socket` (rootful; the default image already enables the user one globally) and asserts the kernel is unchanged and
  the only one) (the dx package lists, the old `variants/dx/packages/extras.txt` included, are `dx/packages/` in octarine-bins since 2026-11-16),
  `.github/workflows/build-dx.yml` (the dx-only `dx.preinstall` was removed 2026-11-10 and `variants/dx/system_files/usr/share/flatpak`
  with it; a dx-only Flatpak drop-in would need no recipe change, `ujust flatpak-preinstall` reads every `*.preinstall` there),
  `.github/scripts/dx-smoke.sh`.
- **The dx lists (pinned by digest, the octarine-bins-dx image, since 2026-11-16).** `ghcr.io/redcodeworks/octarine-bins-dx` is a signed FROM scratch image from the octarine-bins repository (signed with `keys/octarine-bins.pub`'s key, NOT the toolbox key): `/packages/{required-fedora,optional-fedora}.txt` and `/packages/install.sh` (the same installer as the other two images), and an EMPTY `/COMPONENTS` (no binary yet). It is pinned like the base octarine-bins image: `ARG BINS_DX_TAG` (for humans) and `ARG BINS_DX_DIGEST` in `variants/dx/Containerfile` (`BINS_DX_REF` is built from them, with defaults, and is the `FROM` of the `binsdx` stage), changed only by the weekly `bins-dx` bump PR. `dx-image.yml` verifies the PINNED digest on every dx build with `keys/octarine-bins.pub` (`retry.sh cosign verify`) and records `ghcr.io/redcodeworks/octarine-bins-dx@<digest>` in the label `io.github.redcodeworks.octarine-os.bins-dx`; the NVIDIA dx build shares the step and the pin. The pin covers the lists and the installer only: the packages still float via dnf. The Containerfile mounts it with `RUN --mount=type=bind,from=binsdx,source=/,target=/binaries` and `dx.sh` runs `MISSING_FILE=... bash /binaries/packages/install.sh` (misses are appended to the default image's `optional-packages-missing`) and then `BINARIES_REQUIRED="" /ctx/install-binaries.sh` (zero components accepted; a component dx gets later is unknown to the reader until `install-binaries.sh` learns it). The installer's contract and order: see "Package lists" under the default image. A merged bump makes the dx testing build the first with the new lists. `keys/redcodeworks-toolbox-cosign.pub` stays in the dx image's `ctx` only for the datastore bundle signature policy (`dx.sh`).
- **Workflow rules (`build-dx.yml`).** Since 2026-11-10 dx also builds on `testing` and promotes on `main`; the flow, the plan decision table, the
  input hashes and the result check are in "Input hashes and dx on testing" above, and the plan logic is `.github/scripts/plan-dx.sh`. The text below
  describes the earlier main-only version where it still applies (the build steps, labels, sign job, concurrency). Triggers: `workflow_run` of "Build container image" (`completed`,
  `branches: [main, testing]`; `workflow_run` workflows run from the default branch's file, so the workflow cannot be run from `testing`
  or a feature branch and the first run of a changed file happens only after promotion) and `workflow_dispatch` (inputs `channel`, `force`). The
  plan job runs only when `github.ref == refs/heads/main` and (a dispatch, or the triggering run concluded `success`, its event
  is `schedule`, `push` or `workflow_dispatch`, and its `head_branch` is `main`; never a pull request). Channel: `latest` after
  the default build, the input on dispatch. Plan: resolves
  `octarine-os:<channel>` to a digest (sha256 of the raw manifest), verifies it with `cosign.pub`, reads the published
  `octarine-os-dx:<channel>` labels and ends green with the notice "base unchanged, nothing to build" when its
  `org.opencontainers.image.base.digest` equals the digest AND its `io.github.redcodeworks.octarine-os.dx-tree` label equals
  `git rev-parse HEAD:variants/dx` (so a change to the dx files, for example a bumped pin, also rebuilds; the base digest
  alone would wait for the next base change) and no force; a missing, unreadable or unlabelled image builds. The plan job logs
  in with `packages: read` because a new GHCR package is private until the owner makes it public. Build: setup tools, the pin
  check and signature verification, base verified again by digest and pulled, kernel of the base read, `podman build` with
  explicit labels (the `just build` set plus `base.name`/`base.digest`, `dx-tree` and `bins-dx`; inherited maintainer
  labels and the base's `base-index-digest` are unset), size guard (15 GiB), `dx-smoke.sh`, `just rechunk`, the
  channel-neutral version check, push of `<channel>` and `<channel>-<date>-<sha>`. Sign job (`signing` environment): signs
  every pushed digest with the repository key, verifies both tags with `cosign.pub`. Concurrency: see "How dx is started" (testing: one group, a newer run cancels; latest: per commit, never cancelled). Least privilege per job, actions pinned by SHA with version comments, schedules none.
- **Smoke test.** `dx-smoke.sh` runs inside the built image: gcc, g++, clang, cmake, ninja, meson, gdb, pkgconf, uv, fish, the rustup package and `rustup-init` (the RPM ships only that; no `rustup` command),
  `glib2-devel`, `openssl-devel`, virt-manager, virt-viewer, qemu-kvm, the libvirtd and virtqemud units, `podman.socket`,
  no VS Code or virt-manager Flatpak in any preinstall list, exactly one kernel equal to `BASE_KERNEL`, and the default image's checks that still apply
  (os-release, the three policy rules, sudoers, brew, recipes, removed packages). It prints `DIAG` lines on failure. Under
  `pipefail` it never pipes a producer into `grep -q` (the lesson of the NVIDIA initramfs check).
- **Signature policy.** `build.sh` writes a `sigstoreSigned` rule for `octarine-os`, `octarine-os-nvidia` and `octarine-os-dx` into
  the default image (strips `-nvidia` and `-dx` from `IMAGE_NAME`); the dx image inherits it. A machine therefore switches to
  the dx image only after it runs a default image built with the rule (update first, then
  `bootc switch --enforce-container-sigpolicy`). Asserted in the smoke tests (`default-smoke.sh`, `dx-smoke.sh`, `gx-smoke.sh`, `nvidia-smoke.sh`).
- **User-facing note (formerly in the README).** Switch with `bootc switch --enforce-container-sigpolicy ghcr.io/redcodeworks/octarine-os-dx:latest`
  after updating to the newest default image (it carries the signature policy); undo by switching back to `octarine-os:latest`. The README table and the `ujust dev` text say what `dev` sets up; the step table lived in the README and is now in
  "Developer menu" below.
- **VS Code.** `com.visualstudio.code` is the community-maintained Flathub build; Flathub's API reports it as not verified
  (Microsoft is only listed as developer). The owner chose it knowingly; it is installed only by the `vscode` step of `ujust dev` (which says so), never preinstalled.
- **Kernel argument.** None since 2026-11-13: the dx image no longer ships `10-iommu.toml`; `iommu=pt` is opt-in (see "Kernel argument" under the default image notes).
- **Stage 3 (done, `feat/vm-host-to-dx`).** The VM-hosting set moved out of the default image and lives only in dx and nvidia-dx
  (`required-fedora.txt` of octarine-bins-dx, formerly `variants/dx/packages/extras.txt`: `libvirt` and `qemu-kvm` meta packages, `cockpit-machines`, `virt-install`, `virtiofsd`, `swtpm`,
  `swtpm-tools`, `dnsmasq`, `edk2-ovmf`, `virt-manager`, `virt-viewer`, `libvirt-nss`, ...). `build.sh` no longer lists `libvirt` and
  `qemu-kvm` (CRITICAL) or `cockpit-machines` (the `cockpit` group); the `libguestfs` group (`guestfs-tools`, `libguestfs`,
  `libguestfs-xfs`, `virt-v2v`) stays in the default image and drags in libvirt libraries and a QEMU subset as dependencies
  (measured on the default image of 2026-11-10 with `dnf5 --disable-repo='*' remove --assumeno libvirt qemu-kvm cockpit-machines`:
  103 packages and about 79 MiB go away, among them `libvirt`, `libvirt-daemon`, `libvirt-daemon-driver-storage-*` (except `-core`),
  `libvirt-dbus`, `libvirt-glib`, `qemu-kvm`, `qemu-system-x86`, the `qemu-audio-*`, `-block-*`, `-device-*`, `-ui-*` modules,
  `virtiofsd`, `virt-install`, `cockpit-machines`, `spice-server`, `virglrenderer`, glusterfs and Ceph client libraries). What stays
  because of libguestfs and virt-v2v: `libvirt-libs`, `libvirt-client`, `libvirt-daemon-common`, `-driver-qemu`, `-driver-network`,
  `-driver-secret`, `-driver-storage-core`, `-daemon-log`, `-daemon-config-network`, `qemu-kvm-core`, `qemu-system-x86-core`,
  `qemu-img`, `qemu-common`, `edk2-ovmf`, `nbdkit*`, `passt`, `supermin`, `libguestfs-appliance`, `swtpm` (with `-libs`, `-tools`,
  `-selinux`, dragged in by the QEMU driver, so it is NOT asserted absent), `dnsmasq`, `virt-what`. The `libvirt` group and the
  `virtqemud` units can still exist in the default image through the driver packages, but nothing enables them. Smoke tests:
  `build.yml` asserts `libvirt`, `qemu-kvm`, `cockpit-machines`, `virt-manager`, `virt-viewer` and `libvirt-nss`
  are absent (and `guestfs-tools` present); `nvidia-smoke.sh present` asserts the same for the plain NVIDIA image (skipped for an
  `-dx` image id); `dx-smoke.sh` asserts the full set, the `libvirtd`, `virtqemud`, `virtnetworkd` and `virtstoraged` units and
  `libvirt-nss`. `user-setup` names only the groups that exist in its menu (`getent group`). Switching a machine from dx to the default image removes VM hosting
  (`ujust dev --only libvirt` and `ujust virthost-setup` are dx-only; the hardware-setup `virtualization` step was removed; the user's `libvirt` group membership stays
  in `/etc/group` and is harmless). UNVERIFIED: the package set after a real build (the list above is from a local image dated
  2026-11-10, CI is the first full run), and that a machine switching from dx to default loses nothing else.
- **Unverified until promotion.** The real build (no build before the merge exercises `variants/dx`: `build.yml` builds the default
  image only), the base digest compare, the sign step and the first `workflow_run` behavior only run after the workflow
  exists on `main` (for the testing trigger and the promote path see "Input hashes and dx on testing"). The `FROM` expansion `${BASE_DIGEST:+@}${BASE_DIGEST}` was checked with a local podman, not on the runner.

## gx image (`octarine-os-gx`) (2026-11-16, Kevin: the "gamer" image)

- **Model in one sentence.** gx is the published default image plus ONE pinned octarine-bins image (`ghcr.io/redcodeworks/octarine-bins-gx`: the gaming package lists, their installer, later gx binaries; since 2026-11-16, before that the `gaming-packages` list image of octarine-images) plus a few gx-only steps, built by the same
  reusable workflow as dx (`dx-image.yml` with `variant: gx`), dispatched in parallel with dx after the default build, built on `testing` and promoted by retag on `main`, publishing its
  OWN `latest` independently (`publish-latest.sh` with `IMAGE=gx`, the `publish` job of `build-gx.yml`). A sibling of dx, not a layer on dx.
- **Files.** `variants/gx/Containerfile` (the pin ARGs `BINS_GX_TAG`/`BINS_GX_DIGEST`/`BINS_GX_REF`, the `ctx` stage, one `RUN` of `gx.sh` with the bins-gx image bind-mounted at
  `/binaries`, then `bootc container lint --fatal-warnings`), `variants/gx/gx.sh`. No `system_files` tree (the packages bring their own files; a tree needs a
  `COPY` and a `cp -a`). `.github/workflows/build-gx.yml` (thin caller), `.github/scripts/gx-smoke.sh`. Shared with dx: `dx-image.yml`, `plan-dx.sh` (env `VARIANT`), `aggregate-dx.sh`, `dispatch-dx.sh`
  (env `VARIANT`), `inputs-hash.sh` (kind `gx`, see "Input hashes and dx on testing").
- **`gx.sh` steps (since 2026-11-16, the installer of the pinned bins-gx image does the work).** (1) kernel recorded; (2) `dnf5-plugins` (the base has it already: a no-op; the installer's COPR list needs `dnf5 copr`); (3) `MISSING_FILE=/usr/share/octarine-os/optional-packages-missing bash /binaries/packages/install.sh`: required-fedora (`gamescope`, `mangohud`, `gamemode`, `mesa-vulkan-drivers`, `libFAudio` for both architectures named explicitly, `steam-devices`), required-negativo17 (`steam`, with `fedora-multimedia` enabled for that call only), required-copr (`lizardbyte/stable:Sunshine-2026.914.233613-1.fc45`: enable, strict install, disable), optional-fedora (vkBasalt, input helpers, Proton helpers, diagnostics; best effort), the installer then cleans the dnf caches; (4) the script asserts that `steam` came from `fedora-multimedia`; (5) `BINARIES_REQUIRED="" install-binaries.sh` (zero components); (6) IMAGE_ID `octarine-os-gx`, kernel unchanged (one directory under `/usr/lib/modules`), `validate-repos.sh`, `final-cleanup.sh`, `bootc container lint`.
- **Steam from negativo17, not RPM Fusion (changed 2026-11-16, Kevin).** Until then gx.sh installed Steam from RPM Fusion's disabled `rpmfusion-nonfree-steam.repo` (carried by `fedora-workstation-repositories`, enabled through an override file with `priority=10`, because negativo17's own newer `steam` otherwise won by version), then removed the carrier packages again; all of that is gone. negativo17 ships Mesa for BOTH architectures (`mesa-vulkan-drivers` x86_64 and i686, epoch 1, same version) and newer than Fedora, so installing `required-negativo17.txt` also upgrades the base's x86_64 Mesa and brings i686 Mesa, the codec libraries and `openh264` (both architectures, replacing the base's `noopenh264` stub) from negativo17 (about 60 packages, see octarine-bins's `gx/README.md`); `gx-smoke.sh` asserts equal x86_64 and i686 Mesa versions and that `steam` came from `fedora-multimedia`. The `.i686` entries of the lists name their `.x86_64` sibling explicitly (a bare name next to `name.i686` made dnf5 install ONLY the i686 package; found in the first local gx build; the octarine-bins lint enforces the pairing).
- **Sunshine (verified in the local image).** `getcap /usr/bin/sunshine` = `cap_sys_admin,cap_sys_nice=p`, `rpm -V Sunshine` clean, `/usr/lib/udev/rules.d/60-sunshine.rules` (uinput and uhid access, group input, `uaccess`),
  `/usr/lib/modules-load.d/60-sunshine.conf` loads `uhid` (uinput gets its static node from the rule), the user unit `app-dev.lizardbyte.app.Sunshine.service` (alias `sunshine.service`) ships NOT enabled
  (`systemctl --global is-enabled` = disabled; the user starts it with `systemctl --user enable --now app-dev.lizardbyte.app.Sunshine`, the alias only works after that first enable); the firewall services
  `sunshine` and `steam-streaming` are the image's own. UNVERIFIED: that chunkah keeps the file capability (it keeps the capabilities of the base's `newuidmap`, `mtr-packet` and others, seen in the published default image,
  so it should), and a real stream.
- **Not in the image (Kevin).** Moonlight (Flatpak for the people who want it), MoonDeck Buddy, Terra packages, a Flatpak Steam (Steam is in no `preinstall.d` list). `ujust gaming-setup` skips its `steam`, `extensions` and
  `desktop` steps when `rpm -q steam` succeeds (`GAMING_SETUP_NATIVE_STEAM=1|0` forces the answer for tests; `tests/recipes/gaming-setup.sh`); `protonup`, `lutris`, `extest`, `gamemode` are unchanged.
- **Pipeline.** `build.yml` has a `dispatch_gx` job beside `dispatch_dx` (same `needs`, same `if`, the same digest hand-over; `VARIANT=gx` for `dispatch-dx.sh`). `build-gx.yml`: dispatch only, run-name
  `gx <channel> <sha>`, the concurrency pattern of dx (testing cancels, latest per commit never), a `gx` job (the reusable workflow), its own `sign` job with `environment: signing` through
  `.github/actions/sign-images`, the result job named `Build gx and push image` only when `inputs.sha == github.sha` (the commit status of the same name is posted on the built commit for `testing`),
  `publish` (`publish-latest.yml` with `image: gx`) and `alert` (label `ci-failure-gx`). The check `Build gx and push image` is a required check of the main ruleset (like `Build dx and push image`).
  `dx-image.yml` picks the variant's Containerfile, verifies the pinned binaries image of the variant (dx `octarine-bins-dx`, gx `octarine-bins-gx`, with `keys/octarine-bins.pub`; `LIST_REF`), labels `<variant>-tree`, `<variant>-inputs` and `bins-dx`/`bins-gx`, and
  runs `.github/scripts/<variant>-smoke.sh`. Weekly bump kinds `bins-dx` and `bins-gx` (the same code). `prune-daily.yml` treats all three packages (octarine-os, -dx, -gx) alike; `rollback-latest.yml` and the
  `publish-latest.yml` dispatch take `image: gx`.
- **First publication.** A new GHCR package is created PRIVATE: after the first gx push (testing) the owner sets `octarine-os-gx` to public in the package settings, or `ujust switch-image` and `bootc upgrade`
  cannot read it (and the package `octarine-os-gx` must allow this repository's workflows: Package settings, Manage Actions access). `octarine-os-gx:latest` exists since the first green
  main run; before that, `ujust switch-image gx` said it was not published.
- **Local build result (2026-11-16, podman with a scratch root, base `octarine-os:testing` at 0e63072).** About 1.5 to 1.7 minutes per build with warm layers (pull of the base about 50 s); the image is 11.1 GB
  uncompressed against 7.6 GB for the base; `bootc container lint` 14 checks passed; `gx-smoke.sh` 72 checks passed. UNVERIFIED until CI: the runner build, the signed pin check, sign, promote, publish and the first
  `workflow_run`-free dispatch of `build-gx.yml` (a dispatched run uses the file of the ref, so the first one is on `testing` after the merge).

## NVIDIA dx image (`octarine-os-nvidia-dx`) and the CUDA toolbox

- **What it is.** `ghcr.io/redcodeworks/octarine-os-nvidia-dx`: the SAME dx layer (`variants/dx`, one `Containerfile`, one package
  list, no ROCm, no CUDA toolkit) on top of `octarine-os-nvidia` instead of `octarine-os`. Kevin's decision (2026-11-10): the DX
  build is identical for both variants, and NVIDIA's toolkit is a user-side install. No fork of the package list: the workflow passes
  `BASE_IMAGE=ghcr.io/<owner>/octarine-os-nvidia` and `DX_IMAGE_ID=octarine-os-nvidia-dx` (a build argument of the final stage of
  `variants/dx/Containerfile`, default `octarine-os-dx`; `dx.sh` sets `IMAGE_ID` from it and refuses any other value).
- **Own caller, `build-nvidia-dx.yml` (name "Build NVIDIA dx image"; since 2026-11-16 a thin caller of the reusable `dx-image.yml`, like `build-dx.yml`: the plan, build and promote jobs and their steps live once in `dx-image.yml` (the sign job is the caller's own, see below), with inputs `base_name`, `dx_name`, `channel`, `sha`, `base_digest`, `force`, `dry_run`, `promote_from_testing`, `tags` (a template with `{sha}` and `{date}`), `description` and `extra_smoke`, and outputs the job results for the callers' result jobs; the called workflow takes a `variant` input (dx or gx) that picks the Containerfile and the smoke script).** Not a matrix of `build-dx.yml`: that file posts the REQUIRED
  check `Build dx and push image` (also the commit status on the tested commit) and its trigger and result logic must not change. The new
  workflow never posts that context: its result job is named `NVIDIA dx build result`, there is no `statuses` permission and no status
  call, so it can neither satisfy nor block a promotion pull request. Trigger: `workflow_run` of "Build NVIDIA variant" (`main`
  only; that workflow itself runs only on the Sunday schedule and by dispatch) and `workflow_dispatch` with `force`; never a push, pull
  request or `testing`. Jobs: `plan` -> `build` -> `sign` (environment `signing`) -> `nvidia_dx_result` (`aggregate-dx.sh` with promote skipped).
  The caller keeps its own triggers, its concurrency group `build-nvidia-dx` and its result job; concurrency never moves into the reusable workflow (a called workflow cannot share its caller's group). **Signing lives in the callers (2026-11-16).** The `signing` ENVIRONMENT secret did not reach a job inside the reusable `dx-image.yml`: the sign job got an empty key (`invalid pem block`, then `getting signer: reading key`) on two runs, with a declared `workflow_call` secret (ee077f8) and without one (9c2baba, #218), although the same job shape works in `build.yml` and `build-nvidia.yml` where `environment: signing` sits on an ordinary job. So `dx-image.yml` has no sign job and no secret; `build-dx.yml` and `build-nvidia-dx.yml` each have a `sign` job (`environment: signing`, `needs: <the called workflow>`, `contents: read`, `packages: write`) that checks out the built commit, logs in to ghcr.io and runs the composite action `.github/actions/sign-images` with `private-key: ${{ secrets.SIGNING_SECRET }}` (an input, passed to cosign through `env://`, never in a shell string or printed; flags `--new-bundle-format=false --use-signing-config=false`, `COSIGN_EXPERIMENTAL=false`). Mode `sign` after a build (sign each digest, verify every tag), mode `verify` after a promotion (the digest was signed when the testing image was published: verify, never sign again); the job is skipped unless the called workflow reports `build` or `promote` as success, so dry runs, skips and failures before it skip it. The result jobs take `SIGN` from `needs.sign.result` (`aggregate-dx.sh` unchanged); `dx-image.yml` exports `image`, `alias_tags` and `digests` for the sign job. UNVERIFIED until the next testing dx build. Still unverified: the callers' result mapping.
- **Plan.** `plan-dx.sh` with `CHANNEL=latest BASE_NAME=octarine-os-nvidia DX_NAME=octarine-os-nvidia-dx PROMOTE_FROM_TESTING=false`
  (the new switch skips the search for a tested testing image: there is no testing channel). Skip when the published
  `octarine-os-nvidia-dx:latest` has the same base digest (raw manifest of the verified `octarine-os-nvidia:latest`) and the same `dx_inputs`
  as this commit; otherwise build. `is_dx_only` lists the new workflow (`build-nvidia-dx.yml`; `inputs-hash.sh` lists no tests), so a change to it changes
  `dx_inputs` (dx rebuilds too) and never rebuilds the default image.
- **Tags.** `latest`, `latest-<sha>`, `latest-<date>-<sha>`, `<date>-<sha>`, `<date>`, `latest-<date>` (the NVIDIA variant's set), one push through
  `push-tags.sh`, signed like the others (`cosign.pub`). No `testing`.
- **Smoke tests on the built image.** `dx-smoke.sh` with `EXPECT_IMAGE_ID=octarine-os-nvidia-dx`, then `nvidia-smoke.sh present` with the same
  `EXPECT_IMAGE_ID` (driver package, kernel module, one kernel equal to the base's, initramfs, kargs, SELinux module) and the new checks (also run by
  the NVIDIA variant's own build): no `cuda-toolkit*`/`cuda-nvcc*`/`cuda-compiler*`/`nvidia-cuda-toolkit` package, no `/usr/local/cuda*`, no `nvcc`
  on PATH; the CDI pieces (`nvidia-container-toolkit`, `-base`, `nvidia-ctk`) are reported as INFO only.
- **Signature policy.** `build.sh` now writes the rule for SEVEN repositories (`octarine-os`, `-nvidia`, `-dx`, `-nvidia-dx` and, since 2026-11-16, `-gx` and `-nvidia-gx`, the gamer variants, and `-dx-gx`, the experimental gx layer on the dx image; the later ones were not published when their rule was added, so a machine on this image can switch to it later; the base name is derived by stripping
  `-dx`, then `-gx`, then `-nvidia`) into the default image, so the dx and NVIDIA images (built on it) inherit it; the smoke tests of `build.yml`
  and `dx-smoke.sh` assert it. Consequence: `bootc switch --enforce-container-sigpolicy ...octarine-os-nvidia-dx` works only on a machine that has booted
  an image carrying the new rule (the policy is `reject` by default); `ujust switch-image` prints a hint for it.
- **CDI pieces in the NVIDIA variant (`nvidia.sh`).** Our `nvidia.sh` runs the akmods `nvidia-install.sh`, which per the ublue-os/akmods sources (read 2026-11-10, addons 0.15) installs the full `nvidia-container-toolkit` and enables `nvidia-cdi-refresh.service`, `.path` and `nvidia-persistenced.service`; so `nvidia.sh` only keeps a guarded fallback (install `nvidia-container-toolkit-base` when NEITHER toolkit package is installed; warning on failure; enable the refresh units when present). The smoke test reports the units as INFO (enabled) or WARNING (not enabled), never a failure. UNVERIFIED in a real build.
- **First publication.** A new GHCR package may start private: the owner makes `octarine-os-nvidia-dx` public once (package settings), or `ujust switch-image` reports it as
  not published. The plan job logs in with the token, so it can read a private package.
- **The CUDA step of `ujust dev` (dx image, `70-octarine-dev.just`, step `cuda`).** Shown in the checklist and run only when an NVIDIA driver is present
  (`nvidia-smi -L` works or `/sys/module/nvidia` exists; hooks `DEV_NVIDIA_SYSFS`); otherwise the step records "skipped (no NVIDIA driver on this machine)". Why a container:
  NVIDIA's license does not allow baking the toolkit into a public image, and NVIDIA's `fedora45` repository had no toolkit (as of 2026-10-27: `fedora44` has `cuda-toolkit-13-x`
  up to 13.5.0, GCC 15.x works with CUDA 13.3+, GCC 16 does not). Never installed on the host, the CUDA repository is never in the image (a test greps for it).
  It creates the rootless distrobox `cuda` from `registry.fedoraproject.org/fedora-toolbox:44` (`DEV_CUDA_IMAGE`) with
  `--additional-flags "--device nvidia.com/gpu=all"` (CDI), NOT `--nvidia` (known open gap on Fedora Atomic, Bluefin issue 2559: no `ld.so.conf.d` entry or `NVIDIA_*` env,
  empty `libcuda.so` links), then inside it: NVIDIA's fedora44 repo (the `.repo` file fetched with `sudo curl -fsSL` into `/etc/yum.repos.d/cuda-fedora44.repo`, `DEV_CUDA_REPO_URL`; the dnf5 config-manager plugin is not assumed; skipped when a repo file for it exists; the file exists, gpgcheck=1, `cuda-toolkit` is a meta package, 13.5.0 newest, per a 2026-11-10 web read), `sudo dnf5 -y install cuda-toolkit gcc15-c++`, `/etc/profile.d/cuda.sh` (PATH `/usr/local/cuda/bin`, `NVCC_CCBIN=g++-15`; the pin is only a safety for CUDA 13.3, 13.5 accepts GCC 16 which is Fedora 44's default, and `gcc15-c++` is in Fedora's own repos). Precondition: the host has an NVIDIA CDI spec
  (`nvidia.yaml` in `/var/run/cdi` or `/etc/cdi`; hook `DEV_CDI_DIRS`; the image's `nvidia-cdi-refresh` units write `/var/run/cdi/nvidia.yaml` at boot); without it the step fails and says to reboot or start `nvidia-cdi-refresh.service`, then prints `sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml`; the recipe never runs sudo for it (sudo stays libvirt-only). `--image IMAGE` (validated name) creates the container from that image (for example
  `docker.io/nvidia/cuda:<version>-devel-<distro>`) and installs nothing in it; it only applies when the container is created. Idempotent (container exists and has nvcc, plus
  profile.d for the default image: already done; an existing container without the toolkit is not recreated), network commands retried, `--no` plan, undo
  `distrobox rm --force cuda`. After the install it runs `nvidia-smi -L` in the container; a failure is a note (GPU path unverified), not a step failure. Tests: `tests/dev-setup.sh` (stub
  `distrobox`, `nvidia-smi`; fresh, already done, existing container without toolkit, no driver, no CDI spec, failed create, failed install, retries, `--image`, the menu row).
- **Unverified.** Everything about the live GPU path (CDI into a rootless distrobox, libcuda inside the container, `nvcc` with `g++-15`), the existence of `cuda-fedora44.repo` at that URL, the package
  names `cuda-toolkit` and `gcc15-c++` on Fedora 44, whether `nvidia-install.sh` ships the container toolkit and refresh units, and the whole `build-nvidia-dx.yml` run, which can only
  happen after the workflow is on `main` (workflow_run and dispatch use the default branch's file) and after the first NVIDIA build there. Only a real NVIDIA machine can verify the CUDA step.

## NVIDIA gx image (`octarine-os-nvidia-gx`) (2026-11-16, Kevin: proof of concept, layering order os, nvidia, gx)

- **What it is.** `ghcr.io/redcodeworks/octarine-os-nvidia-gx`: the SAME gx layer as `octarine-os-gx` (`variants/gx`, the lists of the pinned `octarine-bins-gx` image) on top of `octarine-os-nvidia` instead of `octarine-os`. Model: `build-nvidia-gx.yml` is a thin caller of the reusable `dx-image.yml` (`variant: gx`, `base_name: octarine-os-nvidia`, `dx_name: octarine-os-nvidia-gx`, `promote_from_testing: false`, `extra_smoke: nvidia-smoke.sh present`), exactly like `build-nvidia-dx.yml` is for dx; same `workflow_run` trigger ("Build NVIDIA variant" finished on `main`) and guards, `latest` only, no commit status and no required check, its own concurrency group `build-nvidia-gx` (it never cancels or waits for `build-nvidia-dx`), its own `sign` and `NVIDIA gx build result` jobs. The image id reaches `gx.sh` as `GX_IMAGE_ID` (accepted: `octarine-os-gx` or `octarine-os-nvidia-gx`).
- **Where it is named** (mirror of nvidia-dx, no more): `build.sh` signature-policy refs (sixth repository, asserted by `default-smoke.sh`, `dx-smoke.sh`, `gx-smoke.sh`), `inputs-hash.sh` (`is_gx_only` lists the caller, so editing it changes `gx_inputs` only), `zizmor.yml` (the three ignores that name `build-nvidia-dx.yml`), `ujust switch-image` (image `nvidia-gx`, list, menu, GPU question, Secure Boot hint, signature-policy hint) and the `hardware-setup` nvidia step (an `*-gx` image id switches to `nvidia-gx`), README, `docs/`. `publish-latest.sh`, `publish-latest.yml`, `rollback-latest.yml` and `prune-daily.yml` do NOT name nvidia-dx (it publishes `latest` directly in its own caller), so they do not name nvidia-gx either.
- **The schedule is off on purpose (Kevin, 2026-11-16).** The cron of `build-nvidia.yml` is removed, so none of the three NVIDIA workflows runs on its own: Kevin dispatches "Build NVIDIA variant" on `main`, and the `workflow_run` guards of `build-nvidia-dx.yml` and `build-nvidia-gx.yml` (now `workflow_run.event == 'workflow_dispatch'`) start both after it; each also has its own `workflow_dispatch` (with `force`) to run alone. No cron anywhere; a freshness check or failure alert that expects a weekly NVIDIA run must not.
- **It cannot run until the NVIDIA variant builds.** Since 2026-11-16 the NVIDIA variant build fails on main (Mesa i686 26.2.7 against the base's x86_64 26.2.6, file conflicts in `nvidia.sh`); fix-or-drop is undecided and `nvidia.sh` is untouched. The new caller is skipped until "Build NVIDIA variant" succeeds on `main`, so nothing here was ever built (no local NVIDIA build either).
- **Open risks of the gx layer on the NVIDIA base (not solved, to be checked at the first real run).** (1) `required-fedora.txt` of the octarine-bins-gx image installs `mesa-vulkan-drivers`/`mangohud`/`libFAudio` for i686; the NVIDIA base replaces parts of the Mesa/GL stack with negativo17 packages, which is the same x86_64-versus-i686 version mismatch that breaks the NVIDIA build today, so the gx transaction can fail the same way (and `gx-smoke.sh` `same_mesa` would fail if it installs with mixed versions). (2) 32-bit Steam and Proton need the 32-bit NVIDIA driver libraries (negativo17 `nvidia-driver-libs.i686`); `gx.sh` does not install them and `gx-smoke.sh` does not check them (the akmods `nvidia-install.sh` may already ship them: unverified from here, read it in the first run's log). (3) `gx-smoke.sh` Mesa vulkan checks assume a Mesa driver stack that is the intended one (on an NVIDIA machine the Mesa Vulkan drivers are present but unused). (4) What carries over unchanged: the kernel-unchanged and one-kernel checks (the NVIDIA variant has the base's kernel plus kmods), the RPM Fusion Steam priority handling (applies only to the `steam` name), `validate-repos.sh` (negativo17 repositories are enabled by the base, so they are allowed), the Sunshine checks. `gx.sh` only got the image-id regex; the package side is deliberately unchanged.
- **First publication.** The new GHCR package starts private; the owner makes it public (and lets this repository's workflows write to it) once, or `ujust switch-image` reports it as not published.

## dx-gx image (`octarine-os-dx-gx`, alias `fx`) (2026-11-16, Kevin: experimental, dispatch only)

- **Model (one sentence).** The fx image is the gx layer applied on top of `octarine-os-dx` (layering order os, dx, gx), built by a thin dispatch-only caller of the shared `dx-image.yml`, exactly like `build-nvidia-gx.yml` is the gx layer on the NVIDIA base.
- **The caller.** `build-dx-gx.yml`: `variant: gx`, `base_name: octarine-os-dx`, `dx_name: octarine-os-dx-gx`, `channel: latest`, `promote_from_testing: false`, `extra_smoke: dx-smoke.sh` (the gx smoke test runs by itself, the second one proves the dx layer is intact). Triggers: `workflow_dispatch` only (input `force`), guarded to `main`: no schedule, no `workflow_run`, no push, no `testing` channel, no commit status, no required check (its result job is `dx-gx build result`). Own concurrency group `build-dx-gx` (never cancels, never waits for another image), own `sign` job. Nothing rebuilds it when dx moves: dispatch it again, the plan job skips when the `octarine-os-dx:latest` digest and the gx inputs are unchanged. Because it only exists on `main` after a promotion, the first dispatch comes after the PR that adds it is merged.
- **Alias.** `ujust switch-image fx` maps to `dx-gx`, i.e. `octarine-os-dx-gx`. It is a user-facing alias only: there is NO second registry package and NO second signature rule.
- **Where it is named** (mirror of nvidia-gx): `build.sh` (seventh signature-policy repository, asserted by `default-smoke.sh`, `dx-smoke.sh`, `gx-smoke.sh`), `inputs-hash.sh` (`is_gx_only` lists the caller), `zizmor.yml` (`self-repository` ignore only: the caller has no `workflow_run` and no `GITHUB_ENV` writes), `ujust switch-image` (image `dx-gx`, alias `fx`, list, menu, GPU question not applicable, signature hint), the `hardware-setup` nvidia step (an `*-dx-gx` id switches to `nvidia-dx`: there is no NVIDIA fx image, and the dx layer is the one that keeps the toolchain; revisit if one is ever built), `virthost-setup` (its dx-image check accepts `*-dx-gx`), README, `docs/`.
- **What the gx layer assumes about its base** (checked 2026-11-16 against the dx base). Unchanged and fine: `gx.sh` takes `GX_IMAGE_ID` `octarine-os-dx-gx` (regex `^octarine-os(-nvidia|-dx)?-gx$`); `dnf5` skips what the dx lists already installed; the before/after kernel check and the one-kernel check read the kernel the dx base carries (dx does not change the base's kernel); `optional-packages-missing` exists (the default image creates it, dx appends, gx appends); `validate-repos.sh` has the same allow-list; Steam still comes from negativo17. What does NOT carry over and was fixed: `gx-smoke.sh` asserted "no dev-only recipe (ujust dev is dx only)", which fails on fx, so on `EXPECT_IMAGE_ID=octarine-os-dx-gx` it asserts the opposite; `virthost-setup` rejected an image id that does not end in `-dx`. Labels: the image inherits the dx base's `dx-tree`, `dx-inputs` and `bins-dx` labels next to its own `gx-tree`, `gx-inputs`, `bins-gx`; the plan job compares only `gx-inputs` and `org.opencontainers.image.base.digest` (set to the dx digest), so the stale `dx-inputs` label is harmless but describes the dx layer's inputs, not this build's. The image `title`/`description` labels are set by the caller.
- **Combined smoke.** gx-smoke (games, Sunshine, Steam source, repos, kernel, identity) plus dx-smoke (toolchain, `-devel`, QEMU/libvirt, dev recipe, datastore recipes, kernel, identity), both with `EXPECT_IMAGE_ID=octarine-os-dx-gx`.
- **Size.** Big: gx alone is about 11 GB and fx adds the dx layer on top; `dx-image.yml` fails an image above `MAX_IMAGE_GIB` (see the measured size below) and the runner needs room for the build plus the chunkah copy. Measured locally 2026-11-16 (podman image size, uncompressed): default 9.5 GB, dx 12.2 GB, dx-gx 15.5 GB (14.4 GiB), so `build-dx-gx.yml` passes `max_image_gib: 18` to `dx-image.yml` (new input, default 15) instead of sitting 0.6 GiB under the old limit. The CI runner has not run it: free disk after the build and chunkah copy is the thing to read in the first run.
- **First publication.** The new GHCR package starts private; the owner makes it public once, or `ujust switch-image` reports it as not published. Untested on hardware.

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
  - `cuda` (last step, shown only with an NVIDIA driver): the rootless `cuda` distrobox with the CUDA toolkit, through CDI; option `--image IMAGE`. Design, hooks and what is unverified: "NVIDIA dx image and the CUDA toolbox" above.
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

Edit `config/image.env` (`IMAGE_NAME`, `REPO_ORGANIZATION`, `IMAGE_DESC`), generate a key
(`COSIGN_PASSWORD="" cosign generate-key-pair`), commit `cosign.pub`, create a protected environment
`signing` limited to `main` and `testing` (deployment branch policies through the API) and store the private key
as the `SIGNING_SECRET` environment secret. Never commit `cosign.key`. Review `build.sh` and `system_files/`, enable Actions and make the GHCR package public.

## build.sh notes

- **No RPM Fusion in the base (checked 2026-11-16).** The booted image's `/usr/etc/yum.repos.d` (and every older deployment's) holds only the base's akmods COPR, negativo17 and the `rok-cdemu` COPR file, `/usr/share/dnf5/repos.d` only Fedora's own files, and `validate-repos.sh` allows no RPM Fusion id. The `rpmfusion-*` repo files seen on nox in `/etc/yum.repos.d` are local leftovers of the machine's `/etc` (not owned by any package; the owner enabled `rpmfusion-nonfree-steam` by hand on 2026-10-17), not part of any image. A build that needs RPM Fusion (the gx variant, for Steam) must add it itself: Fedora's `fedora-workstation-repositories` package ships a DISABLED `rpmfusion-nonfree-steam.repo` in `/usr/share/dnf5/repos.d` (key in `/usr/share/distribution-gpg-keys/rpmfusion`, already in the image); enable it for that transaction only, disable it again, and keep it out of `validate-repos.sh`'s allow-list (or add the id there on purpose).
- **Local SELinux module `octarine-local` (2026-11-17; every image, dx/gx inherit it).** Source `system_files/usr/share/octarine-os/selinux/octarine-local.cil` (the three rules, the reasons and the upstream references are in its comments), installed by the `SELinux: local policy module` step of `build.sh` with `semodule -i` after all package steps (CIL needs no selinux-policy-devel; the rules name pcp and tuned types, so a missing package or a renamed type makes `semodule -i` fail and with it the build, no `|| true`). It fixes three boot-time AVC denials seen on nox: `ps` run by `pcp_pmlogger_t` and `pcp_pmie_t` reading the systemd-nsresourced socket (an `allow ... sock_file read`, the same narrow rule Fedora added for other domains in selinux-policy PRs #3469, #3456 and #3495; no PCP rule exists upstream), and tuned 2.28's `bootc loader-entries` call whose SELinux probe runs `chcon` and is denied `mac_admin` for `tuned_t` (a `dontaudit` only: the domain is NOT given `mac_admin`; tuned issue #895, fix PR #892). Remove a rule when its fix has reached the image: take the module out on a test boot (`sudo semodule -r octarine-local`) and look for AVC denials (`journalctl -b _TRANSPORT=audit`); drop the tuned rule when tuned no longer starts bootc from `tuned_t`. The smoke test (`default-smoke.sh`) checks that the module is listed and that its extracted CIL still has the PCP rule (`sesearch` is not in the image). Persistence (verified in a local build: `semodule -i` at build time writes `/etc/selinux/targeted/active/modules/400/octarine-local` and recompiles `/etc/selinux/targeted/policy/policy.35`, nothing under `/var/lib/selinux`; `sesearch` on that compiled policy shows both `allow ... sock_file read` rules and the `dontaudit`, and no `mac_admin` allow for `tuned_t`; the 3-way merge below is ostree's documented behavior, NOT yet observed on a host): the policy store is `/etc/selinux/targeted/active` (module at `modules/400/octarine-local`, compiled policy beside it), which an image carries as `/usr/etc`; on a host the 3-way `/etc` merge keeps any file that was changed locally and adds the image's new ones, so a machine where the same module was installed by hand (nox) keeps its own identical copy and nothing conflicts (same name, same priority 400: the image's copy is moot there). Remove a hand-installed copy with `sudo semodule -r octarine-local` only when you want the image's copy to take over. The base image itself ships a priority-400 module `permissive_bootupd_t` (verified in `silverblue-main:45`), so `permissive bootupd_t` in Cockpit's SELinux page is NOT a machine-local customization. What IS machine-local on nox and not in the image: the booleans `virt_sandbox_use_all_caps` and `virt_use_nfs` and the virthost fcontext rules. Do not run Cockpit's SELinux "automation script": it starts with `module -D` and `fcontext -D` and would delete local modules and fcontext rules.
- Packages come from the base's repos (distrobox, ffmpeg and pam-u2f already ship in `silverblue-main`; its
  multimedia stack is negativo17, so `gstreamer1-plugins-bad/-ugly` replace the `-free` variants and there is no
  `mesa-va-drivers-freeworld`). Package names are release-specific; `dnf5 install` stops on an unknown name.
- `solaar-udev` is in the critical `dnf5 install` block (it already ships in the base and stays listed in case the base drops it) and in the `CRITICAL` list of both smoke tests; it provides `/usr/lib/udev/rules.d/42-logitech-unify-permissions.rules` (device permissions, including the uinput line). **The `solaar` GUI package is NOT in the image (Kevin, 2026-11-16, after briefly shipping it with an opt-in autostart toggle, PR #228 history):** a user who wants Solaar installs the Flatpak (Flathub `io.github.pwr_solaar.solaar`, community-packaged and unverified, no autostart: they add their own autostart entry). `default-smoke.sh` checks that `solaar` is not installed and that the rules file exists and has the uinput line. Not verifiable without a boot: that the Flatpak sees a receiver.
- Only `gcc`, `gcc-c++`, `make` and `binutils` in the default image (2026-11-14; no cmake, ninja, meson, clang or -devel libraries): bigger builds happen in a toolbox or on the dx image. Nothing in the image build compiles from source.
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
  `octarine-images` repo (`dev-toolbox`: `ghcr.io/redcodeworks/fedora-toolbox:latest`, weekly, packages baked in);
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
  (built in the octarine-images repo: RPM Fusion Steam, gamescope, mangohud, gamemode, protontricks and more; no
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
  major changes, confirm, replace via recreate; no package resolution test, the octarine-images CI covers it),
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
  `system_files/usr/share/ublue-os/distrobox/`, with an image from the octarine-images repo; extend `tests/toolbox.sh`.
- **Wrapper scripts.** Exported wrappers need a stdin guard, or they hang tools that talk over stdio.
- **Installer scripts.** SDKMAN and nvm (in the toolbox) are the only installer
  scripts; nothing here needs sudo.
- **Other recipes.** `ujust gnome-candy` runs a recipe of the candy-for-gnome repo from a fresh checkout in
  `~/.cache/candy-for-gnome/repo` (`CANDY_FOR_GNOME_REF` picks the ref).
  `user-setup [user] [--yes|--no] [--only STEP[,STEP...]]` replaced the seven single-purpose recipes `add-user-groups`,
  `flatpak-games-access`, `steam-flatpak-devices`, `vscode-flatpak-podman`, `podman-desktop-deny-docker-socket`,
  `chrome-flatpak-webapps` and `gearlever-applications` (removed, no aliases). It is an interactive y/n checklist; steps
  in order: `groups` (the gum checklist names only the groups `getent` finds, so the default image says gamemode and input; copies the `gamemode`, `input` and `libvirt` lines from `/usr/lib/group` into `/etc/group` first;
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
  non-zero. **`editor` step (2026-11-15, Kevin: "define a default editor"; a step of its own right after `shell`, no sudo):** options vi (always), nano, vim, nvim, hx, only when found (PATH, then
  `/home/linuxbrew/.linuxbrew/bin`, then `~/.local/bin`; hooks `USER_SETUP_EDITOR_DIRS` and `USER_SETUP_EDITOR_SYSDIRS`); the default answer is "keep the current settings" (`--yes` alone keeps too);
  `--editor NAME` (unknown or not installed: exit 2 listing the detected ones) implies `--only editor`. It writes ONE managed file, `~/.config/environment.d/50-editor.conf`
  (`EDITOR`, `VISUAL`, `SUDO_EDITOR`, KEY=value, a header with the undo): SUDO_EDITOR is always the absolute path (sudoedit runs with sudo's restricted PATH), EDITOR and VISUAL the plain name only when the
  binary is in `/usr/bin`, `/bin` or `/usr/local/bin`, else the absolute path (Homebrew and `~/.local/bin` are on PATH only in login shells, not for everything the session starts). Lines in the
  user's own rc files (`.bashrc`, `.bash_profile`, `.profile`, `.zshrc`, `.zshenv`, `.zprofile`, `.bashrc.d/*`, fish `config.fish` and `conf.d`, other `environment.d` files) that set these
  variables are listed with file and line, never edited, and the question to write anyway defaults to NO (an explicit `--editor` writes with a note). Each such line whose value differs from the pick is reported with file, line, variable, its value, the value the pick writes and the exact line to remove or change (another `environment.d` file is named as such); tested with a fixture HOME (`set -gx EDITOR` in `config.fish`, `export EDITOR=` in `.bashrc`). Verified in environment.d(5): the files are read by
  the systemd user manager and passed to the services it starts (GNOME's terminal server is the example in the man page), SSH logins and plain TTY logins do not read them. FOUND on nox (not tested end to end):
  the image's base ships `nano-default-editor` (`/etc/profile.d/nano-default-editor.sh` sets `EDITOR=/usr/bin/nano` only when unset, its fish twin in `vendor_conf.d` uses `set -q`), and
  `systemctl --user show-environment` on nox shows `EDITOR=/usr/bin/nano`: a session's `systemctl --user import-environment` (niri-session does it, GNOME imports the login environment) copies the LOGIN
  SHELL's environment, which lacks environment.d, over the manager's, so environment.d alone would probably lose for EDITOR. Hence two small image files read the SAME managed file for login shells:
  `system_files/etc/profile.d/octarine-os-editor.sh` (bash, zsh; sorts after the nano one; accepts only the three keys and plain path characters, parsed never executed) and
  `system_files/usr/share/fish/vendor_conf.d/octarine-os-40-editor.fish`; a user's own rc files still win. UNVERIFIED: the import ordering in a real niri and GNOME login. Test hooks:
  `USER_SETUP_FISH/ZSH/SHELLS/SKEL/SEARCH_DIRS/FONTS_BREWFILE`. Tests: `tests/recipes/user-setup.sh` (fake
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
  installed; the MangoHud directory name is unverified), `extest` (installs the prebuilt libraries of the image, see "Prebuilt binaries": `/usr/lib/extest/lib/libextest.so` and `lib64/libextest.so`
  into `$EXTEST_DEST` (default `~/.local/lib/extest`) with the same relative names, 0755, comparing sha256 first and saying
  "already done" when both are identical; fails with a clear message when the image lacks them; test hook
  `GAMING_SETUP_EXTEST_SRC` for the source directory; nothing is built any more, `EXTEST_SRC` and `EXTEST_COMMIT` are gone), `desktop` (launchers
  `octarine-gaming-steam*.desktop` carrying `X-Octarine-Generated=ujust gaming-setup`; only marked files are
  overwritten; the extest hook (only when both libraries are installed) is `--filesystem=<dir>:ro --env=LD_PRELOAD=<dir>/$LIB/libextest.so`
  passed to `flatpak run` per launcher instead of a global override. The literal `$LIB` is the dynamic loader's token (ld.so(8):
  `lib` or `lib64` per process), so Steam's default 32-bit client loads the 32-bit library and the experimental 64-bit client
  (an application setting) the 64-bit one. In the `Exec=` line the argument is double-quoted and the dollar sign escaped as
  `\\$` (desktop entry spec: the file's backslash escape comes first, then the quoting rule; GLib's parser gives back `$`);
  `tests/recipes/gaming-setup.sh` asserts the generated text and its unescaped form. UNVERIFIED: `$LIB` expansion inside Steam's
  Flatpak (the sandbox's loader and library layout), and a real Steam run with either client; gamescope launcher: `flatpak run
  --command=gamescope ... -f -W -H -r --adaptive-sync -- steam -gamepadui`, the `steam -gamepadui` part is an
  unverified choice; resolution from Mutter DisplayConfig, else `niri msg --json outputs` with jq, else `GAMING_SETUP_RES`
  or a prompt; never silent), `gamemode` and `reset` (also removes the old global extest override entries and, when asked, both libraries). Tests:
  `tests/recipes/gaming-setup.sh`. Extest is by Supreeeme and contributors, MIT license; credited in the README; the image ships
  the built libraries with the license text and source record ("Prebuilt binaries").
  Flatpak recipes only add or remove their own override entries (Flatseal shows the result); recipes are
  idempotent, and each override-changing recipe has a matching reset (`user-setup` prints the undo per applied step).
  Themes land in `~/.themes`, icons in `~/.local/share/icons`; `gnome-candy` needs network, git and just, and
  without a name opens a checklist (everything off by default). The extest step is not verified end to end with a real Steam.

## Image hygiene notes

- Labels were missing from the pushed image until `ostree-rechunk` passed them on (see "Labels").
- The base image may carry `/etc/brlapi.key` (brltty's API key, generated at package install and so identical
  in every copy of a public image) and a copy of `/sysroot/ostree/repo/objects`; neither is created by this
  repo's Containerfile or `build.sh`. Findings are with the hub for follow-up.
