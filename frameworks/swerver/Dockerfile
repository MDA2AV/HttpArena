FROM debian:trixie AS build

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl xz-utils git libssl-dev dpkg-dev pkg-config python3 \
    && rm -rf /var/lib/apt/lists/*

# Install Zig 0.16.0 stable
RUN set -eux; \
    DPKG_ARCH=$(dpkg --print-architecture); \
    case "${DPKG_ARCH}" in \
        amd64) ZIG_ARCH=x86_64 ;; \
        arm64) ZIG_ARCH=aarch64 ;; \
        *) echo "unsupported arch: ${DPKG_ARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://ziglang.org/download/0.16.0/zig-${ZIG_ARCH}-linux-0.16.0.tar.xz" \
        -o /tmp/zig.tar.xz; \
    mkdir -p /opt/zig; \
    tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1; \
    rm /tmp/zig.tar.xz; \
    ln -s /opt/zig/zig /usr/local/bin/zig; \
    zig version

# Clone swerver library
WORKDIR /src
RUN git clone --depth 1 --branch v0.1.0-alpha.6 \
        https://github.com/justinGrosvenor/swerver.git .

# Symlink OpenSSL for Zig's linker
RUN MULTIARCH=$(dpkg-architecture -qDEB_HOST_MULTIARCH); \
    for lib in libssl.so libssl.a libcrypto.so libcrypto.a; do \
        ln -sf "/usr/lib/${MULTIARCH}/${lib}" "/usr/lib/${lib}"; \
    done

# Copy HttpArena application source into swerver tree and build
COPY main.zig build.zig build.zig.zon /src/httparena/
WORKDIR /src/httparena
RUN zig build --summary all

# ── runtime stage ──
FROM debian:trixie-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates libssl3 \
    && rm -rf /var/lib/apt/lists/*

COPY --from=build /src/httparena/zig-out/bin/swerver-httparena /usr/local/bin/swerver
COPY config-h1.json /etc/swerver/config-h1.json
COPY config-tls.json /etc/swerver/config-tls.json
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 8080 8443/tcp 8443/udp

CMD ["/usr/local/bin/entrypoint.sh"]
