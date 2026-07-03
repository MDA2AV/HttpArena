FROM debian:stable-slim AS build

RUN apt-get -qq update && \
    apt-get -qy install --no-install-recommends \
        ca-certificates build-essential git libpq-dev liburing-dev \
        cmake curl bzip2 python3 && \
    rm -rf /var/lib/apt/lists/*

# Pinned, reproducible V at master commit 02015a7c (built from source). Moved off
# the 0.5.1 tag: the codegen regression that forced the pin (single-element array
# push 4-7x slower, vlang/v#27468) is fixed (vlang/v#27470), and the vanilla library
# now uses `ArrayFlags.managed` (the buf_view non-marking window) which only exists
# on post-0.5.1 V. `make` bootstraps via the matching vc; if a much later rebuild
# ever fails to bootstrap, pin vlang/vc to the commit cut for this V.
RUN git clone https://github.com/vlang/v /opt/v && \
    cd /opt/v && git checkout 02015a7ce111e4d0cfd5b5d78711ad0db7586936 && \
    make && ln -s /opt/v/v /usr/local/bin/v

# Install the vanilla HTTP server as the `vanilla` module (import vanilla.http_server),
# pinned to a specific commit: reproducible, and with NO per-build network call to
# detect changes. The previous approach `ADD`ed the GitHub API main-ref URL to cache-bust
# whenever main moved, but that hit api.github.com on every build and a transient 504
# (or rate-limit) failed the whole build (MDA2AV/HttpArena#895). To pick up upstream
# library fixes, bump this commit.
#
# Pinned to vanilla main @b189036 — the lib-wide alloc audit (#72 pg_async, #73
# static_assets, #74 TLS buffer pooling), kTLS record offload for json-tls
# (enghitalo/vanilla#79; after the Mbed TLS handshake the kernel does TLS 1.3 record
# AES-128-GCM via setsockopt TLS_TX+TLS_RX, so the epoll worker's steady-state
# read/write are plain recv/send), PLUS static_assets `url_prefix` (#80) and
# core.queue_buf borrowed send (#81) — this entry serves /static/* through the
# audited static_assets module (precompressed .br/.gz negotiation + ETag/Vary,
# sendfile for the large siblings) instead of a hand-rolled identity-only map.
RUN git clone https://github.com/enghitalo/vanilla /root/.vmodules/vanilla && \
    git -C /root/.vmodules/vanilla checkout b189036212e4283ef2cffe42b318b556f8a3d1bc

# Mbed TLS 4 for the json-tls profile. The vanilla `tls` module's C shim
# (vanilla_tls.c, built with `-d vanilla_tls`) targets the Mbed TLS 4.x API
# (PSA, TLS 1.3); Debian apt only ships 2.28, which is ABI/API-incompatible, so
# build 4.x from the version-pinned release tarball (self-contained — needs no
# Python framework) as SHARED libs into /usr/local, matching the #flag in
# tls_mbedtls_d_vanilla_tls.c.v (-L/usr/local/lib -lmbedtls -lmbedx509
# -lmbedcrypto). 4.x also produces libtfpsacrypto (the TF-PSA-Crypto split),
# linked transitively. Headers land in /usr/local/include for the build.
ARG MBEDTLS_VERSION=4.1.0
RUN curl -fsSL -o /tmp/mbedtls.tar.bz2 \
        "https://github.com/Mbed-TLS/mbedtls/releases/download/mbedtls-${MBEDTLS_VERSION}/mbedtls-${MBEDTLS_VERSION}.tar.bz2" && \
    tar -xf /tmp/mbedtls.tar.bz2 -C /tmp && \
    cd "/tmp/mbedtls-${MBEDTLS_VERSION}" && \
    # THREAD-SAFETY (load-bearing): vanilla runs N TLS worker threads, each driving
    # TLS 1.3 handshakes through Mbed TLS's PSA crypto, whose key store is a GLOBAL,
    # process-wide table. Without MBEDTLS_THREADING_C the concurrent handshakes race
    # on the key slots — a heap-use-after-free under load (confirmed with ASan:
    # psa_wipe_key_slot on one thread frees a slot another thread is mid-memcpy in
    # psa_hmac_setup; crashes ~c1024 with "double free or corruption"). THREADING_C +
    # THREADING_PTHREAD guard the key store with a pthread mutex. In 4.x the crypto
    # (and so its config) lives in the tf-psa-crypto submodule.
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
# -d vanilla_tls compiles the real Mbed TLS backend (the json-tls listener on
# :8081); without it the tls module is a stub and the binary stays mbedtls-free.
RUN v -prod -gc none -d vanilla_tls . -o server

FROM debian:stable-slim
RUN apt-get -qq update && \
    apt-get -qy install --no-install-recommends libpq5 liburing2 && \
    rm -rf /var/lib/apt/lists/*
# Mbed TLS 4 shared libs for the json-tls endpoint (libmbedcrypto pulls in
# libtfpsacrypto transitively). ldconfig so the loader resolves them with no
# LD_LIBRARY_PATH. Plain-HTTP builds don't link mbedtls, but this image always
# enables -d vanilla_tls, so the runtime needs them.
COPY --from=build /usr/local/lib/libmbedcrypto.so* /usr/local/lib/libmbedx509.so* /usr/local/lib/libmbedtls.so* /usr/local/lib/libtfpsacrypto.so* /usr/local/lib/
RUN ldconfig
COPY --from=build /app/server /server

# 8080 = plaintext HTTP; 8081 = json-tls (HTTP/1.1 over TLS). The harness
# bind-mounts the cert/key at /certs and the server reads /certs/server.{crt,key}
# (override via TLS_CERT/TLS_KEY); with no cert mounted it self-signs.
EXPOSE 8080 8081
CMD ["/server"]
