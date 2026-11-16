# CI workflows (`.github/`)

Everything that builds, tests, signs and publishes the images runs from here.

- `workflows/` has the GitHub Actions workflows. `test.yml` runs the tests on every branch; `build.yml` builds the default
  image on `testing` and `main` and every day; `build-dx.yml`, `build-nvidia.yml` and `build-nvidia-dx.yml`
  build the variants; `binaries.yml` builds the prebuilt programs; `publish-latest.yml` moves the
  `latest` tag; `bump-pins.yml` opens the weekly pull requests that move pinned versions; the rest are maintenance (cleanup of old test images, a rollback, a workflow security audit).
- `scripts/` has the shell and Python helpers the workflows call (planning which builds are needed, registry and signature
  checks, smoke tests, pin bumps). `actions/` has two small shared steps (tool install and the test suite).
- `dependabot.yml` and `zizmor.yml` configure dependency updates and the workflow audit.

How a change flows: work on a feature branch, where `test.yml` runs the tests; open a pull request into `testing`; merging
it makes `build.yml` build and publish the `testing` image. A pull request from `testing` into `main` (the only way into
`main`, enforced by `require-testing-branch.yml` and the branch rules) is checked, and merging it promotes the tested
build instead of building again; the `latest` tag then moves for the default and dx images together. Pushes that change
only documentation skip the image builds.

Before editing: workflows are audited for security problems, and the required checks (`test`, `secrets` and the build
check) must keep their names. Scripts are tested from `tests/`, so a change to one usually needs a test change too.
