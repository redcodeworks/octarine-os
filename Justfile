set dotenv-path := "config/image.env"
set dotenv-load

export image_name := env_var("IMAGE_NAME")
export repo_organization := env_var("REPO_ORGANIZATION")
export image_desc := env_var("IMAGE_DESC")
# The repository name (URLs in the labels); IMAGE_NAME may carry a variant suffix such as -nvidia in CI
repo_name := env_var_or_default("REPO_NAME", image_name)
export image_keywords := env_var("IMAGE_KEYWORDS")
export image_logo_url := env_var("IMAGE_LOGO_URL")
export default_tag := env_var("DEFAULT_TAG")

[private]
default:
    @just --list

# Check Just Syntax
[group('Just')]
check:
    #!/usr/bin/env bash
    find . -type f -name "*.just" | while read -r file; do
    	echo "Checking syntax: $file"
    	just --unstable --fmt --check -f $file
    done
    echo "Checking syntax: Justfile"
    just --unstable --fmt --check -f Justfile

# Fix Just Syntax
[group('Just')]
fix:
    #!/usr/bin/env bash
    find . -type f -name "*.just" | while read -r file; do
    	echo "Checking syntax: $file"
    	just --unstable --fmt -f $file
    done
    echo "Checking syntax: Justfile"
    just --unstable --fmt -f Justfile || { exit 1; }

# Clean Repo
[group('Utility')]
clean:
    #!/usr/bin/env bash
    set -eoux pipefail
    touch _build
    find *_build* -exec rm -rf {} \;
    rm -f previous.manifest.json
    rm -f changelog.md
    rm -f output.env

# Sudo Clean Repo
[group('Utility')]
[private]
sudo-clean:
    just sudoif just clean

# sudoif bash function
[group('Utility')]
[private]
sudoif command *args:
    #!/usr/bin/env bash
    function sudoif(){
        if [[ "${UID}" -eq 0 ]]; then
            "$@"
        elif [[ "$(command -v sudo)" && -n "${SSH_ASKPASS:-}" ]] && [[ -n "${DISPLAY:-}" || -n "${WAYLAND_DISPLAY:-}" ]]; then
            sudo --askpass "$@" || exit 1
        elif [[ "$(command -v sudo)" ]]; then
            sudo "$@" || exit 1
        else
            exit 1
        fi
    }
    sudoif {{ command }} {{ args }}

# This Justfile recipe builds a container image using Podman.
#
# Arguments:
#   $target_image - The tag you want to apply to the image (default: $image_name).
#   $tag - The tag for the image (default: $default_tag).
#
# The version label is `<YYYYMMDD>-<short sha>` (.github/scripts/image_version.py), the same for testing and
# main builds, and only set when the git working directory is clean.
#
# just build $target_image $tag
#
# Example usage:
#   just build myimage mytag
#
# This will build an image 'myimage:mytag'
#

# Build the image using the specified parameters
build $target_image=image_name $tag=default_tag:
    #!/usr/bin/env bash

    set -euox pipefail

    BUILD_ARGS=()
    BUILD_ARGS+=("--build-arg" "IMAGE_ORG={{ repo_organization }}")
    BUILD_ARGS+=("--build-arg" "IMAGE_NAME=${target_image##*/}")  # strip a registry or localhost/ prefix
    # BREW_IMAGE overrides the Containerfile's digest-pinned default (for a local experiment); CI uses the default
    if [[ -n "${BREW_IMAGE:-}" ]]; then BUILD_ARGS+=("--build-arg" "BREW_IMAGE=${BREW_IMAGE}"); fi
    # The prebuilt binaries image is pinned by digest in the Containerfile (BINS_DIGEST); nothing to pass
    # CI sets BASE_IMAGE and FEDORA_VERSION (workflow env, optionally from repository variables); locally they are
    # optional (`FEDORA_VERSION=46 just build`) and the Containerfile defaults apply when unset
    if [[ -n "${BASE_IMAGE:-}" ]]; then BUILD_ARGS+=("--build-arg" "BASE_IMAGE=${BASE_IMAGE}"); fi
    if [[ -n "${FEDORA_VERSION:-}" ]]; then BUILD_ARGS+=("--build-arg" "FEDORA_VERSION=${FEDORA_VERSION}"); fi
    # CI resolves the floating base to a digest once and verifies its signature (base_pin.py): the build is FROM that digest
    if [[ -n "${BASE_PIN:-}" ]]; then BUILD_ARGS+=("--build-arg" "BASE_PIN=${BASE_PIN}"); fi
    # os-release IMAGE_VERSION: the build's version
    BUILD_ARGS+=("--build-arg" "IMAGE_VERSION=$(uv run --frozen --no-dev python -I .github/scripts/image_version.py)")
    LABELS=()
    # Trace the image to its base (CI exports BASE_DIGEST after pulling the base)
    if [[ -n "${BASE_IMAGE:-}" && -n "${FEDORA_VERSION:-}" ]]; then LABELS+=("--label" "org.opencontainers.image.base.name=${BASE_IMAGE}:${FEDORA_VERSION}"); fi
    if [[ -n "${BASE_DIGEST:-}" ]]; then LABELS+=("--label" "org.opencontainers.image.base.digest=${BASE_DIGEST}"); fi
    # The base's manifest-list digest: the scheduled run compares it with the current base to decide whether to skip the build
    # the upstream base digest this image was built on and that it was verified against the pinned Universal Blue key (a new label; the
    # dx labels org.opencontainers.image.base.digest and dx-inputs are not touched)
    if [[ -n "${BASE_PIN:-}" ]]; then LABELS+=("--label" "org.octarineos.upstream-base=${BASE_PIN}" "--label" "org.octarineos.upstream-base-verified=cosign keys/ublue-os-main-cosign.pub"); fi
    if [[ -n "${BASE_INDEX_DIGEST:-}" ]]; then LABELS+=("--label" "io.github.redcodeworks.octarine-os.base-index-digest=${BASE_INDEX_DIGEST}"); fi
    if [[ -z "$(git status -s)" ]]; then
        GIT_SHA=$(git rev-parse --short HEAD)
        LABELS+=("--label" "io.artifacthub.package.readme-url=https://raw.githubusercontent.com/{{ repo_organization }}/{{ repo_name }}/${GIT_SHA}/README.md")
        LABELS+=("--label" "org.opencontainers.image.documentation=https://raw.githubusercontent.com/{{ repo_organization }}/{{ repo_name }}/${GIT_SHA}/README.md")
        LABELS+=("--label" "org.opencontainers.image.url=https://github.com/{{ repo_organization }}/{{ repo_name }}/tree/${GIT_SHA}")
        LABELS+=("--label" "org.opencontainers.image.version=$(uv run --frozen --no-dev python -I .github/scripts/image_version.py)")
        # The full commit this image was built from (the scheduled skip check compares its content with main)
        LABELS+=("--label" "org.opencontainers.image.revision=$(git rev-parse HEAD)")
        # The hash of the files that make the default image (not docs, not the dx-only files): a push whose hash is equal
        # needs no new image, see .github/scripts/inputs_hash.py
        LABELS+=("--label" "io.github.redcodeworks.octarine-os.vanilla-inputs=$(uv run --frozen --no-dev python -I .github/scripts/inputs_hash.py vanilla)")
    fi

    # The pinned prebuilt binaries image this build installed from (the digest reference: the exact binaries of this image, for a rollback)
    LABELS+=("--label" "io.github.redcodeworks.octarine-os.binaries=ghcr.io/{{ repo_organization }}/octarine-bins@$(sed -n 's/^ARG BINS_DIGEST=//p' Containerfile)")

    # Image metadata for https://artifacthub.io/ - This is optional but is highly recommended so we all can get a index of all the custom images
    # The metadata by itself is not going to do anything, you choose if you want your image to be on ArtifactHub or not.
    LABELS+=("--label" "io.artifacthub.package.deprecated=false")
    LABELS+=("--label" "io.artifacthub.package.keywords={{ image_keywords }}")
    LABELS+=("--label" "io.artifacthub.package.license=Apache-2.0")
    LABELS+=("--label" "io.artifacthub.package.logo-url={{ image_logo_url }}")
    LABELS+=("--label" "io.artifacthub.package.prerelease=false")
    # The source label links the GHCR package to the repository; the licenses label is shown on the package page
    LABELS+=("--label" "org.opencontainers.image.source=https://github.com/{{ repo_organization }}/{{ repo_name }}")
    LABELS+=("--label" "org.opencontainers.image.licenses=Apache-2.0")
    LABELS+=("--label" "org.opencontainers.image.created=$(date -u +%Y\-%m\-%d\T%H\:%M\:%S\Z)")
    LABELS+=("--label" "org.opencontainers.image.description={{ image_desc }}${IMAGE_VARIANT:+ (NVIDIA variant for NVIDIA GPUs, built weekly from the NVIDIA base)}")
    LABELS+=("--label" "org.opencontainers.image.title=${target_image}")
    LABELS+=("--label" "org.opencontainers.image.vendor={{ repo_organization }}")

    # This actually builds the image!
    PODMAN_BUILD_ARGS=("${BUILD_ARGS[@]}" "${LABELS[@]}" --pull=newer --tag "${target_image}:${tag}" --file Containerfile)

    podman build "${PODMAN_BUILD_ARGS[@]}" .

# Split the image into layers for smaller updates (chunkah, like Aurora and Bazzite). The chunkah image is pinned by digest in config/chunkah.env and its
# cosign signature is verified before it runs (.github/scripts/chunkah_ref.py). chunkah starts from the image's own config (`podman inspect`), so
# every label set by `just build` stays; CHUNKAH_EPOCH_BASE (see below) sets SOURCE_DATE_EPOCH; the labels of an earlier ostree commit are dropped, as chunkah's own documentation does.
# You may run into space issues on runners: this makes a complete copy of the image.
[group('Image')]
rechunk $target_image=image_name $tag=default_tag:
    #!/usr/bin/env bash

    set -xeuo pipefail

    CHUNKAH_REF="$(uv run --frozen --no-dev python -I .github/scripts/chunkah_ref.py)"
    STARTED="$(date +%s)"
    CHUNKAH_CONFIG_FILE="$(mktemp)"

    # The output goes in the current directory, not /tmp (it may be small)
    CHUNKAH_OUTPUT_DIR="$(mktemp -d ./"${target_image}"_chunkah_XXXXXX)"

    trap 'rm -f "${CHUNKAH_CONFIG_FILE}"; rm -rf "${CHUNKAH_OUTPUT_DIR}"' EXIT
    podman inspect "${target_image}:${tag}" > "${CHUNKAH_CONFIG_FILE}"

    # The optional packages that did not install (build.sh writes the list into the image) become a LABEL, so the daily's skip check can see a degraded latest and
    # rebuild it instead of keeping it for up to a week (plan_skip.py): "none" or a comma separated list; no label when the image has no such file
    MISSING_LABEL=()
    if missing="$(podman run --rm --network none "${target_image}:${tag}" cat /usr/share/octarine-os/optional-packages-missing 2> /dev/null)"; then
      csv="$(printf '%s\n' "${missing}" | grep -v '^$' | paste -sd, - || true)"
      MISSING_LABEL=(--label "org.octarineos.optional-packages-missing=${csv:-none}")
    fi

    # Reproducible layers: chunkah clamps the mtime of every file no package owns to SOURCE_DATE_EPOCH (else to now), so a rebuild with no content change
    # re-shipped every layer with such files. The epoch is the Created time of the image the build started FROM (CHUNKAH_EPOCH_BASE, a digest reference the
    # workflow has already pulled): a pure function of the base digest. Unset (a local run): no epoch, chunkah's default. Set but unreadable: fail.
    EPOCH_ARGS=()
    if [[ -n "${CHUNKAH_EPOCH_BASE:-}" ]]; then
      epoch="$(podman image inspect --format '{{ '{{.Created.Unix}}' }}' "${CHUNKAH_EPOCH_BASE}")"
      [[ "${epoch}" =~ ^[0-9]+$ && "${epoch}" -gt 0 ]] || { echo "::error::no usable Created time for ${CHUNKAH_EPOCH_BASE}: '${epoch}'"; exit 1; }
      EPOCH_ARGS=(-e "SOURCE_DATE_EPOCH=${epoch}")
    fi

    podman run --rm \
      "${EPOCH_ARGS[@]}" \
      --mount=type=image,src="${target_image}:${tag}",target=/chunkah \
      -v "${CHUNKAH_CONFIG_FILE}:/chunkah-config.json:ro,Z" \
      -v "${CHUNKAH_OUTPUT_DIR}:/run/out:Z" \
      "${CHUNKAH_REF}" \
      build \
      --verbose \
      --compressed \
      --max-layers 256 \
      --prune /sysroot/ \
      --label ostree.commit- --label ostree.final-diffid- \
      "${MISSING_LABEL[@]}" \
      --config /chunkah-config.json \
      --output oci:/run/out/chunked

    CHUNKED_IMAGE="$(podman pull "oci:${CHUNKAH_OUTPUT_DIR}/chunked")"
    podman tag "${CHUNKED_IMAGE}" "${target_image}:${tag}"
    LAYERS="$(podman image inspect "${target_image}:${tag}" --format '{{ '{{len .RootFS.Layers}}' }}')"
    SIZE_MIB="$(( $(podman image inspect "${target_image}:${tag}" --format '{{ '{{.Size}}' }}') / 1048576 ))"
    MSG="Rechunk (chunkah): ${target_image}:${tag}, $(( $(date +%s) - STARTED )) s, ${LAYERS} layers, ${SIZE_MIB} MiB, ${CHUNKAH_REF}"
    echo "${MSG}"
    if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then echo "${MSG}" >> "${GITHUB_STEP_SUMMARY}"; fi

# Generate Default Tag
[group('Utility')]
generate-default-tag $tag=default_tag:
    #!/usr/bin/env bash
    set -eoux pipefail

    echo "${tag}"

# Generate Tags
[group('Utility')]
generate-build-tags $target_image=image_name $tag=default_tag $bare="true":
    #!/usr/bin/env bash
    set -eoux pipefail

    DATE=$(date +%Y%m%d)
    BUILD_TAGS=()
    if [[ -z "$(git status -s)" ]]; then
        GIT_SHA=$(git rev-parse --short HEAD)
        BUILD_TAGS+=("${tag}-${GIT_SHA}")
        BUILD_TAGS+=("${tag}-${DATE}-${GIT_SHA}")
        if [[ "$tag" == "latest" ]]; then
            BUILD_TAGS+=("${DATE}-${GIT_SHA}")
        fi
    fi

    if [[ "$tag" == "latest" ]]; then
        BUILD_TAGS+=("${DATE}")
    fi
    # bare=false: the tag list of a main build or promotion, which publishes only the dated tags; the bare `latest` of both the
    # default and the dx image is moved by the publish-latest workflow once the pair has been checked
    if [[ ! ( "$tag" == "latest" && "$bare" == "false" ) ]]; then
        BUILD_TAGS+=("${tag}")
    fi
    BUILD_TAGS+=("${tag}-${DATE}")

    echo "${BUILD_TAGS[@]}"

# Tag Images
[group('Utility')]
tag-images $target_image=image_name $tag=default_tag tags="":
    #!/usr/bin/env bash
    set -eoux pipefail

    # Get Image, and untag
    IMAGE=$(podman inspect ${target_image}:${tag} | jq -r .[].Id)
    podman untag ${IMAGE}

    # Tag Image
    for tag in {{ tags }}; do
        podman tag $IMAGE "${target_image}:${tag}"
    done

    # Show Images
    podman images

# Image Name
[group('Utility')]
[private]
image_name $target_image=image_name:
    #!/usr/bin/env bash
    set -eoux pipefail

    echo "${image_name}"

# Runs shell check on all Bash scripts
lint:
    #!/usr/bin/env bash
    set -eoux pipefail
    # Check if shellcheck is installed
    if ! command -v shellcheck &> /dev/null; then
        echo "shellcheck could not be found. Please install it."
        exit 1
    fi
    # Run shellcheck on all Bash scripts
    find . -iname "*.sh" -type f -exec shellcheck "{}" ';'

# Runs shfmt on all Bash scripts
format:
    #!/usr/bin/env bash
    set -eoux pipefail
    # Check if shfmt is installed
    if ! command -v shfmt &> /dev/null; then
        echo "shfmt could not be found. Please install it."
        exit 1
    fi
    # Run shfmt on all Bash scripts
    find . -iname "*.sh" -type f -exec shfmt --write "{}" ';'

# Open the release pull request from testing into main. Pass true to also wait for the required checks and merge it
[group('Release')]
release $merge="false":
    #!/usr/bin/env bash
    set -euo pipefail
    git fetch -q origin
    branch=$(git rev-parse --abbrev-ref HEAD)
    [[ "$branch" == "testing" ]] || { echo "Switch to the testing branch first (you are on '$branch')"; exit 1; }
    [[ -z "$(git status --porcelain --untracked-files=no)" ]] || { echo "Commit or stash your changes first"; exit 1; }
    [[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/testing)" ]] || { echo "testing is not in sync with origin/testing: push (or pull) first"; exit 1; }
    [[ "$(git rev-list --count origin/main..origin/testing)" -gt 0 ]] || { echo "testing has nothing that main does not already have"; exit 0; }

    url=$(gh pr list --base main --head testing --state open --json url --jq '.[0].url // empty')
    if [[ -z "$url" ]]; then
        url=$(gh pr create --base main --head testing \
            --title "Release $(date +%Y-%m-%d)" \
            --body "$(git log --format='- %s' origin/main..origin/testing)")
    fi
    echo "$url"

    if [[ "$merge" == "true" ]]; then
        echo "Waiting for the required checks (the testing build can take about 20 minutes)..."
        gh pr checks "$url" --watch --required
        gh pr merge "$url" --merge
        echo "Merged. The latest build is running: gh run list --branch main --limit 1"
    else
        echo "When the checks pass, merge it with: just release true   (or: gh pr merge --merge)"
    fi

# List the newest dated tags of the Homebrew files image and the current pin (bump it with `just brew-bump`)
[group('Image')]
brew-tags:
    #!/usr/bin/env bash
    set -euo pipefail
    skopeo list-tags docker://ghcr.io/ublue-os/brew | python3 -c 'import json,re,sys; print("\n".join(sorted(t for t in json.load(sys.stdin)["Tags"] if re.fullmatch(r"\d{8}", t))[-8:]))'
    echo "Current: $(sed -n 's/^ARG BREW_TAG=//p' Containerfile)@$(sed -n 's/^ARG BREW_DIGEST=//p' Containerfile)"

# Bump the Homebrew files image pin: resolve the digest of a dated tag (default: the newest), verify its cosign signature, write tag and digest into the Containerfile
[group('Image')]
brew-bump tag="":
    #!/usr/bin/env bash
    set -euo pipefail
    tag="{{ tag }}"
    if [[ -z "${tag}" ]]; then
        tag=$(skopeo list-tags docker://ghcr.io/ublue-os/brew | python3 -c 'import json,re,sys; print(sorted(t for t in json.load(sys.stdin)["Tags"] if re.fullmatch(r"\d{8}", t))[-1])')
    fi
    [[ "${tag}" =~ ^[0-9]{8}$ ]] || { echo "tag must be YYYYMMDD, got '${tag}'" >&2; exit 1; }
    digest=$(skopeo inspect --raw "docker://ghcr.io/ublue-os/brew:${tag}" | sha256sum | sed 's/ .*//')
    [[ "${digest}" =~ ^[0-9a-f]{64}$ ]] || { echo "cannot resolve ghcr.io/ublue-os/brew:${tag}" >&2; exit 1; }
    ref="ghcr.io/ublue-os/brew@sha256:${digest}"
    cosign verify --key keys/ublue-os-brew-cosign.pub "${ref}" > /dev/null || { echo "cosign verification failed for ${ref}; the Containerfile is unchanged" >&2; exit 1; }
    sed -i -e "s/^ARG BREW_TAG=.*/ARG BREW_TAG=${tag}/" -e "s/^ARG BREW_DIGEST=.*/ARG BREW_DIGEST=sha256:${digest}/" Containerfile
    echo "Containerfile now pins ghcr.io/ublue-os/brew:${tag}@sha256:${digest} (signature valid)"

# Bump the octarine-bins pin: resolve the digest of a tag (default: latest), verify its cosign signature with keys/octarine-bins.pub, write tag and digest into the Containerfile
[group('Image')]
bins-bump tag="latest":
    #!/usr/bin/env bash
    set -euo pipefail
    ref="ghcr.io/redcodeworks/octarine-bins"
    digest=$(skopeo inspect --raw "docker://${ref}:{{ tag }}" | sha256sum | sed 's/ .*//')
    [[ "${digest}" =~ ^[0-9a-f]{64}$ ]] || { echo "cannot resolve ${ref}:{{ tag }}" >&2; exit 1; }
    cosign verify --key keys/octarine-bins.pub "${ref}@sha256:${digest}" > /dev/null || { echo "cosign verification failed for ${ref}@sha256:${digest}; the Containerfile is unchanged" >&2; exit 1; }
    version=$(skopeo inspect --config "docker://${ref}@sha256:${digest}" | jq -r '.config.Labels["org.opencontainers.image.version"] // empty')
    [[ "${version}" =~ ^[0-9]{8}-[0-9a-f]{7}$ ]] || { echo "the image has no usable org.opencontainers.image.version label ('${version}')" >&2; exit 1; }
    sed -i -e "s/^ARG BINS_TAG=.*/ARG BINS_TAG=${version}/" -e "s/^ARG BINS_DIGEST=.*/ARG BINS_DIGEST=sha256:${digest}/" Containerfile
    echo "Containerfile now pins ${ref}:${version}@sha256:${digest} (signature valid)"

# Use this repository's git hooks (ruff format and shfmt of staged files on commit, a gitleaks scan on push)
[group('Security')]
install-hooks:
    #!/usr/bin/env bash
    set -euo pipefail
    git config core.hooksPath githooks
    echo "Git hooks enabled from githooks/. The pre-push scan needs gitleaks (brew install gitleaks); the pre-commit format needs uv and shfmt"
