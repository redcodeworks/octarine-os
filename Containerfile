# Homebrew, as files only: Universal Blue's `ghcr.io/ublue-os/brew` is a FROM scratch image that holds
# /system_files (a tarball of the prefix plus the first-boot, update and upgrade units). Pinned by DIGEST, with the
# dated tag (YYYYMMDD, upstream rebuilds weekly) kept for humans. Bump both with `just brew-bump [tag]`, which resolves the
# digest, verifies it with cosign against keys/ublue-os-brew-cosign.pub and writes both lines; CI checks the format
# on every build and the signature whenever the pin changed. The pinned reference is logged by the build.
ARG BREW_TAG=20261115
ARG BREW_DIGEST=sha256:9e0492dbc471258657564c94dae18b58dd96ddb998a06f2b15e8209efb48042b
ARG BREW_IMAGE=ghcr.io/ublue-os/brew:${BREW_TAG}@${BREW_DIGEST}
# Prebuilt binaries, as files only: ghcr.io/redcodeworks/octarine-bins is a FROM scratch image built and signed (with its OWN key,
# keys/octarine-bins.pub) by the octarine-bins repository: the sched_ext schedulers scx_* (GPL-2.0), libextest.so for Steam Input on
# Wayland (32-bit and 64-bit, MIT) and Ghostty. Pinned by DIGEST like the brew image above: it changes only through a bump PR
# (the weekly bump-pins.yml or `just bins-bump [tag]`, which resolve the digest and verify it with cosign before writing it); CI
# verifies the pinned digest on every build, logs it and records it in an image label. BINS_TAG (the image's `<date>-<sha>` version) is only for humans. build.sh installs the files under /usr
# (the package lists of the images are text files in this repository, packages/<kind>, installed by build_files/install-packages.sh).
ARG BINS_TAG=20261117-f1507cc
ARG BINS_DIGEST=sha256:7f762f58d7773656e51c4cf28d9fe2bf63e1b7dc9c5e03dd70c799c1dc8ebfe9
ARG BINS_IMAGE=ghcr.io/redcodeworks/octarine-bins:${BINS_TAG}@${BINS_DIGEST}
# Base image selection (see the base image comment below); declared here, before the first FROM
ARG BASE_IMAGE=ghcr.io/ublue-os/silverblue-main
ARG FEDORA_VERSION=45
# The digest of ${BASE_IMAGE}:${FEDORA_VERSION} that the workflow resolved ONCE and verified (.github/scripts/base-pin.sh); empty for a local
# `just build`, which then builds on the floating tag as before.
ARG BASE_PIN=""
FROM ${BREW_IMAGE} AS brew
FROM ${BINS_IMAGE} AS binaries

# Allow build scripts to be referenced without being copied into the final image
FROM scratch AS ctx
COPY build_files /
COPY packages/default /packages
COPY system_files /system_files
COPY cosign.pub /cosign.pub

# Base image: `just build` and CI pass BASE_IMAGE and FEDORA_VERSION from config/image.env (the one place to edit,
# for example for a Fedora major upgrade). Like the brew ARGs above, these must stay before the first FROM to be
# usable in a FROM line; the defaults repeat the env file for a bare `podman build` and CI checks they agree.
FROM ${BASE_IMAGE}:${FEDORA_VERSION}${BASE_PIN:+@}${BASE_PIN}

# Passed in by `just build` from config/image.env; used to scope the signature policy to this image
ARG IMAGE_ORG
ARG IMAGE_NAME
# The build's channel-neutral version written to os-release IMAGE_VERSION by build.sh
ARG IMAGE_VERSION
## Other possible base images include:
# FROM ghcr.io/ublue-os/bazzite:stable
# FROM ghcr.io/ublue-os/bazzite:testing
# FROM ghcr.io/ublue-os/aurora:stable
# FROM ghcr.io/ublue-os/bluefin-nvidia-open:stable
# 
# ... and so on, here are more base images
# Universal Blue Images: https://github.com/orgs/ublue-os/packages
# Fedora base image: quay.io/fedora/fedora-bootc:<release>
# CentOS base images: quay.io/centos-bootc/centos-bootc:stream10

### [IM]MUTABLE /opt
## Some bootable images, like Fedora, have /opt symlinked to /var/opt, in order to
## make it mutable/writable for users. However, some packages write files to this directory,
## thus its contents might be wiped out when bootc deploys an image, making it troublesome for
## some packages. Eg, google-chrome, docker-desktop.
##
## Uncomment the following line if one desires to make /opt immutable and be able to be used
## by the package manager.

# RUN rm /opt && mkdir /opt

### MODIFICATIONS
## make modifications desired in your image and install packages by modifying the build.sh script
## the following RUN directive does all the things required to run "build.sh" as recommended.

# Brew's files go in first; build.sh then copies system_files over them, so our presets and files win
COPY --from=brew /system_files /

# The pinned octarine-bins image is bind-mounted, not copied, so build.sh installs exactly what it checks (layout and contract:
# the header of install-binaries.sh). /binaries/COMPONENTS names the components;
# install-binaries.sh installs them and checks that the shared libraries the binaries need are in this image
RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=bind,from=binaries,source=/,target=/binaries \
    --mount=type=cache,dst=/var/cache \
    --mount=type=cache,dst=/var/log \
    --mount=type=tmpfs,dst=/tmp \
    /ctx/build.sh

### LINTING
## Verify final image and contents are correct.
RUN --network=none bootc container lint --fatal-warnings --no-truncate
