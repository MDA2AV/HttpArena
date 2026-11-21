FROM ubuntu:24.04 AS build
ARG GCANNON_REF=main
# CACHE_BUST is set to the current timestamp by the benchmark script so
# docker always pulls the latest gcannon source instead of reusing a
# stale git-clone layer. Without this, edits pushed to the gcannon repo
# are invisible until the user manually runs --no-cache.
ARG CACHE_BUST=0
# libssl-dev: gcannon 0.7.0 and later do the TLS handshake with OpenSSL (the
# runtime image's libssl3 serves the binary), and fail to build without it.
RUN apt-get update && apt-get install -y --no-install-recommends \
        gcc libc6-dev make git ca-certificates libssl-dev && rm -rf /var/lib/apt/lists/*
WORKDIR /deps
RUN git clone --branch liburing-2.9 --depth 1 https://github.com/axboe/liburing.git && \
    cd liburing && ./configure --prefix=/usr && make -j"$(nproc)" -C src && make install -C src
WORKDIR /build
RUN echo "cache_bust=$CACHE_BUST" && \
    git clone https://github.com/MDA2AV/gcannon . && \
    git checkout "$GCANNON_REF" && \
    make clean && make -j"$(nproc)"

FROM ubuntu:24.04
COPY --from=build /usr/lib/liburing.so.2.9 /usr/lib/liburing.so.2.9
RUN ln -s liburing.so.2.9 /usr/lib/liburing.so.2 && ln -s liburing.so.2 /usr/lib/liburing.so && \
    ldconfig
COPY --from=build /build/gcannon /usr/local/bin/gcannon
ENTRYPOINT ["gcannon"]
