# syntax=docker/dockerfile:1.7

FROM alpine:3.20 AS build
ARG RETRY=6
ARG TARGETARCH
ARG RETRY_DELAY=3
ARG ZIG_VERSION=0.16.0
ARG ZIX_VERSION=0.4.x-rc2
RUN apk add --no-cache ca-certificates curl git tar xz

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

# Vendor zix 0.4.x-rc2, separate layer so source-only rebuilds skip the fetch.
# The Http1 raw engine work this image needs (large-body drain plus the per-worker
# response cache used by the /json endpoint) must be present on the 0.4.x-rc2 branch.
# Four ordered attempts before giving up: curl the archive tarball from github then
# codeberg, then a shallow git clone from github then codeberg. The github archive
# redirects to codeload.github.com (which the benchmark runner may not resolve), so
# curl can fall through to the codeberg tarball, and git clone talks to github.com
# and codeberg.org directly as the deeper fallback. RETRY and RETRY_DELAY bound
# every attempt.
RUN set -eu; \
    fetch() { \
        rm -rf /src/vendor/zix; mkdir -p /src/vendor/zix; \
        curl -fsSL --retry ${RETRY} --retry-delay ${RETRY_DELAY} --retry-all-errors "$1" -o /tmp/zix.tar.gz \
            && tar -xz --strip-components=1 -C /src/vendor/zix -f /tmp/zix.tar.gz; \
    }; \
    clone() { \
        attempt=0; \
        while [ "${attempt}" -lt "${RETRY}" ]; do \
            rm -rf /src/vendor/zix; \
            git clone --depth 1 --branch "${ZIX_VERSION}" "$1" /src/vendor/zix && return 0; \
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
COPY --from=build /src/zig-out/bin/zix /zix
EXPOSE 8080
ENTRYPOINT ["/zix"]
