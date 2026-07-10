# syntax=docker/dockerfile:1.7

FROM alpine:3.20 AS build
ARG RETRY=6
ARG TARGETARCH
ARG RETRY_DELAY=3
ARG TIMEOUT_SEC=180
ARG ZIG_VERSION=0.16.0
ARG ZIX_VERSION=0.5.x-rc1
RUN apk add --no-cache ca-certificates curl git tar xz openssl

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

WORKDIR /server
COPY build.zig build.zig.zon ./
COPY src ./src

# Vendor zix ${ZIX_VERSION} in its own layer so source-only rebuilds skip the fetch.
# Tries curl tarball then git clone, github before codeberg.
# RETRY / RETRY_DELAY bound every attempt.
RUN set -eu; \
    fetch() { \
        rm -rf /server/vendor/zix; mkdir -p /server/vendor/zix; \
        curl -fSL --retry ${RETRY} --retry-delay ${RETRY_DELAY} --retry-all-errors "$1" -o /tmp/zix.tar.gz \
            && tar -xz --strip-components=1 -C /server/vendor/zix -f /tmp/zix.tar.gz; \
    }; \
    clone() { \
        attempt=0; \
        while [ "${attempt}" -lt "${RETRY}" ]; do \
            rm -rf /server/vendor/zix; \
            git clone --depth 1 --branch "${ZIX_VERSION}" "$1" /server/vendor/zix && return 0; \
            attempt=$((attempt + 1)); \
            sleep "${RETRY_DELAY}"; \
        done; \
        return 1; \
    }; \
    fetch "https://github.com/prothegee/zix/archive/refs/heads/${ZIX_VERSION}.tar.gz" \
    || { echo "FAILED: curl ${RETRY} times from github" >&2; \
        fetch "https://codeberg.org/prothegee/zix/archive/${ZIX_VERSION}.tar.gz" \
    || { echo "FAILED: curl ${RETRY} times from codeberg" >&2; \
        clone "https://github.com/prothegee/zix.git" \
    || { echo "FAILED: git clone ${RETRY} times from github" >&2; \
        clone "https://codeberg.org/prothegee/zix.git" \
    || { echo "FAILED: git clone ${RETRY} times from codeberg" >&2; exit 1; }; }; }; }

# Add +aes+pclmul: x86_64_v3 omits AES-NI / PCLMUL,
# so zix TLS would compile the ~40x slower software AES-GCM.
# Every x86_64_v3 CPU has them, so it is safe.
RUN set -eu; \
    case "${TARGETARCH:-amd64}" in \
        amd64) ZIG_TARGET=x86_64-linux-musl; ZIG_CPU=x86_64_v3 ;; \
        arm64) ZIG_TARGET=aarch64-linux-musl; ZIG_CPU=baseline ;; \
    esac; \
    zig build -Dtarget="${ZIG_TARGET}" -Dcpu="${ZIG_CPU}+aes+pclmul+adx" --release=fast

# Self-signed Ed25519 cert generated at image build, baked at /etc/zix-tls.
RUN set -eu; \
    mkdir -p /etc/zix-tls; \
    openssl genpkey -algorithm ED25519 -out /etc/zix-tls/server.key; \
    openssl req -new -x509 -key /etc/zix-tls/server.key -out /etc/zix-tls/server.crt \
        -days 3650 -subj "/CN=localhost"

FROM alpine:3.20
COPY --from=build /server/zig-out/bin/zix-grpc /zix-grpc
COPY --from=build /etc/zix-tls /etc/zix-tls
EXPOSE 8080 8443/tcp
ENTRYPOINT ["/zix-grpc"]
