FROM debian:trixie AS build

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl xz-utils git libssl-dev pkg-config python3 \
    && rm -rf /var/lib/apt/lists/*

# Install latest Zig nightly (0.16.0-dev)
RUN set -eux; \
    DPKG_ARCH=$(dpkg --print-architecture); \
    case "${DPKG_ARCH}" in \
        amd64) ZIG_ARCH=x86_64 ;; \
        arm64) ZIG_ARCH=aarch64 ;; \
        *) echo "unsupported arch: ${DPKG_ARCH}" >&2; exit 1 ;; \
    esac; \
    ZIG_URL=$(curl -fsSL https://ziglang.org/download/index.json | \
        python3 -c "import json,sys; d=json.load(sys.stdin)['master']; print(d['${ZIG_ARCH}-linux']['tarball'])"); \
    curl -fsSL "${ZIG_URL}" -o /tmp/zig.tar.xz; \
    mkdir -p /opt/zig; \
    tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1; \
    rm /tmp/zig.tar.xz; \
    ln -s /opt/zig/zig /usr/local/bin/zig; \
    zig version

# Clone swerver source — pinned to specific commit to bust Docker cache
WORKDIR /src
RUN git clone https://github.com/justinGrosvenor/swerver.git . && \
    git checkout 89943bd855efcd57543d36e1c6ed1c963c31677f

# Symlink OpenSSL libs to /usr/lib/ for Zig's linker
RUN MULTIARCH=$(dpkg-architecture -qDEB_HOST_MULTIARCH); \
    for lib in libssl.so libssl.a libcrypto.so libcrypto.a; do \
        ln -sf "/usr/lib/${MULTIARCH}/${lib}" "/usr/lib/${lib}"; \
    done

# Build with all features: TLS + HTTP/2 + HTTP/3 (QUIC)
RUN zig build \
        -Denable-tls=true \
        -Denable-http2=true \
        -Denable-http3=true \
        -Doptimize=ReleaseFast \
        --summary all

# ----- runtime stage -----
FROM debian:trixie-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        libssl3 \
    && rm -rf /var/lib/apt/lists/*

COPY --from=build /src/zig-out/bin/swerver /usr/local/bin/swerver
COPY config-h1.json /etc/swerver/config-h1.json
COPY config-tls.json /etc/swerver/config-tls.json
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 8080 8443/tcp 8443/udp

CMD ["/usr/local/bin/entrypoint.sh"]
