FROM ubuntu:24.04 AS build

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential autoconf automake libtool libltdl-dev pkg-config \
        git ca-certificates \
        liburing-dev libssl-dev \
    && rm -rf /var/lib/apt/lists/*

# Build libreactorng from source, pinned to a commit. A small patch adds a graceful close-on-drain
# to libreactor's stream so the server can honor `Connection: close` without the abortive
# stream_close truncating the response (upstream keeps connections open unconditionally).
ARG LIBREACTORNG_VERSION=7a65f8b108f62f2531db952b0f87cf5f34a24b3c
COPY connection-close.patch /tmp/connection-close.patch
WORKDIR /tmp/libreactorng
RUN git clone https://github.com/fredrikwidlund/libreactorng.git . \
    && git checkout "${LIBREACTORNG_VERSION}" \
    && git apply /tmp/connection-close.patch \
    && ./autogen.sh \
    && ./configure CFLAGS="-O3 -march=native" \
    && make -j"$(nproc)" \
    && make install \
    && ldconfig

# Build the bench server against the patched libreactor.
WORKDIR /app
COPY src/server.c .
RUN gcc -O3 -march=native -Wall -Wextra -o server server.c \
        $(pkg-config --libs --cflags libreactor)

FROM ubuntu:24.04
RUN apt-get update && apt-get install -y --no-install-recommends \
        liburing2 libssl3 libltdl7 ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /usr/local/lib/libreactor* /usr/local/lib/
COPY --from=build /app/server /server
RUN ldconfig
EXPOSE 8080
CMD ["/server"]
