# Allow build scripts to be referenced without being copied into the final image
FROM scratch AS ctx
COPY build_files /
COPY system_files /system_files
COPY cosign.pub /cosign.pub

# Homebrew, as files only: Universal Blue's `ghcr.io/ublue-os/brew` is a FROM scratch image that holds
# /system_files (a tarball of the prefix plus the first-boot, update and upgrade units). It floats on
# `latest` (upstream rebuilds weekly; dated YYYYMMDD tags exist for pinning). CI resolves `latest` to a
# digest once, verifies that digest with cosign (keys/ublue-os-brew-cosign.pub), logs it and passes
# `ref@digest` as BREW_IMAGE, so what was verified is what is built.
ARG BREW_IMAGE=ghcr.io/ublue-os/brew:latest
FROM ${BREW_IMAGE} AS brew

# Base Image
FROM ghcr.io/ublue-os/silverblue-main:45

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
# Fedora base image: quay.io/fedora/fedora-bootc:44
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
