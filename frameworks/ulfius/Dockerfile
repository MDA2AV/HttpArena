FROM ubuntu:24.04 AS build

RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc make cmake git ca-certificates pkg-config \
    libmicrohttpd-dev libjansson-dev libcurl4-openssl-dev \
    libgnutls28-dev libsqlite3-dev zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

# Build ulfius and its dependency orcania/yder from source
WORKDIR /tmp
RUN git clone --depth 1 --branch v2.3.3 https://github.com/babelouest/orcania.git && \
    cd orcania && cmake -B build -DCMAKE_BUILD_TYPE=Release -S . && \
    cmake --build build -j$(nproc) && cmake --install build

RUN git clone --depth 1 --branch v1.4.20 https://github.com/babelouest/yder.git && \
    cd yder && cmake -B build -DCMAKE_BUILD_TYPE=Release -DWITH_JOURNALD=OFF -S . && \
    cmake --build build -j$(nproc) && cmake --install build

RUN git clone --depth 1 --branch v2.7.15 https://github.com/babelouest/ulfius.git && \
    cd ulfius && cmake -B build -DCMAKE_BUILD_TYPE=Release \
      -DWITH_WEBSOCKET=OFF -DWITH_CURL=OFF \
      -DCMAKE_C_FLAGS="-O3 -flto" \
      -S . && \
    cmake --build build -j$(nproc) && cmake --install build

RUN ldconfig

# Build our server
WORKDIR /app
COPY src/server.c ./
RUN gcc -O3 -flto -march=native -o server server.c \
    $(pkg-config --cflags --libs libulfius) \
    -ljansson -lsqlite3 -lz -lm -lpthread

FROM ubuntu:24.04
RUN apt-get update && apt-get install -y --no-install-recommends \
    libmicrohttpd12t64 libjansson4 libgnutls30t64 libsqlite3-0 zlib1g && \
    rm -rf /var/lib/apt/lists/*
COPY --from=build /usr/local/lib/libulfius.so* /usr/local/lib/
COPY --from=build /usr/local/lib/liborcania.so* /usr/local/lib/
COPY --from=build /usr/local/lib/libyder.so* /usr/local/lib/
COPY --from=build /app/server /server
RUN ldconfig

EXPOSE 8080 8443
CMD ["/server"]
