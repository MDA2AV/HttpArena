FROM debian:stable-slim AS build

RUN apt-get -qq update && \
    apt-get -qy install --no-install-recommends \
        ca-certificates build-essential git libpq-dev liburing-dev \
        cmake curl bzip2 python3 && \
    rm -rf /var/lib/apt/lists/*

# Pinned, reproducible V at master commit 02015a7c (built from source). Master is
# now preferred over the 0.5.1 tag: the codegen regression that forced 0.5.1 (single-
# element array push 4-7x slower, vlang/v#27468) is fixed (vlang/v#27470), and the
# code uses the modern pooled Go-style db.pg (vlang/v#27265). 02015a7c descends from
# cef604a26, so it keeps the Boehm GC free-space-divisor fix (vlang/v#27560, fixes
# vlang/v#27555) that recovers the default-GC throughput regression seen in the
# c0624b2..6c4d26f range (verified ancestor; the c..02015a7c range adds no GC change).
# For a current master commit, `make` bootstraps via the matching vc; if a much later
# rebuild ever fails to bootstrap, pin vlang/vc to the commit cut for this V.
RUN git clone https://github.com/vlang/v /opt/v && \
    cd /opt/v && git checkout 02015a7ce111e4d0cfd5b5d78711ad0db7586936 && \
    make && ln -s /opt/v/v /usr/local/bin/v

# Install the vanilla HTTP server as the `vanilla` module (import vanilla.http_server),
# pinned to a specific commit: reproducible, with NO per-build network call to detect
# changes. The previous approach `ADD`ed the GitHub API main-ref URL to cache-bust when
# main moved, but that hit api.github.com every build and a transient 504/rate-limit
# failed the whole build (MDA2AV/HttpArena#895). Bump this commit to pick up lib fixes.
#
# Pinned to vanilla main @b189036 — the lib-wide alloc audit (#72 pg_async, #73
# static_assets, #74 TLS buffer pooling) PLUS kTLS record offload (enghitalo/vanilla#79,
# ancestor 5137a9a). The io_uring backend has no TLS, so the json-tls listener runs on
# the lib's epoll backend on :8081 (see main.v); kTLS makes its steady-state read/write
# plain recv/send with the kernel doing AES-128-GCM. pg_async#72 touches this backend's
# async-DB row-decode hot path.
RUN git clone https://github.com/enghitalo/vanilla /root/.vmodules/vanilla && \
    git -C /root/.vmodules/vanilla checkout b189036212e4283ef2cffe42b318b556f8a3d1bc

# Mbed TLS 4 for the json-tls profile (the epoll TLS listener on :8081). The vanilla
# `tls` C shim (built with -d vanilla_tls) targets the Mbed TLS 4.x API; Debian apt
# ships only 2.28 (ABI-incompatible), so build 4.x from the version-pinned release
# tarball into /usr/local. THREAD-SAFETY: enable MBEDTLS_THREADING_C +
# MBEDTLS_THREADING_PTHREAD — the TLS workers share Mbed TLS's global PSA key store,
# which races (heap-use-after-free) under concurrent handshakes without the mutex.
ARG MBEDTLS_VERSION=4.1.0
RUN curl -fsSL -o /tmp/mbedtls.tar.bz2 \
        "https://github.com/Mbed-TLS/mbedtls/releases/download/mbedtls-${MBEDTLS_VERSION}/mbedtls-${MBEDTLS_VERSION}.tar.bz2" && \
    tar -xf /tmp/mbedtls.tar.bz2 -C /tmp && \
    cd "/tmp/mbedtls-${MBEDTLS_VERSION}" && \
    python3 tf-psa-crypto/scripts/config.py set MBEDTLS_THREADING_C && \
    python3 tf-psa-crypto/scripts/config.py set MBEDTLS_THREADING_PTHREAD && \
    cmake -S "/tmp/mbedtls-${MBEDTLS_VERSION}" -B /tmp/mbedtls-build \
        -DCMAKE_BUILD_TYPE=Release \
        -DUSE_SHARED_MBEDTLS_LIBRARY=On -DUSE_STATIC_MBEDTLS_LIBRARY=Off \
        -DENABLE_TESTING=Off -DENABLE_PROGRAMS=Off \
        -DCMAKE_INSTALL_PREFIX=/usr/local && \
    cmake --build /tmp/mbedtls-build -j"$(nproc)" && \
    cmake --install /tmp/mbedtls-build && ldconfig && \
    rm -rf /tmp/mbedtls.tar.bz2 "/tmp/mbedtls-${MBEDTLS_VERSION}" /tmp/mbedtls-build

WORKDIR /app
COPY . .
# Default GC (NOT -gc none, NOT -prealloc): this runs on the vanilla HTTP server's own
# manual buffer management. -d vanilla_tls compiles the real Mbed TLS backend for the
# json-tls listener (without it the tls module is a stub and mbedtls isn't linked).
RUN v -prod -d vanilla_tls . -o server

FROM debian:stable-slim
RUN apt-get -qq update && \
    apt-get -qy install --no-install-recommends libpq5 liburing2 && \
    rm -rf /var/lib/apt/lists/*
# Mbed TLS 4 shared libs for the json-tls (epoll) listener (libmbedcrypto pulls in
# libtfpsacrypto transitively). ldconfig so the loader resolves them with no
# LD_LIBRARY_PATH.
COPY --from=build /usr/local/lib/libmbedcrypto.so* /usr/local/lib/libmbedx509.so* /usr/local/lib/libmbedtls.so* /usr/local/lib/libtfpsacrypto.so* /usr/local/lib/
RUN ldconfig
COPY --from=build /app/server /server

# 8080 = io_uring HTTP (non-TLS profiles); 8081 = json-tls (HTTP/1.1 over TLS, epoll
# backend). The harness bind-mounts the cert/key at /certs (override via
# TLS_CERT/TLS_KEY); with no cert mounted the server self-signs.
EXPOSE 8080 8081
CMD ["/server"]
