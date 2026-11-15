# The assembled prebuilt binaries image (published as ghcr.io/redcodeworks/octarine-os-binaries:<assembled key>): the content directory
# that binaries/lib/assemble.sh made, copied to /. Build context: that directory (the assemble job of binaries.yml), passed with
# `podman build --file binaries/lib/assemble.Containerfile <dir>`.
FROM scratch

ARG IMAGE_VERSION=dev
ARG IMAGE_REVISION=unknown
ARG IMAGE_CREATED=unknown
ARG IMAGE_COMPONENTS=""
ARG IMAGE_DEGRADED=""

COPY . /

LABEL maintainer="redcodeworks/octarine-os" \
      org.opencontainers.image.authors="redcodeworks" \
      org.opencontainers.image.vendor="redcodeworks" \
      org.opencontainers.image.title="octarine-os-binaries" \
      org.opencontainers.image.description="Prebuilt binaries for octarineOS (sched_ext schedulers, libextest.so and any optional components), assembled from separately built and signed components" \
      org.opencontainers.image.url="https://github.com/redcodeworks/octarine-os" \
      org.opencontainers.image.source="https://github.com/redcodeworks/octarine-os" \
      org.opencontainers.image.version="${IMAGE_VERSION}" \
      org.opencontainers.image.revision="${IMAGE_REVISION}" \
      org.opencontainers.image.created="${IMAGE_CREATED}" \
      org.octarineos.binaries-components="${IMAGE_COMPONENTS}" \
      org.octarineos.binaries-degraded="${IMAGE_DEGRADED}"
