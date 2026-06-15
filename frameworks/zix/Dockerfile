# syntax=docker/dockerfile:1.7
#
# zix. Zig HTTP/1.1 server on the zix.Http1 raw engine (no std.http).
# Shared-nothing EPOLL: each worker runs its own SO_REUSEPORT accept plus
# level-triggered epoll loop. Per-worker response cache (/json), large-body drain.
# WebSocket echo lives in the separate zix-ws framework.
# Built statically against musl, x86_64 tuned to the x86_64_v3 baseline (AVX2,
# matches the AMD Zen 2 benchmark host, stays below the AVX-512 it lacks). The
# runtime image is the single static binary on Alpine.

FROM alpine:3.20 AS build
ARG ZIG_VERSION=0.16.0
ARG TARGETARCH
RUN apk add --no-cache ca-certificates curl xz tar

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

# Vendor zix 0.4.x-rc2, separate layer so source-only rebuilds skip the download.
# Strip the top-level directory produced by GitHub's archive. The Http1 raw
# engine work this image needs (large-body drain plus the per-worker response
# cache used by the /json endpoint) must be present on the 0.4.x-rc2 branch.
RUN mkdir -p /src/vendor/zix && \
    curl -fsSL --retry 3 --retry-delay 3 --retry-all-errors \
        https://github.com/prothegee/zix/archive/refs/heads/0.4.x-rc2.tar.gz \
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
COPY --from=build /src/zig-out/bin/zix /zix
EXPOSE 8080
ENTRYPOINT ["/zix"]
