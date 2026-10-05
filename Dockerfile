# nFPM's own image is the pinned source of the binary: v2.47.0, referenced by
# the digest of its multi-architecture index so it resolves on amd64 and arm64
# alike. Podman rejects a reference carrying both a tag and a digest, hence
# the version lives in this comment.
FROM --platform=$BUILDPLATFORM ghcr.io/goreleaser/nfpm@sha256:a662cb167d7b6d3a83920c83d76b12d02b8ac5dd2c13e5c62c15270b23f6df0c AS nfpm

# Packaging only downloads and repacks, so this stage runs on the build
# machine's own platform and takes the target architecture as a plain value.
# An arm64 package can be built on amd64 without emulation.
FROM --platform=$BUILDPLATFORM debian:13-slim AS build
RUN apt-get update \
    && apt-get install --yes --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*
COPY --from=nfpm /usr/bin/nfpm /usr/bin/nfpm
WORKDIR /src
COPY versions.env nfpm.yaml build.sh ./
COPY packaging/ packaging/
ARG TARGETARCH
ARG PRERELEASE=""
# Invoked through bash so the result does not depend on the executable bit,
# which a Windows checkout does not carry into the build context.
RUN PRERELEASE="$PRERELEASE" bash build.sh "$TARGETARCH"

# Holds nothing but the package, for copying out to the host. `build --output`
# would be shorter, but Podman on Windows and macOS does not support it, so
# the package is taken out of a created container instead. Creating a
# container needs some command to be set; it is never run.
FROM scratch AS package
COPY --from=build /src/dist/*.deb /dist/
CMD ["/never-run"]

FROM debian:13-slim AS test
# Debian's container images ship a policy-rc.d that forbids starting
# services during package installation. A real host has none, and the smoke
# test is about what happens on a real host.
RUN apt-get update \
    && apt-get install --yes --no-install-recommends systemd init-system-helpers curl \
    && rm -rf /var/lib/apt/lists/* \
    && rm -f /usr/sbin/policy-rc.d
COPY --from=package /dist/ /smoke/
COPY versions.env test/smoke.sh /smoke/
COPY test/smoke.service /etc/systemd/system/smoke.service
RUN systemctl enable smoke.service
# Boot status lines would bury the test's own output.
CMD ["/usr/lib/systemd/systemd", "--show-status=false"]
