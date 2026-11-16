# Git hooks (`githooks/`)

Optional hooks for a local clone. `pre-push` scans the commits about to be pushed for secrets with
[gitleaks](https://github.com/gitleaks/gitleaks) and stops the push if it finds any; it only warns if gitleaks is not installed.

Enable them in a clone with `just install-hooks`, which points `core.hooksPath` at this folder. They run on the
contributor's machine only: nothing in the image or the CI workflows uses them. To skip the scan once, push with
`--no-verify`.
