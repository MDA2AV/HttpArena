# nilo — a toolkit for Zig 0.16 whose largest module is an HTTP server on
# zio fibers. One static binary, built from the commit `build.zig.zon` pins.

FROM alpine:3.20 AS build
ARG TARGETARCH
ARG ZIG_VERSION=0.16.0
RUN apk add --no-cache ca-certificates curl git tar xz

# The official toolchain, for the arch Buildx is building.
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

WORKDIR /server
COPY build.zig build.zig.zon ./
COPY src ./src

# nilo and its one dependency (zio) come from the pin in build.zig.zon; the
# Postgres driver behind nilo_sql is fetched because build.zig asks for it.
# Static against musl, so the runtime image needs nothing.
RUN set -eu; \
    case "${TARGETARCH:-amd64}" in \
        # `+aes+pclmul` is not decoration. Zig's `x86_64_v3` level carries
        # neither, and std.crypto's AES-256-GCM — which is what an OpenSSL
        # client negotiates — runs at 71 MB/s a core without them against
        # 5,133 with. Without this the TLS profiles collapse: `8gbit`
        # delivers 39% of its offered rate at a six-second p99. Both
        # instructions have been on every x86_64 server CPU since about
        # 2011, unlike the AVX-512 that `x86_64_v4` would also demand.
        amd64) ZIG_TARGET=x86_64-linux-musl; ZIG_CPU=x86_64_v3+aes+pclmul ;; \
        # Same trap on the other arch: ARMv8's crypto extensions are
        # optional, so `baseline` has no AES either. Every server-class
        # aarch64 has them.
        arm64) ZIG_TARGET=aarch64-linux-musl; ZIG_CPU=baseline+aes+sha2 ;; \
    esac; \
    zig build -Dtarget="${ZIG_TARGET}" -Dcpu="${ZIG_CPU}" --release=fast --summary failures

FROM alpine:3.20
COPY --from=build /server/zig-out/bin/nilo-arena /nilo-arena
EXPOSE 8080 8081
ENTRYPOINT ["/nilo-arena"]
