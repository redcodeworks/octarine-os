# Homebrew, as files only: Universal Blue's `ghcr.io/ublue-os/brew` is a FROM scratch image that holds
# /system_files (a tarball of the prefix plus the first-boot, update and upgrade units). Pinned by DIGEST, with the
# dated tag (YYYYMMDD, upstream rebuilds weekly) kept for humans. Bump both with `just brew-bump [tag]`, which resolves the
# digest, verifies it with cosign against keys/ublue-os-brew-cosign.pub and writes both lines; CI checks the format
# on every build and the signature whenever the pin changed. The pinned reference is logged by the build.
ARG BREW_TAG=20261108
ARG BREW_DIGEST=sha256:2993b28cf9a54efebdc418ef42228618f5c68e8b931430f2d60eddc190e30016
ARG BREW_IMAGE=ghcr.io/ublue-os/brew:${BREW_TAG}@${BREW_DIGEST}
# Base image selection (see the base image comment below); declared here, before the first FROM
ARG BASE_IMAGE=ghcr.io/ublue-os/silverblue-main
ARG FEDORA_VERSION=45
FROM ${BREW_IMAGE} AS brew

# Allow build scripts to be referenced without being copied into the final image
FROM scratch AS ctx
COPY build_files /
COPY system_files /system_files
COPY cosign.pub /cosign.pub

# Base image: `just build` and CI pass BASE_IMAGE and FEDORA_VERSION from image-template.env (the one place to edit,
# for example for a Fedora major upgrade). Like the brew ARGs above, these must stay before the first FROM to be
# usable in a FROM line; the defaults repeat the env file for a bare `podman build` and CI checks they agree.
FROM ${BASE_IMAGE}:${FEDORA_VERSION}

# Passed in by `just build` from image-template.env; used to scope the signature policy to this image
ARG IMAGE_ORG
ARG IMAGE_NAME
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

RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=cache,dst=/var/cache \
    --mount=type=cache,dst=/var/log \
    --mount=type=tmpfs,dst=/tmp \
    /ctx/build.sh

### LINTING
## Verify final image and contents are correct.
RUN bootc container lint
