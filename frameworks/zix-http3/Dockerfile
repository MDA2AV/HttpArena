# syntax=docker/dockerfile:1.7

FROM alpine:3.20 AS build
ARG RETRY=6
ARG TARGETARCH
ARG RETRY_DELAY=3
ARG ZIG_VERSION=0.16.0
ARG ZIX_VERSION=0.5.x-rc1
RUN apk add --no-cache ca-certificates curl git tar xz openssl

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

# Resolve zix with zig fetch, then build in the same layer. The mirror and version fill the
# build.zig.zon placeholder, zig fetch downloads it and prints the hash. Codeberg first, GitHub second.
#
# Add +aes+pclmul: x86_64_v3 omits AES-NI / PCLMUL, so zix TLS would compile the ~40x slower
# software AES-GCM. Every x86_64_v3 CPU has them, so it is safe.
RUN set -eu; \
    cp build.zig.zon build.zig.zon.tmpl; \
    save_zix() { \
        base="$1"; \
        attempt=1; \
        while [ "${attempt}" -le "${RETRY}" ]; do \
            sed -e "s|{URL_ZIX_SOURCE}|${base}|g" -e "s|{ZIX_VERSION}|${ZIX_VERSION}|g" \
                build.zig.zon.tmpl > build.zig.zon; \
            if hash="$(zig fetch "${base}/${ZIX_VERSION}.tar.gz")"; then \
                awk -v h="${hash}" '{ print } /\.url = /{ print "            .hash = \"" h "\"," }' \
                    build.zig.zon > build.zig.zon.next; \
                mv build.zig.zon.next build.zig.zon; \
                return 0; \
            fi; \
            echo "zix: ${base} attempt ${attempt}/${RETRY} failed" >&2; \
            attempt=$((attempt + 1)); \
            [ "${attempt}" -le "${RETRY}" ] && sleep "${RETRY_DELAY}"; \
        done; \
        return 1; \
    }; \
    save_zix "https://codeberg.org/prothegee/zix/archive" \
    || { echo "zix: codeberg exhausted ${RETRY} attempts, trying github" >&2; \
         save_zix "https://github.com/prothegee/zix/archive/refs/heads"; } \
    || { echo "zix: github exhausted ${RETRY} attempts" >&2; exit 1; }; \
    rm -f build.zig.zon.tmpl; \
    case "${TARGETARCH:-amd64}" in \
        amd64) ZIG_TARGET=x86_64-linux-musl; ZIG_CPU=x86_64_v3 ;; \
        arm64) ZIG_TARGET=aarch64-linux-musl; ZIG_CPU=baseline ;; \
    esac; \
    zig build -Dtarget="${ZIG_TARGET}" -Dcpu="${ZIG_CPU}+aes+pclmul" --release=fast

# Self-signed Ed25519 cert for the QUIC handshake, baked at /etc/zix-h3. The v1 QUIC handshake flight
# is a single packet an RSA-2048 cert would overflow, so a small key is required. Nothing in the
# harness verifies the certificate.
RUN set -eu; \
    mkdir -p /etc/zix-h3; \
    openssl genpkey -algorithm ED25519 -out /etc/zix-h3/server.key; \
    openssl req -new -x509 -key /etc/zix-h3/server.key -out /etc/zix-h3/server.crt \
        -days 3650 -subj "/CN=localhost"

FROM alpine:3.20
COPY --from=build /src/zig-out/bin/zix-http3 /zix-http3
COPY --from=build /etc/zix-h3 /etc/zix-h3
EXPOSE 8443/tcp 8443/udp
ENTRYPOINT ["/zix-http3"]
