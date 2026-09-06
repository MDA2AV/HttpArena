FROM ubuntu:24.04 AS build
RUN apt-get update && apt-get install -y --no-install-recommends \
        gcc make curl ca-certificates libc6-dev \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app

# Build libioma from its own repo, pinned to a commit for reproducibility (the h2o pattern: fetch
# upstream at a fixed SHA and build it here, tuned for this CPU). No liburing — libioma issues the
# io_uring syscalls directly. Only the baseline handler lives in this entry.
ARG LIBIOMA_VERSION=0127a7cef6813f46fd7f6ae094725d4c7e86bd7a
RUN mkdir -p /tmp/libioma && \
    curl -LSs "https://github.com/MDA2AV/libioma/archive/${LIBIOMA_VERSION}.tar.gz" \
      | tar --strip-components=1 -xz -C /tmp/libioma && \
    make -C /tmp/libioma libioma.a CFLAGS="-O2 -march=native"

COPY main.c .
RUN gcc -O2 -march=native -Wall -std=gnu11 -pthread \
        -I/tmp/libioma/include \
        main.c /tmp/libioma/libioma.a -o server -pthread

FROM ubuntu:24.04
COPY --from=build /app/server /server
EXPOSE 8080
CMD ["/server"]
