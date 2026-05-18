# syntax=docker/dockerfile:1.7
#
# zeemo — Zig io_uring HTTP/1.1 server. Built statically against musl so the
# runtime image is a single binary on scratch.

FROM ubuntu:24.04 AS build
ARG ZIG_VERSION=0.16.0
ARG TARGETARCH
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl xz-utils \
    && rm -rf /var/lib/apt/lists/*

# Pull the official Zig toolchain. Pick the arch that matches the build
# platform; Buildx sets TARGETARCH to amd64/arm64.
RUN set -eu; \
    case "${TARGETARCH:-amd64}" in \
        amd64) ZIG_ARCH=x86_64 ;; \
        arm64) ZIG_ARCH=aarch64 ;; \
        *) echo "unsupported arch: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-${ZIG_ARCH}-linux-${ZIG_VERSION}.tar.xz" \
        | tar -xJ -C /opt; \
    mv "/opt/zig-${ZIG_ARCH}-linux-${ZIG_VERSION}" /opt/zig
ENV PATH="/opt/zig:${PATH}"

WORKDIR /src
COPY build.zig build.zig.zon ./
COPY src ./src
# Match Zig target to the container platform Docker is building.
# HttpArena's bench runner builds for amd64. For local OrbStack on Apple
# Silicon we want arm64 native (Rosetta has BSS-size bugs that abort our
# binary when emulating amd64).
RUN set -eu; \
    case "${TARGETARCH:-amd64}" in \
        amd64) ZIG_TARGET=x86_64-linux-musl ;; \
        arm64) ZIG_TARGET=aarch64-linux-musl ;; \
    esac; \
    zig build -Dtarget="${ZIG_TARGET}" --release=fast

FROM scratch
COPY --from=build /src/zig-out/bin/zeemo /zeemo
EXPOSE 8080
ENTRYPOINT ["/zeemo"]
