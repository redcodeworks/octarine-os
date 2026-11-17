# CI workflows (`.github/`)

Everything that builds, tests, signs and publishes the images runs from here.

- `workflows/` has the GitHub Actions workflows. `test.yml` runs the fast sanity check and the behavior tests (four parallel groups, one job each) and the workflow security audit (`zizmor`, also weekly) on every branch; `build.yml` builds the default
  image on `testing` and `main` and every day; `build-dx.yml`, `build-gx.yml`, `build-nvidia.yml`, `build-nvidia-dx.yml`, `build-nvidia-gx.yml` and the experimental `build-dx-gx.yml` (dispatch only, `latest` only: the gx layer on the dx image; the dx, gx, nvidia-dx, nvidia-gx and dx-gx workflows are thin callers of the reusable `dx-image.yml` (input `variant`: dx or gx) for plan, build and promote and sign in their own `sign` job through the shared action `actions/sign-images`, because the signing environment secret did not reach a job inside a reusable workflow; `build-dx.yml` posts the required check `Build dx and push image` and `build-gx.yml` posts `Build gx and push image` (a required check once the ruleset lists it); `build.yml` dispatches dx and gx in parallel after the default build)
  build the variants; the prebuilt programs (scx, extest, Ghostty) are built by the separate octarine-bins repository, and this image installs the octarine-bins image it pins by digest (the weekly bump proposes a new digest); `publish-latest.yml` moves the
  `latest` tag; `bump-pins.yml` opens one independent pull request per pinned version that moved (one commit each, cut from `testing`, so any subset can be merged in any order and a pin you do not want is just closed; a newer bump of the same pin replaces its older pull request; rerun by hand with `gh workflow run bump-pins.yml --ref testing`, add `-f dry_run=true` to only print what it would open); the rest are maintenance (old daily image cleanup, a rollback).
- `scripts/` has the shell and Python helpers the workflows call (planning which builds are needed, registry and signature
  checks, smoke tests, pin bumps). `actions/` has two small shared steps (tool install, and signing of the variant images).
- `dependabot.yml` configures dependency updates; `zizmor.yml` holds the ignores of the workflow audit (the `zizmor` job of `test.yml`).

How a change flows: work on a feature branch, where `test.yml` runs a fast sanity check (the required `test`, only the obvious: shell syntax and workflow files that parse) and the behavior tests (`suite`, not required, cancelable); open a pull request into `testing`; merging
it makes `build.yml` build and publish the `testing` image (a newer merge cancels an older build: the per-commit tags are pushed, signed and verified first, and `testing` moves to the signed digest only after that, so a cancel leaves the previous signed image in place). A pull request from `testing` into `main` (the only way into
`main`, enforced by `require-testing-branch.yml` and the branch rules) is checked, and merging it promotes the tested
build instead of building again; each image then moves its own `latest` tag, independently of the others. Pushes that change
only documentation skip the image builds.

Before editing: workflows are audited for security problems, and the required checks (`test`, `secrets` and the build
check) must keep their names. Scripts are tested from `tests/<group>/` (`pipeline`, `supply`, `image`, `recipes`; a new test goes into one of those directories and needs no workflow change), so a change to a script usually needs a test change too.

Images built by the scheduled daily build also carry a tag `daily-YYYYMMDD` (the default, dx and gx images). `prune-daily.yml` runs
weekly and keeps the newest 14 of those, deleting older daily images and their signatures; the image behind `latest`, `testing`
builds and everything else are never deleted. See what it would do with `gh workflow run prune-daily.yml -f dry_run=true`. Testing
images accumulate (public registry storage is free); delete old package versions by hand in the GitHub packages UI if ever needed.

## What the build depends on, and how each part is held

The rule: anything that comes from another repository is pinned by digest and moves only through a bump pull request (the weekly pin bump, approved by the owner); the base image and the Fedora packages float. `datastore-images` still floats at its `latest` for now.

| Dependency | Treatment |
|---|---|
| Base image `silverblue-main` | floats at the tag; resolved to a digest and signature-checked on every build |
| Fedora packages, negativo17 multimedia packages | float (installed from the live repositories); a COPR or vendor repository would be pinned and optional only (none today) |
| `octarine-bins-dx` (the dx binaries image of the owner's octarine-bins repository: the developer package lists and their installer, no binary yet; the packages themselves still float) | pinned by digest in the dx `Containerfile`, verified on every dx build with the octarine-bins key, moved by the weekly bump pull request |
| `octarine-bins-gx` (the gx binaries image of the owner's octarine-bins repository: the gamer package lists and their installer, no binary yet; the packages themselves still float, except Sunshine, which the list pins to an exact version) | pinned by digest in the gx `Containerfile`, verified on every gx build with the octarine-bins key, moved by the weekly bump pull request |
| `datastore-images` (the owner's octarine-images repository) | float at `latest`; the digest is checked and recorded in an image label |
| `octarine-bins` (prebuilt scx, extest, Ghostty; the owner's octarine-bins repository) | pinned by digest in the `Containerfile`, verified on every build with its own key, moved by the weekly bump pull request |
| Homebrew files image, chunkah | pinned, moved by the weekly bump pull request |
| GitHub Actions | pinned by commit, moved by Dependabot pull requests |
| CI tool versions, the runner label, the vendored public keys | changed by hand |
| NVIDIA akmods image | the tag for the base image's exact kernel, resolved on every NVIDIA build |
