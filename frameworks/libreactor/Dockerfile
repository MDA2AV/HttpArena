FROM ubuntu:24.04 AS build

RUN apt-get update && apt-get install -y \
    gcc make autoconf automake libtool pkg-config \
    libssl-dev git ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Build libreactor from source (v3.0.0)
RUN git clone --depth 1 https://github.com/fredrikwidlund/libreactor.git /tmp/libreactor \
    && cd /tmp/libreactor \
    && ./autogen.sh \
    && ./configure \
    && make -j$(nproc) \
    && make install \
    && ldconfig \
    && rm -rf /tmp/libreactor

WORKDIR /app
COPY server.c .

RUN gcc -O3 -march=native -flto -o server server.c \
    $(pkg-config --cflags --libs libreactor) -lssl -lcrypto

FROM ubuntu:24.04
RUN apt-get update && apt-get install -y libssl3t64 && rm -rf /var/lib/apt/lists/*
COPY --from=build /usr/lib/libreactor* /usr/lib/
COPY --from=build /app/server /server
RUN ldconfig

EXPOSE 8080
CMD ["/server"]
