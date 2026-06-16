# syntax=docker/dockerfile:1.7
#
# zix-ws. Zig WebSocket echo server on the zix.Http1 raw engine (no std.http).
# Shared-nothing EPOLL: each worker runs its own SO_REUSEPORT accept plus
# level-triggered epoll loop. The WebSocket upgrade and echo are engine-owned,
# a pipelined frame burst is coalesced into one write on readiness.
# Built statically against musl, x86_64 tuned to the x86_64_v3 baseline (AVX2,
# matches the AMD Zen 2 benchmark host, stays below the AVX-512 it lacks). The
# runtime image is the single static binary on Alpine.

FROM alpine:3.20 AS build
ARG RETRY=6
ARG TARGETARCH
ARG RETRY_DELAY=3
ARG ZIG_VERSION=0.16.0
ARG ZIX_VERSION=0.4.x-rc2
RUN apk add --no-cache ca-certificates git curl xz tar

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

# Vendor zix 0.4.x-rc2, separate layer so source-only rebuilds skip the clone.
# The Http1 raw engine work this image needs (large-body drain plus the per-worker
# response cache used by the /json endpoint) must be present on the 0.4.x-rc2
# branch. A shallow git clone over github.com is used instead of the archive
# tarball: the archive endpoint redirects to codeload.github.com, which the
# benchmark runner cannot resolve. git clone talks to github.com directly.
# Codeberg is the fallback when github.com is unreachable. RETRY and RETRY_DELAY
# bound the per-source attempts.
RUN set -eu; \
    clone() { \
        attempt=0; \
        while [ "${attempt}" -lt "${RETRY}" ]; do \
            git clone --depth 1 --branch "${ZIX_VERSION}" "$1" /src/vendor/zix && return 0; \
            rm -rf /src/vendor/zix; \
            attempt=$((attempt + 1)); \
            sleep "${RETRY_DELAY}"; \
        done; \
        return 1; \
    }; \
    clone "https://github.com/prothegee/zix.git" \
    || { echo "FAILED: git clone ${RETRY} times from github" >&2; \
        clone "https://codeberg.org/prothegee/zix.git" \
    || { echo "FAILED: git clone ${RETRY} times from codeberg" >&2; exit 1; }; }

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
