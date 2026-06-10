# syntax=docker/dockerfile:1.7
#
# zix. Zig HTTP/1.1 server on the zix.Http1 raw engine (no std.http).
# Shared-nothing EPOLL: each worker runs its own SO_REUSEPORT accept plus
# level-triggered epoll loop. Engine-owned WebSocket echo, large-body drain.
# Built statically against musl so the runtime image is a single binary on scratch.

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

# Vendor zix 0.3.x, separate layer so source-only rebuilds skip the download.
# Strip the top-level directory produced by GitHub's archive. The Http1 raw
# engine work this image needs (engine-owned WebSocket serve + large-body
# drain) must be present on the 0.3.x branch.
RUN mkdir -p /src/vendor/zix && \
    curl -fsSL https://github.com/prothegee/zix/archive/refs/heads/0.3.x.tar.gz \
        | tar -xz --strip-components=1 -C /src/vendor/zix

WORKDIR /src
COPY build.zig build.zig.zon ./
COPY src ./src
RUN set -eu; \
    case "${TARGETARCH:-amd64}" in \
        amd64) ZIG_TARGET=x86_64-linux-musl ;; \
        arm64) ZIG_TARGET=aarch64-linux-musl ;; \
    esac; \
    zig build -Dtarget="${ZIG_TARGET}" --release=fast

FROM debian:bookworm-slim
COPY --from=build /src/zig-out/bin/zix /zix
EXPOSE 8080
ENTRYPOINT ["/zix"]
