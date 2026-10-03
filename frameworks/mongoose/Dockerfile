FROM ubuntu:24.04 AS build
RUN apt-get update && apt-get install -y --no-install-recommends \
        gcc-14 curl ca-certificates libc6-dev libssl-dev \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app

# Mongoose ships as a two-file amalgamation, so the "library build" is just
# compiling mongoose.c next to the handlers. Pinned to the 7.23 tag: the
# entry's numbers belong to a version, not to whatever master happens to be.
ARG MONGOOSE_VERSION=7.23
RUN curl -LSs "https://github.com/cesanta/mongoose/archive/refs/tags/${MONGOOSE_VERSION}.tar.gz" \
      | tar --strip-components=1 -xz -C /app mongoose-${MONGOOSE_VERSION}/mongoose.c \
                                             mongoose-${MONGOOSE_VERSION}/mongoose.h

COPY main.c .

# MG_TLS_OPENSSL rather than mongoose's built-in TLS: the harness mounts an
# RSA-2048 certificate and every handshake is signed with it, so the entry has
# to use a stack that does RSA with the CPU's AES-NI behind it.
#
# MG_ENABLE_LOG=0 removes the log-level call that MG_VERBOSE otherwise makes
# once per connection per poll iteration. Build with --build-arg MG_LOG=1 to
# get mongoose's own diagnostics back.
ARG MG_LOG=0
RUN gcc-14 -O3 -march=native -flto -std=gnu11 -Wall -Wextra \
        -DMG_ARCH=MG_ARCH_UNIX \
        -DMG_TLS=MG_TLS_OPENSSL \
        -DMG_ENABLE_EPOLL=1 \
        -DMG_ENABLE_DIRLIST=0 \
        -DMG_ENABLE_LOG=${MG_LOG} \
        main.c mongoose.c -o server -lssl -lcrypto -ldl

FROM ubuntu:24.04
RUN apt-get update && apt-get install -y --no-install-recommends \
        libssl3t64 ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /app/server /server
EXPOSE 8080 8081
CMD ["/server"]
