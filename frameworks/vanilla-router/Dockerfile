FROM debian:stable-slim AS build

RUN apt-get -qq update && \
    apt-get -qy install --no-install-recommends \
        ca-certificates build-essential git libdeflate-dev \
        cmake curl bzip2 python3 && \
    rm -rf /var/lib/apt/lists/*

# V master 5516000 (0.5.2), built from source with a pinned bootstrap: vc
# 104d76c3 is vc's snapshot generated from that same V commit, and tccbin
# d6e7ac1b is the head of its thirdparty-linux-amd64 branch. `local=1` makes
# `make` build with both instead of pulling vc and tccbin at their current
# heads. Each repo is fetched at its one commit (depth 1).
RUN git init -q /opt/v && cd /opt/v && \
    git fetch -q --depth 1 https://github.com/vlang/v 5516000ece06706b1c3a7ef9a1262fe8215383a8 && \
    git checkout -q FETCH_HEAD && \
    git init -q vc && \
    git -C vc fetch -q --depth 1 https://github.com/vlang/vc 104d76c331dfb56410e2b75bda53130f045c4b7f && \
    git -C vc checkout -q FETCH_HEAD && \
    git init -q thirdparty/tcc && \
    git -C thirdparty/tcc fetch -q --depth 1 https://github.com/vlang/tccbin d6e7ac1b1bcc98aed734a6ecbfa8509f24606c74 && \
    git -C thirdparty/tcc checkout -q FETCH_HEAD && \
    make local=1 && ln -s /opt/v/v /usr/local/bin/v

# vanilla as the `vanilla` module, pinned to main @fb4c7e7 (the first commit
# with both routers, http1_1.router and http1_1.veb_like).
RUN git init -q /root/.vmodules/vanilla && \
    git -C /root/.vmodules/vanilla fetch -q --depth 1 https://github.com/enghitalo/vanilla \
        fb4c7e7a3f6a796342a7aa0ea29e816cf4e7a92f && \
    git -C /root/.vmodules/vanilla checkout -q FETCH_HEAD

# Mbed TLS 4 for the :8081 listener (json-tls, static-tls, 8gbit), as in
# vanilla-epoll: vanilla's tls module targets the 4.x API (PSA, TLS 1.3) and
# Debian ships 2.28, so build the release tarball as shared libraries.
# mbedtls-rsa-sign-cache.patch keeps the signing key's parsed RSA context per
# thread, so a TLS 1.3 handshake with the harness's RSA-2048 certificate does
# not re-parse the key and regenerate its blinding values every time.
# MBEDTLS_THREADING_C guards PSA's process-wide key store: the TLS workers run
# handshakes concurrently.
ARG MBEDTLS_VERSION=4.1.0
COPY mbedtls-rsa-sign-cache.patch /tmp/
RUN curl -fsSL -o /tmp/mbedtls.tar.bz2 \
        "https://github.com/Mbed-TLS/mbedtls/releases/download/mbedtls-${MBEDTLS_VERSION}/mbedtls-${MBEDTLS_VERSION}.tar.bz2" && \
    tar -xf /tmp/mbedtls.tar.bz2 -C /tmp && \
    cd "/tmp/mbedtls-${MBEDTLS_VERSION}" && \
    patch -p1 < /tmp/mbedtls-rsa-sign-cache.patch && \
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
COPY app.v main.v ./
# -gc none is vanilla's production build (nothing is allocated per request);
# -d vanilla_tls compiles the Mbed TLS backend of the tls module.
RUN v -prod -gc none -d vanilla_tls . -o server

FROM debian:stable-slim
RUN apt-get -qq update && \
    apt-get -qy install --no-install-recommends libdeflate0 && \
    rm -rf /var/lib/apt/lists/*
COPY --from=build /usr/local/lib/libmbedcrypto.so* /usr/local/lib/libmbedx509.so* /usr/local/lib/libmbedtls.so* /usr/local/lib/libtfpsacrypto.so* /usr/local/lib/
RUN ldconfig
COPY --from=build /app/server /server

# 8080: HTTP/1.1. 8081: HTTP/1.1 over TLS, with the certificate the harness
# mounts at /certs (TLS_CERT/TLS_KEY override the paths).
EXPOSE 8080 8081
# One worker per CPU of the container's cpuset: vanilla's default reads the
# host's online CPUs, which ignores the cpuset. VANILLA_WORKERS wins if set.
CMD ["/bin/sh", "-c", "VANILLA_WORKERS=${VANILLA_WORKERS:-$(nproc)} exec /server"]
