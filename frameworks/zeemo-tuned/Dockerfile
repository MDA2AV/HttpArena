FROM ubuntu:24.04 AS build
ARG ZIG_VERSION=0.16.0
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl xz-utils \
    && rm -rf /var/lib/apt/lists/*
# Architecture comes from `uname -m` so the image matches whatever the
# Docker host is actually running (works for both `docker build` and
# buildx, no TARGETARCH dependency).
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
RUN set -eu; \
    zig build -Dtarget="$(uname -m)-linux-musl" --release=fast

FROM scratch
COPY --from=build /src/zig-out/bin/zeemo-tuned /zeemo-tuned
EXPOSE 8080
ENTRYPOINT ["/zeemo-tuned"]
