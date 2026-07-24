FROM ubuntu:24.04 AS build

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential autoconf automake libtool libltdl-dev pkg-config \
        git ca-certificates \
        liburing-dev libssl-dev \
    && rm -rf /var/lib/apt/lists/*

# Build libreactorng from source. The library is small (~200 KiB) and has
# zero third-party runtime deps, so we build it fresh every image rather
# than relying on a distro package (none ships it).
WORKDIR /tmp/libreactorng
RUN git clone --depth 1 https://github.com/fredrikwidlund/libreactorng.git . \
    && ./autogen.sh \
    && ./configure CFLAGS="-O3 -march=native" \
    && make -j"$(nproc)" \
    && make install \
    && ldconfig

# Build the bench server against the installed libreactor.
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
