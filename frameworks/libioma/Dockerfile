FROM ubuntu:24.04 AS build
RUN apt-get update && apt-get install -y --no-install-recommends \
        gcc-14 make curl ca-certificates libc6-dev \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app

# Build libioma from its own repo, pinned to a commit (the h2o pattern: fetch upstream at a fixed
# SHA and build it here, tuned for this CPU). No liburing: libioma issues the io_uring syscalls
# directly. Only the baseline handler lives in this entry. Fat LTO objects for the library and
# -flto on the handler link, so the handler inlines into the engine.
ARG LIBIOMA_VERSION=b027f05360b8ae5192bd73133437663cd645bac1
RUN mkdir -p /tmp/libioma && \
    curl -LSs "https://github.com/MDA2AV/libioma/archive/${LIBIOMA_VERSION}.tar.gz" \
      | tar --strip-components=1 -xz -C /tmp/libioma && \
    make -C /tmp/libioma libioma.a CC=gcc-14 CFLAGS="-O3 -march=native -flto -ffat-lto-objects"

COPY main.c .
RUN gcc-14 -O3 -march=native -flto -Wall -std=gnu11 -pthread \
        -I/tmp/libioma/include \
        main.c /tmp/libioma/libioma.a -o server -pthread

FROM ubuntu:24.04
COPY --from=build /app/server /server
EXPOSE 8080
CMD ["/server"]
