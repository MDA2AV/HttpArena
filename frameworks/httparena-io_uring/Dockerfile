FROM ubuntu:24.04 AS build
RUN apt-get update && apt-get install -y --no-install-recommends \
        gcc-14 make curl ca-certificates libc6-dev libssl-dev libcjson-dev libbrotli-dev zlib1g-dev pkg-config \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app

# Build libioxd from its own repo, pinned to a commit (the h2o pattern: fetch upstream at a fixed
# SHA and build it here, tuned for this CPU). No liburing: libioxd issues the io_uring syscalls
# directly; OpenSSL does the TLS handshake and the kernel the records (kTLS). Only the handlers
# live in this entry. Fat LTO objects for the library and -flto on the handler link, so the
# handlers inline into the engine. cJSON parses the dataset once at startup; brotli and zlib are
# the codings of the library's compression middleware (json-comp).
ARG LIBIOXD_VERSION=3e435f30b6d75b98586ea9e4d35be8c7b75ad6ec
RUN mkdir -p /tmp/libioxd && \
    curl -LSs "https://github.com/MDA2AV/libioxd/archive/${LIBIOXD_VERSION}.tar.gz" \
      | tar --strip-components=1 -xz -C /tmp/libioxd && \
    make -C /tmp/libioxd libioxd.a CC=gcc-14 CFLAGS="-O3 -march=native -flto -ffat-lto-objects"

COPY main.c .
RUN gcc-14 -O3 -march=native -flto -Wall -Wextra -std=gnu23 -pthread \
        -I/tmp/libioxd/include \
        main.c /tmp/libioxd/libioxd.a -o server -pthread -lssl -lcrypto -lbrotlienc -lz -lcjson

FROM ubuntu:24.04
RUN apt-get update && apt-get install -y --no-install-recommends libcjson1 libbrotli1 zlib1g \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /app/server /server
EXPOSE 8080 8081
CMD ["/server"]
