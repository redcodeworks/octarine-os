# CI workflows (`.github/`)

Everything that builds, tests, signs and publishes the images runs from here.

- `workflows/` has the GitHub Actions workflows. `test.yml` runs the fast sanity check and the behavior tests on every branch; `build.yml` builds the default
  image on `testing` and `main` and every day; `build-dx.yml`, `build-nvidia.yml` and `build-nvidia-dx.yml`
  build the variants; `binaries.yml` builds the prebuilt programs on `testing` (a push that changes `binaries/`) and, on `main`, retags the tested build to `latest`; the image build installs from that `latest`; nothing rebuilds them on a timer, by hand: `gh workflow run binaries.yml --ref testing`; `publish-latest.yml` moves the
  `latest` tag; `bump-pins.yml` opens ONE weekly pull request that moves the pinned versions (one commit per pin that moved, so a pin you do not want is dropped with `git revert <its commit>`; a newer weekly pull request closes an unmerged older one; rerun by hand with `gh workflow run bump-pins.yml --ref testing`, add `-f dry_run=true` to only print what it would open); the rest are maintenance (old daily image cleanup, a rollback, a workflow security audit).
- `scripts/` has the shell and Python helpers the workflows call (planning which builds are needed, registry and signature
  checks, smoke tests, pin bumps). `actions/` has one small shared step (tool install).
- `dependabot.yml` and `zizmor.yml` configure dependency updates and the workflow audit.

How a change flows: work on a feature branch, where `test.yml` runs a fast sanity check (the required `test`, only the obvious: shell syntax and workflow files that parse) and the behavior tests (`suite`, not required, cancelable); open a pull request into `testing`; merging
it makes `build.yml` build and publish the `testing` image. A pull request from `testing` into `main` (the only way into
`main`, enforced by `require-testing-branch.yml` and the branch rules) is checked, and merging it promotes the tested
build instead of building again; the `latest` tag then moves for the default and dx images together. Pushes that change
only documentation skip the image builds.

Before editing: workflows are audited for security problems, and the required checks (`test`, `secrets` and the build
check) must keep their names. Scripts are tested from `tests/`, so a change to one usually needs a test change too.

Images built by the scheduled daily build also carry a tag `daily-YYYYMMDD` (the default and the dx image). `prune-daily.yml` runs
weekly and keeps the newest 14 of those, deleting older daily images and their signatures; the image behind `latest`, `testing`
builds and everything else are never deleted. See what it would do with `gh workflow run prune-daily.yml -f dry_run=true`. Testing
images accumulate (public registry storage is free); delete old package versions by hand in the GitHub packages UI if ever needed.

## What the build depends on, and how each part is held

The rule: what the project owns floats at its promoted `latest`; what it does not own is pinned and moves only through a pull request (the weekly pin bump); the base image and the Fedora packages float.

| Dependency | Treatment |
|---|---|
| Base image `silverblue-main` | floats at the tag; resolved to a digest and signature-checked on every build |
| Fedora packages, negativo17 multimedia packages | float (installed from the live repositories); a COPR or vendor repository would be pinned and optional only (none today) |
| `octarine-binaries`, `dev-packages`, `datastore-images` (the owner's own images) | float at `latest`; the digest is checked and recorded in an image label. The one exception: the build on `testing` reads `octarine-binaries:testing` (and fails unless it is the build of that commit's `binaries/` tree); main, the daily build and dispatches never read `testing` |
| Homebrew files image, chunkah, the builder image, the sources of scx, extest and Ghostty, Zig | pinned, moved by the weekly bump pull request |
| GitHub Actions | pinned by commit, moved by Dependabot pull requests |
| CI tool versions, the runner label, the vendored public keys | changed by hand |
| NVIDIA akmods image | the tag for the base image's exact kernel, resolved on every NVIDIA build |
