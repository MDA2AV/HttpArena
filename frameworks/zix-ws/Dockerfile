# syntax=docker/dockerfile:1.7

FROM alpine:3.20 AS build
ARG RETRY=6
ARG TARGETARCH
ARG RETRY_DELAY=3
ARG TIMEOUT_SEC=180
ARG ZIG_VERSION=0.16.0
ARG ZIX_VERSION=0.5.x
RUN apk add --no-cache ca-certificates curl git tar xz openssl

WORKDIR /server
RUN set -eu; \
    case "${TARGETARCH:-amd64}" in \
        amd64) ZIG_ARCH=x86_64 ;; \
        arm64) ZIG_ARCH=aarch64 ;; \
        *) echo "unsupported arch: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fSL -m ${TIMEOUT_SEC} "https://ziglang.org/download/${ZIG_VERSION}/zig-${ZIG_ARCH}-linux-${ZIG_VERSION}.tar.xz" \
        | tar -xJ -C /opt; \
    mv "/opt/zig-${ZIG_ARCH}-linux-${ZIG_VERSION}" /opt/zig
ENV PATH="/opt/zig:${PATH}"

COPY build.zig ./
COPY build.zig.zon.template ./build.zig.zon
COPY src ./src

# Resolve zix with zig fetch git+https
RUN set -eu; \
    fetch_zix() { \
        url="$1"; attempt=1; \
        while [ "${attempt}" -le "${RETRY}" ]; do \
            if $(zig fetch --save ${url}); then \
                return 0; \
            fi; \
            echo "zix: ${url} attempt ${attempt}/${RETRY} failed" >&2; \
            attempt=$((attempt + 1)); \
            [ "${attempt}" -le "${RETRY}" ] && sleep "${RETRY_DELAY}"; \
        done; \
        return 1; \
    }; \
    fetch_zix "git+https://codeberg.org/prothegee/zix#${ZIX_VERSION}" \
        || { echo "zix: codeberg exhausted ${RETRY} attempts" >&2; \
    fetch_zix "git+https://github.com/prothegee/zix#${ZIX_VERSION}"; } \
        || { echo "zix: github exhausted ${RETRY} attempts" >&2; exit 1; }

# +aes+pclmul: x86_64_v3 omits AES-NI / PCLMUL,
# so zix TLS would compile the ~40x slower software AES-GCM.
# +adx speeds the RSA / Montgomery path. Every x86_64_v3 CPU has them, so it is safe.
RUN set -eu; \
    case "${TARGETARCH:-amd64}" in \
        amd64) ZIG_TARGET=x86_64-linux-musl; ZIG_CPU=x86_64_v3 ;; \
        arm64) ZIG_TARGET=aarch64-linux-musl; ZIG_CPU=baseline ;; \
    esac; \
    zig build \
    -Dtarget="${ZIG_TARGET}" \
    -Dcpu="${ZIG_CPU}+aes+pclmul+adx" \
    --release=fast --summary failures;

# Self-signed Ed25519 cert generated at image build, baked at /etc/zix-tls.
RUN set -eu; \
    mkdir -p /etc/zix-tls; \
    openssl genpkey -algorithm ED25519 -out /etc/zix-tls/server.key; \
    openssl req -new -x509 -key /etc/zix-tls/server.key -out /etc/zix-tls/server.cert \
        -days 3650 -subj "/CN=localhost"

FROM alpine:3.20
COPY --from=build /server/zig-out/bin/zix-ws /zix-ws
EXPOSE 8080
ENTRYPOINT ["/zix-ws"]
