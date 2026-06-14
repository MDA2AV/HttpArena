# syntax=docker/dockerfile:1.7
#
# zix-ws. Zig WebSocket echo server on the zix.Http1 raw engine (no std.http).
# Shared-nothing EPOLL: each worker runs its own SO_REUSEPORT accept plus
# level-triggered epoll loop. The WebSocket upgrade and echo are engine-owned,
# a pipelined frame burst is coalesced into one write on readiness.
# Built statically against musl, x86_64 tuned to the x86_64_v3 baseline (AVX2,
# matches the AMD Zen 2 benchmark host, stays below the AVX-512 it lacks). The
# runtime image is the single static binary on Alpine.

FROM debian:bookworm-slim AS build
ARG ZIG_VERSION=0.16.0
ARG TARGETARCH
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl xz-utils \
    && rm -rf /var/lib/apt/lists/*

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

# Vendor zix 0.4.x-rc1, separate layer so source-only rebuilds skip the download.
# Strip the top-level directory produced by GitHub's archive. The engine-owned
# WebSocket serve plus the per-event write coalescing this image needs must be
# present on the 0.4.x-rc1 branch.
RUN mkdir -p /src/vendor/zix && \
    curl -fsSL https://github.com/prothegee/zix/archive/refs/heads/0.4.x-rc1.tar.gz \
        | tar -xz --strip-components=1 -C /src/vendor/zix

WORKDIR /src
COPY build.zig build.zig.zon ./
COPY src ./src
RUN set -eu; \
    case "${TARGETARCH:-amd64}" in \
        amd64) ZIG_TARGET=x86_64-linux-musl; ZIG_CPU=x86_64_v3 ;; \
        arm64) ZIG_TARGET=aarch64-linux-musl; ZIG_CPU=baseline ;; \
    esac; \
    zig build -Dtarget="${ZIG_TARGET}" -Dcpu="${ZIG_CPU}" --release=fast

FROM alpine:3.20
COPY --from=build /src/zig-out/bin/zix-ws /zix-ws
EXPOSE 8080
ENTRYPOINT ["/zix-ws"]
