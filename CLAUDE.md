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
Requirements, Highlights, Install (with the Variants table and the Recipes list: every `ujust` recipe, one line each, no
step lists, the recipes explain themselves), then the closing block Contributing, License, Credits and About this repo
(personal project assisted by Claude, tested only on the owner's setup, not actively maintained beyond the owner's needs,
forks encouraged; its `### Fork it` heading is linked from `AGENTS.md`), disclaimer last. No design rationale, process
history, CI or branching internals, agent instructions or recipe step lists in it. American English throughout. Checked
against the repo by `tests/readme-defaults.sh` (recipes, variant URLs, no stale sections).

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
- `build_files/build.sh`: guard against secrets in `system_files`, rename the base recipe files `10-update.just` and
  `30-distrobox.just` to `*-base.just` (our files of the same names import them; a missing one fails the build), copy
  `system_files` (which overwrites the base's `15-luks.just`, `40-nvidia.just` and `50-akmods.just` with ours), fail if a
  `toggle-nvk` recipe is still installed, generate the
  container signature policy from `IMAGE_ORG`/`IMAGE_NAME`/`cosign.pub`, install packages, enable services.
- `system_files/`: files copied onto `/` (PAM, sysctl, firewalld, sudoers, Flatpak preinstall lists, `ujust` recipes).
- `Justfile` (repo root, not in the image): build, VM and release recipes. `just check` runs `just --fmt --check`.
- `.github/workflows/`: `build-dx.yml` (the reusable workflow that builds the dx image, called by `build.yml` and `build-beta.yml`, see "dx image: a reusable workflow"), `test.yml` (quick tests and secret scan on dev branches), `build.yml` (plan, build, smoke test, push, then a separate `sign` job in the `signing`
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

## Prebuilt binaries (binaries/)

The default image ships binaries that are built in this repository, not compiled in the image build and not taken from a foreign
registry: the sched_ext schedulers (`scx_*`) and the extest libraries. They are built from pinned upstream commits into ONE
signed `FROM scratch` image, `ghcr.io/redcodeworks/octarine-os-binaries`, which the image build copies from. nvidia and the dx
variants inherit them from the default image. (History: #61 first consumed two images built by the fedora-toolbox repository,
pinned by digest; Kevin moved the build here on 2026-11-13 because the binaries are built for this environment.)

- **Sources.** `binaries/Containerfile` (build context: `binaries/`), `binaries/lib/` (`upstream-env.sh` parser, `fetch-source.sh`,
  `stage.sh`, `assemble.sh`), and per component `binaries/scx/` and `binaries/extest/`: `upstream.env` (`UPSTREAM_REPO`, optional
  `UPSTREAM_WATCH`, `UPSTREAM_TAG`, `UPSTREAM_COMMIT`; parsed, never sourced), `build.sh`, and for scx `schedulers.tsv`.
  `binaries/scx/schedulers.tsv` (name, minimum kernel (empty for all seven), description up to 120 characters, curated from the scheduler
  READMEs at v1.1.4) is the source of truth for the scheduler list: adding a scheduler is one line there plus the next bump (check the READMEs
  again then). scx: github.com/sched-ext/scx tag v1.1.4, peeled commit `e7b3a219...`, GPL-2.0; `scx_cake` has no LICENSE of its
  own (a note, the repository LICENSE ships). extest: OUR FORK `redcodeworks/extest` at commit `cb77cd4f...` (a plain mirror, MIT; pin by
  commit, the tag is a label, fork sync does not always bring tags), upstream watched is `Supreeeme/extest`.
- **Build.** Builder: `registry.fedoraproject.org/fedora:45@sha256:e15959f3...` (a manifest-list digest, the release of the image the binaries
  go into; re-resolve with `skopeo inspect --raw docker://registry.fedoraproject.org/fedora:45 | sha256sum` to move it; it is part of `binaries/`, so
  a new builder digest changes the tree hash and rebuilds). Toolchain from Fedora's repositories (at the first build: rustc and cargo 1.99.1,
  clang 23.1.5, glibc 2.44; recorded in each build's `BUILDINFO`). scx dependencies: `git-core rust cargo clang llvm lld libbpf-devel
  elfutils-libelf-devel zlib-devel libzstd-devel pkgconf-pkg-config bpftool make gcc binutils`; one `cargo build --release --locked -p <each
  scheduler of the tsv>` (about 5.5 minutes). extest: `git-core rust cargo gcc binutils rust-std-static-i686-unknown-linux-gnu
  glibc-devel.i686 libgcc.i686`, `cargo build --release --locked` for `x86_64-unknown-linux-gnu` and `i686-unknown-linux-gnu` (upstream's
  `.cargo/config.toml` defaults to i686, so both are named); the highest GLIBC symbol version needed is 2.34 (fine for Flatpak runtimes).
  `fetch-source.sh` fetches the tag (or, for the fork, the commit) and FAILS unless it resolves to exactly the pinned commit (a moved tag
  cannot slip in). `stage.sh` smoke-runs each scheduler's `--version`, checks the ELF class of the extest libraries and writes
  `SOURCE` and `BUILDINFO` (rustc, cargo, clang, glibc, both extest targets, the shared libraries each file needs; a 64-bit file must
  resolve with `ldd`; the libraries are libelf, libz, libzstd, libgcc_s, libc).
- **The image.** `/scx/bin/<name>`, `/scx/schedulers.tsv` (FOUR tab-separated fields: name, `bin/<name>`, minimum kernel (empty today),
  description; no header; read it with `awk -F'\t'` or `cut -f`, never `IFS=$'\t' read`, which collapses the empty field),
  `/extest/lib/libextest.so` (ELF32), `/extest/lib64/libextest.so` (ELF64); `/scx` and `/extest` each hold `LICENSES/`, `SOURCE`, `BUILDINFO`;
  `/LICENSES`, `/SOURCE`, `/BUILDINFO` combine both.
- **Tag = tree hash.** The image tag is `git rev-parse HEAD:binaries`: content-addressed, so the same content is built once and reused by
  `testing`, `main`, the beta channel and the daily rebuild (build once, promote falls out for free). Old hash tags are never pruned
  (small).
- **Workflow** `.github/workflows/binaries.yml` (reusable, also `workflow_dispatch`), called by the `binaries` job of `build.yml` (only when the
  plan wants an image build, not for a promotion or a docs-only push) and `build-beta.yml`, before the image build; the build job `needs` it. Jobs:
  `check` (tree hash; `binaries-lookup.sh`: the tag exists and `cosign verify --key cosign.pub` accepts its digest: green "binaries
  unchanged, nothing to build"; a missing tag, or an existing one whose signature fails, is built again), `build` (`podman build` in the pinned
  builder, `binaries-layout.sh` checks the exported file list, then `push-tags.sh` pushes ONE manifest digest), `sign` (environment `signing`,
  the same `SIGNING_SECRET` (a repository secret: the calling jobs pass it on with `secrets: inherit`, without it the sign step fails with "invalid pem block"), old bundle format, then verify by digest and by tag), `result` (hands over the digest). Only `testing` and
  `main` publish; on any other ref (a validation dispatch) the binaries are built and checked but never pushed or signed, no digest is
  handed over, and the image build stops with an instruction (`binaries-use.sh`): a change to `binaries/` is first fully exercised by the
  merge into `testing` (validate the binaries build alone with `gh workflow run binaries.yml --ref <branch>`). The binaries jobs carry no
  required check name; `Build and push image`, `Sign and verify images` and `Build dx and push image` are unchanged, and a failed binaries
  job fails `Build and push image` (the build job is skipped). The image build verifies the handed digest with `cosign.pub`
  (`binaries-use.sh`, which exports `BINARIES_IMAGE=<image>@<digest>`; `just build` passes it as a build argument, defaulting locally to the
  hash tag of the checked-out tree, and labels the image `io.github.redcodeworks.octarine-os.binaries`). The `Containerfile` has no default for
  `BINARIES_IMAGE`. GHCR creates a new package private: the hub must make `octarine-os-binaries` public (the GPL source records ship in
  the image either way).
- **Which path ran.** The run shows it: a green job "Reuse the binaries image" (the lookup found a signed image for the hash, the build and sign jobs are skipped) or "Build the binaries image" plus "Sign the binaries image"; `binaries.yml` outputs `action` (`reused`, `built` or `validated` for a branch that cannot publish), `hash` and `digest`, each deciding job writes one line to the run summary, and `build.yml` and `build-beta.yml` repeat it; a tag whose signature fails to verify is not reused, the build path rebuilds and signs it again.
- **Installation.** The build step bind-mounts the binaries image at `/binaries`; `build_files/install-binaries.sh` (called by `build.sh`;
  `BINARIES_ROOT` and `DESTDIR` exist for tests) checks that `schedulers.tsv` and `bin/` agree both ways (awk, four fields), then installs
  the schedulers to `/usr/bin/`, the manifest to `/usr/share/octarine-os/schedulers.tsv`, the extest libraries to
  `/usr/lib/extest/lib/libextest.so` and `/usr/lib/extest/lib64/libextest.so`, and the license texts, `SOURCE` and `BUILDINFO` to
  `/usr/share/licenses/octarine-os-binaries/<scx|extest>/` (it fails when the GPL or MIT text is missing). Nothing is enabled or started:
  no unit, no preset.
- **Smoke test** (`build.yml`, copied into `build-beta.yml`; `tests/binary-images.sh` fails when they drift): the manifest exists; per scheduler
  it is executable, `--version` runs, and `ldd` shows no `not found`; the extest libraries are executable and `file` shows a 32-bit and
  a 64-bit ELF; the GPL-2.0 and MIT texts and the `SOURCE` and `BUILDINFO` records ship.
- **Weekly upstream check** `.github/workflows/upstream-check.yml` (Monday 07:00 UTC plus `workflow_dispatch`; scheduled workflows run only from
  `main`, so the schedule starts after the first promotion). `upstream-check.sh` per `binaries/<name>/upstream.env`: scx asks `releases/latest`
  (not prereleases); extest asks the watched project and counts a release or tag only when it is NOT an ancestor of the pinned commit
  (compare API on the fork); when the fork lacks the new commit it ends green with the notice "the fork is behind upstream: sync it
  (`gh repo sync redcodeworks/extest`) and rerun" and never writes to the fork. On a newer release `bump-upstream.sh` opens or updates ONE pull request per
  component on `bump/<name>` into `testing`, changing only `UPSTREAM_TAG` and `UPSTREAM_COMMIT` (an existing branch gets a new commit, never a
  force-push), body with the release notes and compare links; nothing is published from this workflow (the merge into `testing` changes the tree
  hash, and the build after it builds and signs the new binaries). The owner merges bump pull requests. Tests: `tests/upstream-check.sh`.
- **Token (both bump workflows).** Only the default `GITHUB_TOKEN` (job permissions `contents`, `pull-requests`, `actions` write; no personal
  token, no `BUMP_TOKEN`). GitHub starts no `push` or `pull_request` workflow for events made with it, except `workflow_dispatch`, so after each push
  to the bump branch the script runs `gh workflow run test.yml --ref bump/<name>`: the jobs of `test.yml` (named `test` and `secrets`, no
  `if:`) run on the branch tip. Fail soft: a failed dispatch is a warning and the PR body says to run that command by hand. The setting "Allow GitHub Actions
  to create and approve pull requests" must be on (the hub turned it on 2026-11-13). UNVERIFIED on GitHub: whether a dispatched run satisfies the
  required checks of the pull request, and the first real run of either workflow (they must be on `main` first).
- **dev-packages.** The only image still pinned by digest from outside is `dev-packages` (`variants/dx/Containerfile`, key
  `keys/redcodeworks-toolbox-cosign.pub`). `.github/workflows/bump-pins.yml` (Tuesday 07:00 UTC plus dispatch) runs `.github/scripts/bump-pin.sh dev-packages`:
  resolve `:latest` (`skopeo inspect --raw | sha256sum`), verify the signature, compare. Decisions (exit code, result): equal (0, `equal`,
  "nothing to bump"; the signature is still verified); different (10, `different`: the digest line and the tag line, the dated tag with the same
  digest or `latest`, nothing else; ONE pull request on `bump/dev-packages-digest` into `testing`); registry unreachable, `latest` missing or an
  empty answer (1, `unreachable`: the job fails, nothing changes); bad signature (2, `badsignature`: fails, even when the digest is equal); malformed
  pin or unknown image (3). Tests: `tests/bump-pins.sh`; `just dev-packages-bump` stays for a manual bump.
- **Tests.** `tests/binaries-build.sh` (parser, commit verification with local repositories, `stage.sh`, the scheduler list driving `scx/build.sh`,
  `assemble.sh`, the real files), `tests/binary-images.sh` (lookup, gate, layout, installer, smoke text, workflow wiring), `tests/upstream-check.sh`,
  `tests/bump-pins.sh`.
- **Unverified.** The first real binaries build (it first runs on a push to `testing` or by dispatching `binaries.yml`); that a scheduler loads
  on a real kernel (CI cannot load BPF; only `--version` and `ldd` run); the `$LIB` expansion inside Steam's Flatpak and a real Steam run (see
  the gaming-setup notes). The scheduler runtime (units, recipe) is separate work.
- **Undo.** Remove `binaries/`, the three `binaries-*.sh` scripts, `binaries.yml`, `upstream-check.yml`, the `binaries` jobs and steps, the
  `BINARIES_IMAGE` argument and mount, `install-binaries.sh`, the smoke assertions and the tests; restore the cargo build in the `extest`
  step from git history.

## sched_ext schedulers (`scx@`, `ujust scheduler`)

The seven shipped schedulers (`scx_rusty`, `scx_lavd`, `scx_cake`, `scx_bpfland`, `scx_cosmos`, `scx_flash`, `scx_p2dq`, sched-ext/scx v1.1.4,
built from `binaries/scx`, see "Prebuilt binaries"; Fedora's own old `scx_rusty` package is not used) are BPF schedulers that replace the
kernel's default (EEVDF) while loaded. EVERYTHING SHIPS OFF: no preset enables one (`00-octarine-scx.preset` says `disable scx@*.service`), none runs
after install; the owner decides default-on after a soak. Whatever fails, the machine stays on EEVDF. Adding a scheduler later = one line in
`binaries/scx/schedulers.tsv` plus the upstream bump; the registry, drop-ins, menus and tests derive from it.

- **Registry.** `build_files/gen-schedulers.sh` (called by `build.sh` after `install-binaries.sh`) reads `/usr/share/octarine-os/schedulers.tsv`
  (four tab-separated fields: name, `bin/<name>`, minimum kernel (EMPTY for all seven today), description up to 120 characters; read with
  `awk -F'\t'` or `cut -f`, never `IFS=$'\t' read`) and writes `/usr/share/octarine-os/schedulers.d/<instance>.conf` (`NAME`, `INSTANCE`, `BINARY`,
  `DESCRIPTION`, `MIN_KERNEL`, `FLAGS`; parsed with awk, never sourced). The **instance name is the scheduler name without `scx_`**: `rusty`, `lavd`, `cake`,
  `bpfland`, `cosmos`, `flash`, `p2dq` (it equals the scheduler's `sched_ext_ops` name, which `/sys/kernel/sched_ext/root/ops` shows). It also writes per
  instance `scx@<name>.service.d/10-conflicts.conf` (`Conflicts=` on every other instance) and, only when the registry has a minimum kernel,
  `20-kernel.conf` (`ConditionKernelVersion=>=<min>`).
- **Unit** `system_files/usr/lib/systemd/system/scx@.service`: `Type=simple`, `ConditionPathExists=/sys/kernel/sched_ext`, `StartLimitIntervalSec=0`
  (user-triggered start/stop cycles never trip systemd's start limit), `Restart=on-failure`, `RestartSec=5`, `ExecCondition=` `scx-preflight %i`,
  `ExecStart=` `scx-run %i`, `ExecStartPost=` `scx-verify %i`, `[Install] WantedBy=multi-user.target`. No hardening directives, as in upstream's own
  `services/scx.service` (which has none either): loading a BPF scheduler needs root and a sandbox that blocks `bpf()` would stop it; whether stricter
  settings still load is UNVERIFIED. Helpers in `/usr/libexec/octarine-os/` (`scx-lib.sh`, `scx-preflight`, `scx-run`, `scx-verify`):
  `scx-preflight` refuses quietly (exit 1, the unit is skipped, not failed) when `/sys/kernel/btf/vmlinux` is missing or the marker
  `/var/lib/octarine-os/scx-disabled/<name>` holds the running `uname -r`; `scx-run` runs the registry's binary (must be `/usr/bin/scx_*`) with the
  registry's flags and a cleared environment; `scx-verify` waits up to 5 s until `/sys/kernel/sched_ext/state` is `enabled` and
  `/sys/kernel/sched_ext/root/ops` equals the instance (sysfs facts read from the kernel docs and a running nox; the `root` directory exists only while a scheduler is loaded).
- **Safeguards (each tested in `tests/schedulers.sh`).** (a) The polkit rule is GENERATED at image build: `build_files/gen-schedulers.sh` fills the template `usr/share/octarine-os/polkit/50-octarine-scx.rules.in` with the exact alternation of the registry instance names and writes `usr/share/polkit-1/rules.d/50-octarine-scx.rules`. It grants `YES` for
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
- **Recipe `ujust scheduler`** (group Setup, above `toolbox`, not part of `hardware-setup`): step 1 scheduler at boot (None plus every registry entry, current first; `sudo -v` once, then `sudo systemctl enable --now scx@NAME.service` FIRST and the enabled other instance is disabled only after the new one is verified running (`systemctl is-active` plus `/sys/kernel/sched_ext/state` and `root/ops`, waited up to `SCHEDULER_WAIT` seconds, default 5); "already set" means enabled AND running; a scheduler that does not run is reported FAILED with the reason (no BTF, the crash-loop marker of this kernel, or the last journal lines), the new instance is disabled again if this run enabled it and the old one is started again, and a marker is removed (`sudo rm -- /var/lib/octarine-os/scx-disabled/NAME`) only when the user confirms (default no; never under `--yes`); sharing one security-key touch between the sudo commands is NOT guaranteed (it depends on the sudoers credential cache); never retried; exact command printed on failure), step 2 scheduler while GameMode is active (Skip, None, entries; writes `scheduler.conf`, no sudo). Every option shows its
  description (menu text shortened to 76 characters; `--list` shows the full text). Flags `--boot`, `--gamemode`, `--status`, `--list`, `--restore`, `--yes`, `--no`, `-h`; unknown name or option exits 2; refuses root; "not applicable" without
  `/sys/kernel/sched_ext`. Test hooks `SCHEDULER_REGISTRY|SYSFS|STATE_DIR|USER_CONF|WAIT|BTF|KERNEL`. Tests: `tests/scheduler-recipe.sh`.
- **Tier 1 compatibility check** (`.github/scripts/scx-kernel-check.py`, a step after the smoke test in `build.yml` and `build-beta.yml`, run inside the built image; the dx and NVIDIA variants inherit the same kernel and the
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

## Datastore containers (dx image only, opt-in)

The dx images ship generic datastore and Kafka Quadlets: rootless, user-level, STOPPED by default, nothing enabled, no lingering. Derived from the
owner's own Quadlets (which override them from `~/.config/containers/systemd` until removed); nothing personal, no airflow, connect, superset, trino,
lakekeeper or dvdrental, no `localhost/` image, no `%h` or home path.

- **Rule.** The Quadlets are rootless user units: their start and stop state never needs administrator rights or any privilege prompt. Start and stop are
  `systemctl --user start|stop <unit>` only. Only the image build writes under `/usr`. Every shipped port is bound to `127.0.0.1` and above 1023.
  `tests/datastore.sh` fails if a shipped Quadlet, recipe, helper, the pin file or this section mentions a privilege-escalation tool, if a unit publishes
  a port below 1024 or anything but `127.0.0.1`, and if a recipe runs as root.
- **Files.** `variants/dx/datastore/quadlets/` (templates), `variants/dx/datastore/datastore.env` (the ONE pin file), `variants/dx/datastore/render.sh`
  (run by `dx.sh` at build: copies the templates to `/usr/share/containers/systemd/users/` and replaces each `@NAME_IMAGE@` with
  `<image>:<tag>@<digest>`; fails on a missing or malformed pin, a `latest` or floating tag, or a tag outside its major). Units: `datastore.pod`
  (`PodName=datastore`, ports 5432 PostgreSQL, 6379 Valkey, 8333 S3, 9333 SeaweedFS master, 8889 filer on loopback), `postgresql.container` (container
  name `pgsql`), `valkey.container`, `seaweedfs.container`, `kafka.pod` + `kafka.container` (KRaft, 9092), `lakehouse.network`, the named `local`-driver
  volumes `postgresql-data`, `valkey-data`, `seaweed-data`, `kafka-data`. No `[Install]`, no preset, no lingering. Generated unit names (read with
  `quadlet --user --dryrun` on the image's podman 6.1): `datastore-pod.service`, `kafka-pod.service`, `postgresql.service`, `valkey.service`,
  `seaweedfs.service`, `kafka.service`, plus `*-volume.service` and `lakehouse-network.service`.
- **Location, verified.** The user generator reads `/usr/share/containers/systemd/users/` (checked by running `quadlet --user --dryrun` as an unprivileged user on
  the default image with the rendered files mounted there: all units are generated). The dx smoke test repeats that dry run inside the built image.
- **Pins.** Exact patch-level tags with digests (`Image=name:tag@sha256:...`; the tag stays for humans, the digest decides), recorded 2026-11-13: postgres
  `17.12-alpine`, valkey `9.1.3-alpine`, seaweedfs `3.99`, kafka `4.3.2` (the minor the owner runs; `4.4.0` exists and arrives as a bump pull request). No
  `AutoUpdate=` on any shipped unit: a stateful service never changes image unattended. Majors are never bumped automatically (PostgreSQL 17 to 18 needs dump
  and restore or `pg_upgrade`). `tests/datastore.sh` checks that every shipped `Image=` equals the pin file, is an exact tag with a digest, and is not `latest`.
- **Weekly bump.** `bump-pins.yml` (Tuesday 07:00 UTC) now also checks `postgresql`, `valkey`, `seaweedfs` and `kafka` through `.github/scripts/datastore-pin-bump.sh`:
  the newest tag of the same shape and suffix inside the pinned major, with its manifest digest (`skopeo inspect --raw | sha256sum`); release candidates and other
  suffixes never match; a NEWER MAJOR is only named in the pull request body ("newer major available, manual decision") and never changes the pin; one pull request
  per image on `bump/<image>-digest` into `testing`, with the same default-token-plus-dispatch design as the other bump workflows. These are public registry
  images: the digest comes from the registry, nothing of ours signs it. Tests: `tests/datastore-bump.sh`.
- **User override, verified.** `~/.config/containers/systemd/<service>.container.d/10-image.conf` with `[Container]` and `Image=` replaces the shipped image: checked with
  `quadlet --user --dryrun` (the drop-in is loaded from the user directory while the unit comes from `/usr/share`, and the generated `podman run` uses the drop-in's image, the last `Image=` wins).
  `ujust datastore-setup --pin SERVICE=TAG` writes that drop-in (same major only, no digest: a tag can move; a major change is refused, do it by hand), `--unpin` removes it,
  `--status` shows shipped pin, override, running image, the PostgreSQL data major (`PG_VERSION` read with `podman unshare cat`), the storage location and the volume sizes.
- **Secrets, never in the image.** `Secret=postgresql-password`, `valkey-password` and `seaweedfs-s3-config` (a generated SeaweedFS identities JSON, admin with a random access and
  secret key). `ujust datastore-setup` creates the MISSING ones with `podman secret create NAME -` from random data through stdin (never printed, logged or passed as an argument, an
  existing secret is never overwritten); undo `podman secret rm`.
- **Data-version guard.** `ujust datastore start` refuses to start the datastore pod when the data volume's `PG_VERSION` major differs from the effective image's major, with the dump and restore
  message; the Quadlet itself stays simple. `--status` shows both majors. `ujust datastore-setup --update` prints the pins, says "back up first", pulls only after confirmation and never restarts a running service.
- **Recipes** (dx recipe file `72-octarine-datastore.just`, imported by `dx.sh`, group Setup; rootless, refuse root, no hardware-setup step): `ujust datastore start|stop [datastore|kafka|all]` (default datastore;
  checks the secrets first, runs the PostgreSQL guard, never pulls, a running pod is a no-op, unknown name exits 2), `status` (pods, containers, ports, running image against the pin), `logs SERVICE`
  (`journalctl --user`, 200 lines); `ujust datastore-setup [--yes|--no|--status|--pin|--unpin|--update|--backup DIR [--stop]]`. Helper `/usr/share/octarine-os/lib/datastore.sh`.
- **Storage and backups.** Named volumes live in Podman's graphroot, `~/.local/share/containers/storage` with no `storage.conf` (the owner's machine moves it with `containers/storage.conf`
  and the btrfs driver); `--status` shows the graphroot and warns when it is under the home; moving it is documented, not automated. `--backup DIR` exports each volume to `DIR/<volume>-<YYYYMMDD-HHMMSS>.tar`
  (`podman volume export`; a name that exists is never reused, `-2`, `-3` ... is appended; written to `<name>.part` and renamed on success, a failure removes only its own `.part`, never an earlier backup), PostgreSQL while running through an online `pg_dumpall` into `DIR/postgresql-<stamp>.sql`; a running pod with Valkey, SeaweedFS or Kafka volumes is refused unless `--stop`
  (stops the pod, exports, starts it again; a trap starts again exactly the pods this run stopped on Ctrl-C, SIGTERM or an early failure); files are private (umask 077). Restore is manual (`podman volume import`), nothing runs on a timer. These volumes are NOT covered by snapper or borg.
- **Smoke test** (`dx-smoke.sh`): the eleven Quadlet files exist, no `[Install]`, every image an exact tag with a digest, no latest, `AutoUpdate=`, home path or local image, loopback ports only, the recipe file and helper
  ship, and the generator dry run produces the pod and container units. Tests: `tests/datastore.sh`, `tests/datastore-bump.sh`, `tests/dx-image.sh`.
- **Unverified (real machine).** The first `systemctl --user start datastore-pod` (image pulls, healthchecks), the secret mounts, SELinux labels on the volumes, the owner's graphroot, a Kafka start with the pinned 4.3.2, and that the removal of the owner's own Quadlet copies leaves the same behavior (container names are kept: `pgsql` and the pod aliases).

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

`ujust wake-on-lan [--yes|--no|--status|--off] [--nic IFACE]` (default image too, `60-custom.just` above `toolbox`) and the hardware-setup step `wake-on-lan` (which only delegates to it, shown only when the wired NIC reports `Supports Wake-on` with `g` in `ethtool`, or when `ethtool` cannot be read as the user and the sysfs `power/wakeup` file exists): the NIC is the default-route device, or the bridge's physical port when that device is a bridge, and the setting goes on the profile that is ACTIVE on the physical device (the port profile `br0-<nic>`, not the bridge profile); `sudo nmcli connection modify "<profile>" 802-3-ethernet.wake-on-lan magic` then `sudo nmcli device reapply <nic>` (`--off` sets `ignore`); idempotent; prints the MAC, the BIOS or UEFI reminder (Wake on LAN or Power On By PCI-E, ErP or EuP off) and that only the OS side is configured and the wake test is the user's (`wakeonlan <MAC>` or `etherwake`). The `nmcli` property value table is from blog sources and unverified; some drivers may reset the setting at shutdown (not verified).

Tests: `tests/virthost-setup.sh` (every step fresh, done and failing; Intel and AMD; NIC detection; nox bridge layout; SSH, Wi-Fi and root refusals; ACL, SELinux and pool; virtio download, existing, forced, offline; `nwbridge`; Wake-on-LAN with and without a bridge), `tests/hardware-setup.sh`, `tests/dev-setup.sh`. Only a real machine can verify: the bridge takeover, qemu with a custom directory and its label, WoL waking the machine, the group re-login, and the virtio download from a network that blocks scripts.

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
- `tests/plan-build.sh` tests the docs-only plan script with fixed inputs; run it after changing
  `.github/scripts/plan-build.sh`.
- `tests/binaries-build.sh`, `tests/binary-images.sh`, `tests/upstream-check.sh` and `tests/bump-pins.sh` test the prebuilt binaries and their workflows (see "Prebuilt binaries"); `tests/schedulers.sh`, `tests/scheduler-recipe.sh` and `tests/scx-kernel-check.sh` test the scheduler runtime, the recipe and the kernel check (see "sched_ext schedulers").
- `tests/beta-channel.sh` tests the beta workflow (schedule, base env, permissions, pins, tags, signing) and the beta prune rule.
- `tests/nvidia-variant.sh` tests the variant workflow triggers, the policy of both repositories, the kernel-matched akmods tag, the smoke checks and the released-tag prune mode.
- `tests/inputs-hash.sh` tests the two input hashes, the dx-only path list, `plan-vanilla-reuse.sh` (testing) and the promote of a dx-only tip; `tests/plan-dx.sh` the dx plan decision table (stub skopeo and cosign; the testing base `testing-<sha7>`, walk-back, fallback and the promotion sequence) and `aggregate-dx.sh`; `tests/push-tags.sh` one push plus digest copies.
- `tests/nvidia-dx-image.sh` tests the NVIDIA dx workflow (triggers, guards, no required-check context, the shared dx layer, both smoke tests, tags, signing), the `DX_IMAGE_ID` part of `dx.sh`, the CDI part of `nvidia.sh` and the dx-only input list; the plan decision for it is in `tests/plan-dx.sh`.
- `tests/dx-image.sh` tests the dx workflow (triggers, guards, channel mapping, permissions, pins, tags, signing, the promote job, the result job), the Containerfile and package lists, the policy of all three repositories, the dx smoke script with stub tools, the dx prune rule and `just dev-packages-bump`.
- `tests/image-version.sh` tests the version string, the neutral-version check (labels and os-release `IMAGE_VERSION`, beta rule) and `set_os_release_field` of the three scripts; `tests/fastfetch-default.sh` the default fastfetch configuration.
- `tests/build-triggers.sh` tests the build triggers: no `pull_request` in `build.yml`, a dispatch from another ref never logs in, pushes or signs, the aggregate job name, other workflows unchanged.
- `tests/dev-setup.sh` tests `ujust dev` (dx only), the sdk wrapper, the fnm and cargo shell snippets and the dx-only wiring (see "Developer menu").
- `tests/niri-setup.sh` tests `ujust niri-setup` and the shipped niri files (see "niri setup"); `tests/niri-keybinds.sh` the experimental keybind wizard (see "Keybind wizard" there).
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
- `tests/just-recipes.sh` tests the image's just files assembled like the base `justfile` (parses, new recipes listed, removed
  base recipes absent, every public recipe has a description); `tests/switch-image.sh`, `tests/update-services.sh` and
  `tests/luks-tpm-unlock.sh` test the recipes of `ujust switch-image`, `toggle-updates`/`update` and `luks-tpm-unlock`
  (Esc, the single-call re-enroll, the image-off line).
- `tests/readme-defaults.sh` tests the README (section order, no removed sections, every `ujust` recipe of the recipe files listed, the
  three variant URLs, the disclaimer last) and the zsh and `iommu=pt` shipping rules (no image ships either; the iommu karg is opt-in).
- The default image carries no compilers or build tools (the dx image does); the toolbox the definition describes is
  the image `ghcr.io/redcodeworks/fedora-toolbox` built from its own repo (`TOOLBOX_IMAGE` overrides the tag). The host recipe is `ujust toolbox <name>`; to add a toolbox ship a
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
  `/etc/pki/containers`) from `IMAGE_ORG`, `IMAGE_NAME` and `cosign.pub`, keeping the catch-all last (rules for the default, `-nvidia`, `-dx` and `-nvidia-dx` repositories).
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
  aggregate means built, signed and published. `aggregate-result.sh` (tested by `tests/aggregate-result.sh`)
  accepts a skipped `sign` only when nothing was published and fails when sign was expected and did not succeed. Pruning stays safe: a version
  carrying `latest*` next to `testing*` tags is never a candidate (`tests/prune-testing.sh`).
- **Disk images.** `build-disk.yml` runs only on `workflow_dispatch` (Run workflow in the Actions tab, or
  `just build-iso` / `just build-qcow2` locally); no trigger, no required check depends on it. It passes
  `rootfs: btrfs` to the builder action (the failure was `no default root filesystem type specified in
  container`). Config paths are passed as `./disk_config/...` because podman reads a bare path as a volume name.

## Input hashes and dx on testing

- **Two hashes, one script.** `.github/scripts/inputs-hash.sh` (tests: `tests/inputs-hash.sh`) hashes the sorted
  `git ls-tree -r` entries (mode, blob id, path) of a commit that pass a filter, so the result does not depend on commit ids or
  dates. `dx_inputs` covers the dx-only paths (`is_dx_only`): `variants/dx/**`, `.github/workflows/build-dx.yml`,
  `.github/scripts/{dx-smoke,plan-dx,aggregate-dx}.sh`, `.github/workflows/build-nvidia-dx.yml`, `keys/redcodeworks-toolbox-cosign.pub`, `tests/{dx-image,dev-setup,plan-dx,nvidia-dx-image}.sh`.
  `vanilla_inputs` covers every other tracked file except the docs-only ones (`is_docs`, `docs-only.sh`). A new dx-only file must be
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
- **dx on testing (`build-dx.yml`).** Since 2026-11-13 dx is built INSIDE the pipelines by a reusable workflow (next bullet); the plan, tags and channels below are unchanged. Channels: `testing` (after a testing build; base
  `octarine-os:testing-<sha7>` of the triggering commit, see below; tags `testing` and `testing-<sha7>`; no `-<date>-` tag), `latest` (after a main build), `beta`
  (main only, the beta pipeline or a dispatch). Every checkout is the caller's commit (`github.sha`: the pushed commit, or main's tip).
  `.github/scripts/plan-dx.sh` (tests: `tests/plan-dx.sh`) decides per channel from the published `octarine-os-dx:<channel>` labels
  `org.opencontainers.image.base.digest` and `io.github.redcodeworks.octarine-os.dx-inputs` (new; `dx-tree` is still written but no longer compared):
  skip only when BOTH equal the current base digest (raw manifest digest of the verified base, see "Base of the testing channel" below) and `dx_inputs` of the
  commit; on `latest` otherwise look for a promotable testing image (candidates `testing`, then `testing-<sha7>` of the newest 60 commits of
  HEAD; both labels must equal the current ones and the signature must verify) and retag it (job `promote`: `skopeo copy --all --preserve-digests`
  to `latest` and `latest-<date>-<sha7>`, digest compared before and after; the `sign` job verifies, it does not sign again);
  else build. After a vanilla promote the base digest of `latest` equals the tested digest, which is what makes the labels match.
  Force always builds. Decision table (build / promote / skip), testing: nothing published or any label differs or force = build, both equal = skip
  (the base digest is that of `octarine-os:testing-<sha7>`, walk-back or fallback below);
  latest: both equal = skip, a matching tested testing image = promote (its base digest equals `octarine-os:latest`, which after the default promote
  is the digest of the tested `testing-<sha7>`), else build; beta: both equal = skip, else build.
  Change combinations on `testing`: dx-only = vanilla `reuse` (no vanilla build), dx builds; vanilla-only = vanilla builds, the new base digest
  makes dx build; both = both; nothing/docs-only = vanilla skips, dx skips (labels equal); first run = both build.
- **Base of the testing channel.** `plan-dx.sh` for `testing` does not read the floating `octarine-os:testing` tag: it resolves
  `octarine-os:testing-<short sha7 of HEAD>` (HEAD = the commit being built, whose default build just finished in the same run), verifies
  its signature and records that digest as `base.digest`. If the tag does not exist (the default build was reused for a dx-only or docs-only
  change) it walks back with `nearest_image_for_inputs` (the `plan-vanilla-reuse.sh` logic: first-parent history, stops at a commit whose
  `vanilla_inputs` differ) to the nearest earlier `testing-<sha>`; if there is none either it falls back to the floating `testing` tag with
  a `::warning::` (the old behavior). `base_tag` in the plan output is the tag actually used (`testing-<sha7>`), and the dx image's `base.name`
  label records it. `latest` still resolves `octarine-os:latest`, `beta` `octarine-os:beta`.
- **One manifest digest per build (`push-tags.sh`).** Why the dx image never promoted (found 2026-11-10): every image workflow pushed each
  tag with its own `podman push` of the same local image, and the pushes did not produce one manifest: `octarine-os:testing` and
  `testing-cc213cb` of one build had different digests. The default promote copies `testing-<sha7>`, so `latest` had that digest, while the
  dx testing image had recorded the floating `testing` digest as its base; the `latest` plan then never found a matching tested image and built
  (about 21 minutes per promotion). The fix: `.github/scripts/push-tags.sh <local image> <registry image> <tag>...` pushes the first tag once
  (`podman push --digestfile`), makes every other tag a registry-side `skopeo copy --all --preserve-digests` of that digest, and reads each
  tag's digest back from the registry (a mismatch fails the step); it writes the single `digests=` output the sign job signs. `build.yml`,
  `build-beta.yml`, `build-dx.yml` and `build-nvidia.yml` all use it; a workflow must not `podman push` twice (tested in `tests/push-tags.sh`,
  with the stub podman/skopeo registry, plus the `dx-image` and `beta-channel` workflow checks). Images published before the fix still have
  two digests; the first promotion after it builds dx once because no tested dx image on a matching base exists yet.
- **dx image: a reusable workflow (2026-11-13; replaces the `workflow_run` chain).** `build-dx.yml` is `workflow_call` (inputs `channel`, `force`; outputs
  the plan decision and the results of its jobs) plus a `workflow_dispatch` kept for a manual rebuild on `main`. Why: `workflow_run` always runs the
  workflow file of `main`, so a change to the dx workflow could not be tried on `testing` (the recurring "first real run follows the first
  promotion"), the result had to be posted as a COMMIT STATUS on the tested commit (a `workflow_run` check run attaches to main's tip), the testing
  base was looked up a second time and two workflows had separate concurrency. Now `build.yml` has the job `dx` (`uses: ./.github/workflows/build-dx.yml`,
  channel `testing` on `testing`, `latest` on `main`, `secrets: inherit`, `needs: build_result`, `if` the base aggregate succeeded and the ref is `main` or
  `testing`; never a pull request: the workflow has no such trigger) and `build-beta.yml` has `dx` (channel `beta`, `needs: sign`, ref `main`). ONE-WAY: dx
  needs the base, nothing of the base needs dx, so a failed dx build never turns `Build and push image` or `Sign and verify images` red or blocks their
  signing; the run's overall conclusion is then red (the dx jobs failed) while the base checks stay green. The plan, tags, signing and result logic are the
  same scripts (`plan-dx.sh`, `aggregate-dx.sh`, `push-tags.sh`, `dx-smoke.sh`); the plan still resolves the base itself (`octarine-os:testing-<sha7>`, an
  immutable tag already published and signed by the time dx runs), so the base digest is not passed as an input (deviation from the first sketch: a pass-through
  would have to cover the reused-default-build and promote cases). `build-nvidia-dx.yml` stays a separate workflow: it follows the NVIDIA variant's own weekly
  chain on `main` (a `workflow_run` of "Build NVIDIA variant"), has no testing channel and no promote, and uses another smoke script; it is the only
  `workflow_run` left (a test pins that).
- **The required check `Build dx and push image` (since 2026-11-13).** It is the job `dx_result` OF `build.yml` (a job of a called workflow is reported as
  `<caller job> / <job>`, so the exact name must come from the caller), `if: always()` on `main` and `testing`, `needs: [build_result, dx]`; it feeds
  `aggregate-dx.sh` with the call's outputs (`collect` job: plan, build, promote, sign results and the plan's `build`/`promote` decision) and the base aggregate's
  result in `BASE`: green when dx was built and signed, promoted and verified, or legitimately skipped (base and dx inputs unchanged); RED when the base build
  failed (nothing was built on it; the base's own checks are red too), when the dx workflow reported nothing, or when a dx job failed or was cancelled.
  It is a normal check run on the pushed commit, so the commit-status POST (`statuses: write`) is gone. Main's ruleset lists the context without an
  integration id, so a check run of the Actions app satisfies it; no ruleset change was needed. Two contexts of one name with different results would block a
  promotion: during the transition the old `main` version of `build-dx.yml` may still post the commit status once (below), always with the same outcome in practice.
- **Transition (design).** Until the first promotion, `main` still has the OLD `build-dx.yml` (a `workflow_run` of "Build container image"), which starts after every
  testing run that SUCCEEDED and builds dx again for the same commit. Why that is safe: (1) the new in-pipeline dx finishes before the run completes, so the old one
  starts later; (2) the old one's plan (this commit's `plan-dx.sh`) sees the dx image of the same base digest and dx inputs, signed, and SKIPS (no second build, no tag
  push, no `Build dx` job beyond the plan); (3) both use the concurrency group `build-dx-<channel>` (`cancel-in-progress: false`), so they never run at once; (4)
  if the in-pipeline dx failed the run is red, so the old workflow's `conclusion == 'success'` gate keeps it from posting anything. Residual risks: a PENDING
  group slot is replaced by a newer pending run (the old chain of an earlier commit and the new call of a later one can collide: the cancelled call shows red,
  re-run it); the old workflow posts one more commit status of the same name with success; nothing else. The promotion that brings this file to `main`
  removes the `workflow_run` trigger in the same merge, so there is no overlap after it. Hardening added for this: `plan-dx.sh` skips only when the published
  image's digest also verifies with `cosign.pub` (a `testing` run that `build.yml` cancels between push and sign would otherwise leave an unsigned image with
  equal labels that a skip never repairs).
- **Prune.** `prune-testing.yml` now runs the generic testing pass on the `-dx` package too (same keep count as the default package; `testing-*` only versions,
  promoted versions carrying `latest*` are never candidates) next to the dx per-channel pass.
- **NVIDIA dx.** `build-nvidia-dx.yml` reuses `plan-dx.sh` (`BASE_NAME`, `DX_NAME`, `PROMOTE_FROM_TESTING=false`) and builds the same `variants/dx` layer on `octarine-os-nvidia`; see "NVIDIA dx image and the CUDA toolbox".
- **First runs.** Since the reusable workflow is called from `build.yml`, its first real run is the `testing` build after the merge of the change (no more
  wait for a promotion). Verified here: static tests (`tests/dx-image.sh`, `tests/build-triggers.sh`, `tests/plan-dx.sh`), YAML parses, `bash -n`. Only the first
  `testing` build shows: that the called workflow's `concurrency` and `environment: signing` work as called jobs, that `secrets: inherit` reaches `SIGNING_SECRET`,
  the check name `Build dx and push image` on the pushed commit, the outputs of `collect` reaching `dx_result`, and the old `workflow_run` run skipping.

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
- **Kernel argument:** none in any image. `iommu=pt` used to ship in the dx image (`kargs.d/10-iommu.toml`); since 2026-11-13 it is opt-in, through `ujust virthost-setup` (it matters only for machines that pass devices through to VMs). A machine that had it from an older dx image loses it on the first image that drops the file until the step is run (`sudo rpm-ostree kargs --append-if-missing=iommu=pt`, reboot; undo `--delete-if-present=iommu=pt`). `tests/readme-defaults.sh` and `dx-smoke.sh` assert that no tree ships a `kargs.d` file with iommu, and the smoke tests of `build.yml` and `build-beta.yml` assert the file is absent.
- **Size and compilers:** the default image carries no compilers (the base never had them); the dx image provides them, and `ujust toolbox` can still create a toolbox. ROCm was removed from the image (2026-11-08): GPU compute tooling lives in a rootless distrobox, created by the `rocm` step of `ujust hardware-setup` (the dx images exclude it from the shared list too, see below).
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
  `build.yml`, `build-beta.yml` and `dx-smoke.sh` assert `SHELL=/usr/bin/zsh` is absent). Choosing it is opt-in through the `shell`
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
  | | `color-scheme`, `gtk-theme`, `icon-theme`, `monospace-font-name` | excluded | visual theme and font taste, themes come from gnome-themes |
  | | `font-antialiasing='rgba'`, `font-hinting='full'` | excluded | depend on the display, differ from the GNOME default |
  | | `enable-animations`, `text-scaling-factor`, `toolkit-accessibility` | excluded | equal to the GNOME default, no effect |
  | `30-enable-extensions.sh` | AppIndicator, GSConnect | included | shipped RPMs, GSConnect has a firewall service in the image |
  | | caffeine, dash-to-dock, auto-move-windows, user-theme | excluded | shipped but change the look or need personal data (Auto Move needs an app list, the dock is visual, caffeine adds a panel icon, user-theme is useless without a theme) |
  blur-my-shell is no longer shipped at all (removed 2026-11-13; the owner installs the upstream release as a user extension, which shadows a system copy and which Extension Manager refuses to install over). On an existing machine the system copy disappears with the image update; a user copy and the dconf settings under `/org/gnome/shell/extensions/blur-my-shell/` stay untouched, and if it was enabled from the system copy with no user copy GNOME just lists it as missing. Nothing else in the image referenced the package (no dconf default, schema override, extension-enable list, preset or test).
  | | GPaste (`gpaste`, `gnome-shell-extension-gpaste`, extension `GPaste@gnome-shell-extensions.gnome.org`) | shipped, not enabled | optional `misc` group; the daemon is D-Bus activated (no unit to enable); switch on with `gnome-extensions enable GPaste@gnome-shell-extensions.gnome.org`; default shortcuts Ctrl+Alt+H (history) and Ctrl+Alt+G (UI) |
  | | Just Perfection, ddterm, Freon (`gnome-shell-extension-just-perfection`, `-ddterm`, `-freon`; UUIDs `just-perfection-desktop@just-perfection`, `ddterm@amezin.github.com`, `freon@UshakovVasilii_Github.yahoo.com`) | shipped, not enabled | optional `misc` group, switch on with `gnome-extensions enable <uuid>`; ddterm toggles on F12 by default; Freon reads lm_sensors (in the same group; may need `sensors-detect` for extra sensors) |
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
  | | `desiredgov=powersave`, `[custom]` tuned profile | excluded from `/etc` | AMD amd-pstate specific and needs tuned; stays in the `gaming-setup` user file |

- **User-facing notes (formerly in the README's "Defaults" section).** GNOME: hot corners off, AppIndicator and GSConnect on;
  `gsettings reset <schema> <key>` returns a key to the image default. fish: a user file of the same name disables a snippet (see
  Paths). GameMode needs the user in the `gamemode` group (`ujust user-setup` adds it). The files are `/etc/dconf/db/distro.d`,
  `/etc/gamemode.ini` and `/usr/share/fish`.
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
- **Recipe.** Group Setup; steps `niri`, `portals`, `polkit` and the experimental `keybinds` (own bullet below); `--yes`, `--no` (plan only), `--only STEP[,STEP]`, `help`; the shared
  checklist helper (a step chosen in it is not asked "Apply?" again); each file is idempotent (identical = "already done"), a different
  existing file shows a diff, the replace question defaults to keep (also under `--yes` and with no answer to read) and a yes saves
  `<file>.bak-YYYYMMDD-HHMMSS` first; the `polkit` step skips without `noctalia` on PATH; a failed step is FAILED with its re-run command, exit 1;
  option errors exit 2; no sudo. Test hook: `OCTARINE_NIRI_SETUP_SRC` (a tree with `niri/*.kdl`, `niri-portals.conf`, `10-octarine-os.toml`).
  Test: `tests/niri-setup.sh` (fake gum, ugum, noctalia, sudo, temp HOME; `niri validate` of every include combination when niri exists; a guard
  that `ghostty` and `ptyxis` appear in no shipped niri file). The smoke checks in `build.yml` and `build-beta.yml` look for the files.
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

- User-facing note (formerly in the README): try it with `sudo bootc switch --enforce-container-sigpolicy ghcr.io/redcodeworks/octarine-os:beta`
  and go back with the same command and `:latest`. Until Universal Blue starts a new beta it is the same Fedora release as `latest`.

- `.github/workflows/build-beta.yml`: weekly (Wednesday 14:00 UTC, clear of the daily 11:00, Sunday 05:00 prune and Sunday 12:00
  NVIDIA runs) and on dispatch from any ref, never on pushes or pull requests, not a required check. It builds the normal
  image FROM `ghcr.io/ublue-os/silverblue-main:beta` (workflow env `BASE_IMAGE`, `FEDORA_VERSION=beta`; the repository variables
  are ignored), smoke tests (a copy of build.yml's block, `tests/beta-channel.sh` fails on drift), rechunks, pushes `beta` and
  `beta-<date>-<sha>` only, signs with the same key (`signing` environment) and verifies both tags. Failure = a red scheduled run, no
  notification. The `beta` tag only exists upstream while ublue-os/main builds a beta (their `BUILD_BETA` variable); until then it
  equals stable. Policy: the existing rule for the `octarine-os` path covers every tag. Prune: `PRUNE_KIND=beta KEEP=3` in
  `prune-testing.yml` keeps the newest three `beta-*` builds and any version holding `beta`. Test: `tests/beta-channel.sh`.

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
- **Hiding** a base recipe: redefine it `[private]` (hidden from `ujust --list`, still runnable) in a file that wins:
  `setup-distrobox-app` (its only entry is an NVIDIA PyTorch container) in `30-distrobox.just`, (`configure-broadcom-wl` is removed outright, see above). `enroll-secure-boot-key` stays visible: the NVIDIA variant needs it.
  `install-resolve` stays: it asks for no host `sudo` (the only `sudo` in the pinned davincibox script runs inside the
  rootless container).
- `tests/readme-defaults.sh` scans `60-custom.just` and `10-update.just` for public recipes (each must be in the README).
  `tests/toolbox.sh` requires that no executable `sudo` appears after the `toolbox` recipe in `60-custom.just`, so new
  recipes go BEFORE the `[group('Toolbox')]` line.

## `ujust toggle-updates` and `ujust update`

- Both live in `10-update.just` and share `system_files/usr/share/octarine-os/lib/update-services.sh`, the one table of
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
  for `uupd` (not installed here); both are replaced. Tests: `tests/update-services.sh`.

## Hardware targeting (what is set only where the hardware is)

- `system_files/etc/profile.d/proton.sh` exports `PROTON_FSR4_UPGRADE=1` only when a DRM card has vendor `0x1002` (AMD), by a bash
  glob loop with no subprocess (it runs at every login shell; `OCTARINE_SYSFS_DRM` redirects sysfs in tests). `PROTON_ENABLE_WAYLAND=1`
  stays for everyone but is experimental and reported rough on NVIDIA. fish has no equivalent file (fish does not read `profile.d`).
- GameMode's `desiredgov=powersave` (upstream gamemode#419 workaround) is right only with amd-pstate in active mode: `gaming-setup gamemode`
  pre-ticks the step and writes the line only when `/sys/devices/system/cpu/amd_pstate/status` is `active` (`GAMING_SETUP_PSTATE_STATUS`
  in tests); otherwise the line and its comment are left out and the tuned `[custom]` part stays.
- `switch-image nvidia|nvidia-dx` without an NVIDIA GPU (`0x10de`): says so and asks (default No); `--yes` alone refuses, `--force` proceeds.
- `luks-tpm-unlock` exits 0 with a message when `/dev/tpmrm0` is missing (`OCTARINE_TPM_DEVICE` in tests).
- Tests: `tests/hardware-targeting.sh` and the cases added to `gaming-setup.sh`, `switch-image.sh`, `luks-tpm-unlock.sh`.
  Only real hardware shows: Wayland and FSR4 behavior in games, amd-pstate states, the mcelog unit on Intel, the retry after a wake.

## ROCm is opt-in (not in the dx images)

- The shared `dev-packages` list (fedora-toolbox repo, pinned by digest) still carries `rocminfo rocm-smi rocm-hip rocm-opencl hipcc` because
  it also builds the owner's `fedora-toolbox` container. `variants/dx/dx.sh` runs the installer with
  `EXCLUDE="rocminfo rocm-smi rocm-hip rocm-opencl hipcc"` (EXCLUDE takes exact package names, space separated; an excluded entry is not looked up;
  present in the pinned installer, `dev-packages/install.sh`), and fails the build if any of the five is installed afterwards. `dx-smoke.sh`
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
  wrapper reports "already exported". Tests: `tests/dev-setup.sh` and `tests/hardware-setup.sh` (stub `distrobox`).

## `ujust hardware-setup`

Plan modes are pure (`--list`, `--no`, for `ujust dev` `--no`): no distrobox is entered or started, because `distrobox enter` starts a stopped container. The `rocm` probe in hardware-setup and the existing-box check of the dev `cuda` step say "not checked in plan mode" instead; a real run probes as before. Tests: `tests/hardware-setup.sh`, `tests/dev-setup.sh` (no `distrobox enter` or `podman start` in the log).

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
  and `run_of`, then cases in `tests/hardware-setup.sh`. Skipped for now: firmware and laptop power. Unverified without hardware:
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
  Tests: `tests/luks-tpm-unlock.sh` (fake `lsblk`, `cryptsetup`, `systemd-cryptenroll`, `sudo`).

## `ujust switch-image`

- One recipe in `60-custom.just` switches between the images (`default` = `octarine-os`, `dx` = `octarine-os-dx`, `nvidia` =
  `octarine-os-nvidia`, `nvidia-dx` = `octarine-os-nvidia-dx`) and the channels `latest`, `beta`, `testing`. It replaces the
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
  `--list` probes all twelve combinations in parallel; `--yes` skips the question, `--no` prints the plan.
- Which combinations exist is not hard-coded: `nvidia` and `nvidia-dx` have only `latest` (no `beta` or `testing` tag). `octarine-os-nvidia-dx` is
  built by `build-nvidia-dx.yml` (see "NVIDIA dx image"); its repository is in the signature policy that `build_files/build.sh` generates
  (`tests/nvidia-variant.sh` and `tests/dx-image.sh` check the policy for each repository), so the recipe needed no change except a hint
  printed for `nvidia-dx` (a machine whose image predates the rule gets a signature-policy error from bootc).
- Staged images: the recipe also reads the STAGED deployment (`rpm-ostree status --json`, `staged: true`; test hook `OCTARINE_SWITCH_STAGED_REF`). When it equals the target (digest ignored) it says "already staged: reboot to use it" and calls nothing (no second `bootc switch`, no second security-key touch); a different staged image is named and replaced. The hardware-setup `nvidia` step goes through this recipe, so its probe (`/sys/module/nvidia`, false until the reboot) cannot cause a second switch.
- Tests: `tests/switch-image.sh` (fake `skopeo`, `sudo`, `bootc`; the running image from `OCTARINE_SWITCH_CURRENT_REF`).

## NVIDIA variant (`octarine-os-nvidia`)

- User-facing note (formerly in the README): run the default install steps first, then `bootc switch --enforce-container-sigpolicy
  ghcr.io/redcodeworks/octarine-os-nvidia:latest` and reboot; with Secure Boot on, `ujust enroll-secure-boot-key` (from the base).

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
  `dev-toolbox` (so the host has compilers, `-devel` libraries, debuggers, `uv`, `rustup`, `fish`; no ROCm, see below), VM tooling,
  tracing tools and a few extras; the VS Code Flatpak is not preinstalled (`ujust dev` installs it on request; Kevin 2026-11-10). Opt-in, for the owner's own
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
  `.github/workflows/build-dx.yml` (the dx-only `dx.preinstall` was removed 2026-11-10 and `variants/dx/system_files/usr/share/flatpak`
  with it; a dx-only Flatpak drop-in would need no recipe change, `ujust flatpak-preinstall` reads every `*.preinstall` there),
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
- **Workflow rules (`build-dx.yml`).** Since 2026-11-10 dx also builds on `testing` and promotes on `main`; the flow, the plan decision table, the
  input hashes and the result check are in "Input hashes and dx on testing" above, and the plan logic is `.github/scripts/plan-dx.sh`. The text below
  describes the earlier main-only version where it still applies (the build steps, labels, sign job, concurrency). Triggers: since 2026-11-13 `workflow_call` (from `build.yml` and `build-beta.yml`) and `workflow_dispatch` (inputs `channel`, `force`), no `workflow_run`; see "dx image: a reusable workflow". The
  plan job runs only for a push, schedule or dispatch of `testing` (channel `testing`) or `main` (`latest`, `beta`); never a pull request. Channel: the input. Plan: resolves
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
  no VS Code or virt-manager Flatpak in any preinstall list, exactly one kernel equal to `BASE_KERNEL`, and the default image's checks that still apply
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
- **User-facing note (formerly in the README).** Switch with `bootc switch --enforce-container-sigpolicy ghcr.io/redcodeworks/octarine-os-dx:latest`
  after updating to the newest default image (it carries the signature policy); undo by switching back to `octarine-os:latest`. `beta` follows
  `octarine-os:beta`. The README table and the `ujust dev` text say what `dev` sets up; the step table lived in the README and is now in
  "Developer menu" below.
- **VS Code.** `com.visualstudio.code` is the community-maintained Flathub build; Flathub's API reports it as not verified
  (Microsoft is only listed as developer). The owner chose it knowingly; it is installed only by the `vscode` step of `ujust dev` (which says so), never preinstalled.
- **Kernel argument.** None since 2026-11-13: the dx image no longer ships `10-iommu.toml`; `iommu=pt` is opt-in (see "Kernel argument" under the default image notes).
- **Stage 3 (done, `feat/vm-host-to-dx`).** The VM-hosting set moved out of the default image and lives only in dx and nvidia-dx
  (`variants/dx/packages/extras.txt`: `libvirt` and `qemu-kvm` meta packages, `cockpit-machines`, `virt-install`, `virtiofsd`, `swtpm`,
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
  `build.yml` and `build-beta.yml` assert `libvirt`, `qemu-kvm`, `cockpit-machines`, `virt-manager`, `virt-viewer` and `libvirt-nss`
  are absent (and `guestfs-tools` present); `nvidia-smoke.sh present` asserts the same for the plain NVIDIA image (skipped for an
  `-dx` image id); `dx-smoke.sh` asserts the full set, the `libvirtd`, `virtqemud`, `virtnetworkd` and `virtstoraged` units and
  `libvirt-nss`. `user-setup` names only the groups that exist in its menu (`getent group`). The root `Justfile` recipe `test-vm`
  needs libvirt on the host, so it runs on a dx machine. Switching a machine from dx to the default image removes VM hosting
  (`ujust dev --only libvirt` and `ujust virthost-setup` are dx-only; the hardware-setup `virtualization` step was removed; the user's `libvirt` group membership stays
  in `/etc/group` and is harmless). UNVERIFIED: the package set after a real build (the list above is from a local image dated
  2026-11-10, CI is the first full run), and that a machine switching from dx to default loses nothing else.
- **Unverified until the first `testing` build.** The real build, the base digest compare and the sign step run in the first `testing` build after the merge (for the
  testing trigger and the promote path see "Input hashes and dx on testing"). The `FROM` expansion `${BASE_DIGEST:+@}${BASE_DIGEST}` was checked with a local podman, not on the runner.

## NVIDIA dx image (`octarine-os-nvidia-dx`) and the CUDA toolbox

- **What it is.** `ghcr.io/redcodeworks/octarine-os-nvidia-dx`: the SAME dx layer (`variants/dx`, one `Containerfile`, one package
  list, no ROCm, no CUDA toolkit) on top of `octarine-os-nvidia` instead of `octarine-os`. Kevin's decision (2026-11-10): the DX
  build is identical for both variants, and NVIDIA's toolkit is a user-side install. No fork of the package list: the workflow passes
  `BASE_IMAGE=ghcr.io/<owner>/octarine-os-nvidia` and `DX_IMAGE_ID=octarine-os-nvidia-dx` (a build argument of the final stage of
  `variants/dx/Containerfile`, default `octarine-os-dx`; `dx.sh` sets `IMAGE_ID` from it and refuses any other value).
- **Own workflow, `build-nvidia-dx.yml` (name "Build NVIDIA dx image").** Not a caller of the reusable `build-dx.yml`: it follows the NVIDIA variant's own weekly chain on `main`, has no testing channel or promote and another smoke script. The REQUIRED
  check `Build dx and push image` is the `dx_result` job of `build.yml`. This
  workflow never reports that context: its result job is named `NVIDIA dx build result`, there is no `statuses` permission and no status
  call, so it can neither satisfy nor block a promotion pull request. Trigger: `workflow_run` of "Build NVIDIA variant" (`main`
  only; that workflow itself runs only on the Sunday schedule and by dispatch) and `workflow_dispatch` with `force`; never a push, pull
  request or `testing`. Jobs: `plan` -> `build` -> `sign` (environment `signing`) -> `nvidia_dx_result` (`aggregate-dx.sh` with promote skipped).
  Keep its build and sign steps in line with `build-dx.yml` (a test compares the shared steps).
- **Plan.** `plan-dx.sh` with `CHANNEL=latest BASE_NAME=octarine-os-nvidia DX_NAME=octarine-os-nvidia-dx PROMOTE_FROM_TESTING=false`
  (the new switch skips the search for a tested testing image: there is no testing channel). Skip when the published
  `octarine-os-nvidia-dx:latest` has the same base digest (raw manifest of the verified `octarine-os-nvidia:latest`) and the same `dx_inputs`
  as this commit; otherwise build. `is_dx_only` lists the new workflow and `tests/nvidia-dx-image.sh`, so a change to them changes
  `dx_inputs` (dx rebuilds too) and never rebuilds the default image.
- **Tags.** `latest`, `latest-<sha>`, `latest-<date>-<sha>`, `<date>-<sha>`, `<date>`, `latest-<date>` (the NVIDIA variant's set), one push through
  `push-tags.sh`, signed like the others (`cosign.pub`). No `testing`, no `beta`.
- **Smoke tests on the built image.** `dx-smoke.sh` with `EXPECT_IMAGE_ID=octarine-os-nvidia-dx`, then `nvidia-smoke.sh present` with the same
  `EXPECT_IMAGE_ID` (driver package, kernel module, one kernel equal to the base's, initramfs, kargs, SELinux module) and the new checks (also run by
  the NVIDIA variant's own build): no `cuda-toolkit*`/`cuda-nvcc*`/`cuda-compiler*`/`nvidia-cuda-toolkit` package, no `/usr/local/cuda*`, no `nvcc`
  on PATH; the CDI pieces (`nvidia-container-toolkit`, `-base`, `nvidia-ctk`) are reported as INFO only.
- **Signature policy.** `build.sh` now writes the rule for FOUR repositories (`octarine-os`, `-nvidia`, `-dx`, `-nvidia-dx`; the base name is derived by stripping
  `-dx` first, then `-nvidia`) into the default image, so the dx and NVIDIA images (built on it) inherit it; the smoke tests of `build.yml`, `build-beta.yml`
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
  `tests/gaming-setup.sh` asserts the generated text and its unescaped form. UNVERIFIED: `$LIB` expansion inside Steam's
  Flatpak (the sandbox's loader and library layout), and a real Steam run with either client; gamescope launcher: `flatpak run
  --command=gamescope ... -f -W -H -r --adaptive-sync -- steam -gamepadui`, the `steam -gamepadui` part is an
  unverified choice; resolution from Mutter DisplayConfig, else `niri msg --json outputs` with jq, else `GAMING_SETUP_RES`
  or a prompt; never silent), `gamemode` and `reset` (also removes the old global extest override entries and, when asked, both libraries). Tests:
  `tests/gaming-setup.sh`. Extest is by Supreeeme and contributors, MIT license; credited in the README; the image ships
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
