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
# Pinned to vanilla main @be46940 — carries enghitalo/vanilla#99 (async runtime for
# the io_uring backend via oneshot IORING_OP_POLL_ADD), which this entry needs, and
# #101 (epoll async-runtime hardening — resume drains buffered pipelined requests,
# inline queue-drain deactivation, watch-then-reject teardown; the json-tls listener
# here runs on the epoll backend, stateless, so #101 is inert for this entry but keeps
# both entries on ONE lib SHA): main.v is now the vanilla-epoll entry's async_handler + pg_async code
# verbatim (DB queries PARK on the PG socket instead of blocking the ring worker —
# enghitalo/vanilla#83); an older pin REJECTS async_handler on io_uring at new_server()
# and panics on boot. Also carries #94 (make_state on io_uring), #96 (epoll TLS stateful
# fix), the lib-wide alloc audit (#72/#73/#74) and kTLS record offload (#79). The
# io_uring backend has no TLS, so the json-tls listener runs on the lib's epoll backend
# on :8081 (see main.v).
RUN git clone https://github.com/enghitalo/vanilla /root/.vmodules/vanilla && \
    git -C /root/.vmodules/vanilla checkout be46940b624363ed93991d3166f950143ee14c7b

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
# Default GC (NOT -gc none) for now: the handler code is the epoll twin's -gc none-
# audited code, but this entry flips one variable per benchmark round — the async DB
# runtime lands here; the -gc none switch is a measured follow-up. -d vanilla_tls
# compiles the real Mbed TLS backend for the json-tls listener (without it the tls
# module is a stub and mbedtls isn't linked).
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
