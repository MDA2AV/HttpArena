FROM debian:stable-slim AS build

RUN apt-get -qq update && \
    apt-get -qy install --no-install-recommends \
        ca-certificates build-essential git libpq-dev liburing-dev \
        cmake curl bzip2 python3 && \
    rm -rf /var/lib/apt/lists/*

# Pinned, reproducible V at master commit b99970bd (0.5.2, built from source). The
# removed `json` module is replaced by x.json2 in main.v (encode with
# escape_unicode, so the /json bodies stay byte-identical).
#
# The bootstrap is pinned too. A bare `make` clones vlang/vc and vlang/tccbin at
# their CURRENT heads, so a fixed V source gets built by whatever compiler vc
# holds that day: that is what broke every V entry in #1288 ("C function C.open
# was already declared with a different signature"), and vc head has since
# failed in other ways. vc 2cbaf6bc is vc's newest snapshot (generated from V
# 0c41fadb, 40 commits earlier; vc has none for b99970bd yet), so it is what
# `make` bootstraps this V with today; tccbin d6e7ac1b is the head of tccbin's
# thirdparty-linux-amd64 branch, and `local=1` makes `make` build with both
# instead of pulling.
#
# Each repo is fetched at its one pinned commit (depth 1) rather than cloned:
# a full clone of v, vc and tccbin is hundreds of MB and a slow or flaky link
# stalls it past the validator's timeout; this is ~30 MB.
RUN git init -q /opt/v && cd /opt/v && \
    git fetch -q --depth 1 https://github.com/vlang/v b99970bd438a7bdcdfbe38f74d9364db801d5439 && \
    git checkout -q FETCH_HEAD && \
    git init -q vc && \
    git -C vc fetch -q --depth 1 https://github.com/vlang/vc 2cbaf6bc2367937cd5f0b4ef923d1ef9aad613b3 && \
    git -C vc checkout -q FETCH_HEAD && \
    git init -q thirdparty/tcc && \
    git -C thirdparty/tcc fetch -q --depth 1 https://github.com/vlang/tccbin d6e7ac1b1bcc98aed734a6ecbfa8509f24606c74 && \
    git -C thirdparty/tcc checkout -q FETCH_HEAD && \
    make local=1 && ln -s /opt/v/v /usr/local/bin/v

# Install vanilla as the `vanilla` module (import vanilla.server, vanilla.core, ...),
# pinned to a specific commit: reproducible, with NO per-build network call to
# detect changes. The previous approach `ADD`ed the GitHub API main-ref URL to
# cache-bust whenever main moved, but that hit api.github.com on every build and a
# transient 504 (or rate-limit) failed the whole build (MDA2AV/HttpArena#895). To
# pick up upstream library fixes, bump this commit.
#
# Pinned to vanilla main @091c014: top-level modules and one handler contract
# (core.Handler returning core.Step, watches through core.EventLoop), which main.v
# uses for both listeners. /static/* goes through the static_assets module on both:
# precompressed .br/.gz negotiation + ETag/Vary, snapshots that follow the disk
# (enghitalo/vanilla#180), and sendfile for bodies of 16 KiB or more, on :8080 and,
# over kTLS, on the :8081 TLS listener (enghitalo/vanilla#181; a userspace-TLS
# connection gets the bytes from RAM). Fetched at that one commit.
RUN git init -q /root/.vmodules/vanilla && \
    git -C /root/.vmodules/vanilla fetch -q --depth 1 https://github.com/enghitalo/vanilla \
        091c014a0191afd7e740b84f5599b9b1fc1fd914 && \
    git -C /root/.vmodules/vanilla checkout -q FETCH_HEAD

# Mbed TLS 4 for the json-tls profile. The vanilla `tls` module's C shim
# (vanilla_tls.c, built with `-d vanilla_tls`) targets the Mbed TLS 4.x API
# (PSA, TLS 1.3); Debian apt only ships 2.28, which is ABI/API-incompatible, so
# build 4.x from the version-pinned release tarball (self-contained — needs no
# Python framework) as SHARED libs into /usr/local, matching the #flag in
# tls_mbedtls_d_vanilla_tls.c.v (-L/usr/local/lib -lmbedtls -lmbedx509
# -lmbedcrypto). 4.x also produces libtfpsacrypto (the TF-PSA-Crypto split),
# linked transitively. Headers land in /usr/local/include for the build.
#
# mbedtls-rsa-sign-cache.patch (against 4.1.0): unpatched, every PSA RSA
# signature re-parses the key and regenerates the RSA blinding values from
# scratch, which was most of each TLS 1.3 handshake with the harness's
# RSA-2048 certificate (~11 ms of CPU). The patch keeps the signing key's
# parsed context in a per-thread cache, so blinding is updated by squaring
# as with any long-lived mbedtls_rsa_context; with -O3 -march=native a
# handshake costs ~8 ms. That is what 8gbit (512 fresh connections) and
# json-tls (4096) pay up front before the first request is answered.
ARG MBEDTLS_VERSION=4.1.0
COPY mbedtls-rsa-sign-cache.patch /tmp/
RUN curl -fsSL -o /tmp/mbedtls.tar.bz2 \
        "https://github.com/Mbed-TLS/mbedtls/releases/download/mbedtls-${MBEDTLS_VERSION}/mbedtls-${MBEDTLS_VERSION}.tar.bz2" && \
    tar -xf /tmp/mbedtls.tar.bz2 -C /tmp && \
    cd "/tmp/mbedtls-${MBEDTLS_VERSION}" && \
    patch -p1 < /tmp/mbedtls-rsa-sign-cache.patch && \
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
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_FLAGS_RELEASE="-O3 -march=native -DNDEBUG" \
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
# One worker per CPU the container may run on. vanilla defaults to nr_cpus,
# which reads the host's online CPUs (128 on the bench box) and ignores the
# cpuset, so a 64-CPU profile started 128 workers and latency-500k-8cpu would
# start 128 on 8. nproc honours the cpuset; an explicit VANILLA_WORKERS wins.
CMD ["/bin/sh", "-c", "VANILLA_WORKERS=${VANILLA_WORKERS:-$(nproc)} exec /server"]
