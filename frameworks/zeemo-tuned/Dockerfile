FROM ubuntu:24.04 AS build
ARG ZIG_VERSION=0.16.0
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl xz-utils \
        libssl-dev pkg-config \
    && rm -rf /var/lib/apt/lists/*
# Architecture comes from `uname -m` so the image matches the host arch.
RUN set -eu; \
    ZIG_ARCH="$(uname -m)"; \
    case "${ZIG_ARCH}" in \
        x86_64|aarch64) ;; \
        *) echo "unsupported arch: ${ZIG_ARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-${ZIG_ARCH}-linux-${ZIG_VERSION}.tar.xz" | tar -xJ -C /opt; \
    mv "/opt/zig-${ZIG_ARCH}-linux-${ZIG_VERSION}" /opt/zig
ENV PATH="/opt/zig:${PATH}"

WORKDIR /src
COPY build.zig build.zig.zon ./
COPY src ./src
# Native build (glibc + dynamic libssl/libcrypto). musl-static would need a
# from-source OpenSSL build; the runtime image carries libssl3 instead.
RUN zig build --release=fast

# Runtime: Ubuntu slim so libssl3 is present without extra setup. HttpArena
# mounts /data (dataset + static) and /certs (TLS cert + key) when running.
FROM ubuntu:24.04
RUN apt-get update && apt-get install -y --no-install-recommends \
        libssl3 ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /src/zig-out/bin/zeemo-tuned /zeemo-tuned
EXPOSE 8080 8081
ENTRYPOINT ["/zeemo-tuned"]
