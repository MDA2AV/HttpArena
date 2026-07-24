FROM buildpack-deps:bookworm AS build

RUN apt-get update && apt-get install -y --no-install-recommends \
    cmake clang libssl-dev zlib1g-dev libuv1-dev libbrotli-dev libcjson-dev

# Build h2o from source (same pin as the infrastructure h2o entry)
ARG H2O_VERSION=ccea64b17ade832753db933658047ede9f31a380
WORKDIR /tmp/h2o
RUN curl -LSs "https://github.com/h2o/h2o/archive/${H2O_VERSION}.tar.gz" | \
    tar --strip-components=1 -xz && \
    cmake -B build \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_C_COMPILER=clang \
      -DCMAKE_C_FLAGS="-flto=auto -march=native -mtune=native" \
      -DWITH_MRUBY=off \
      -S . && \
    cmake --build build -j && \
    cmake --install build

# Build app
COPY CMakeLists.txt /app/
COPY src /app/src/
WORKDIR /app/build
RUN cmake \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_C_COMPILER=clang \
      -DCMAKE_C_FLAGS="-flto=auto -march=native -mtune=native" \
      -S .. && \
    cmake --build . -j

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
    libssl3 libbrotli1 libcjson1 && \
    rm -rf /var/lib/apt/lists/*
COPY --from=build /usr/local/lib/libh2o-evloop.so* /usr/local/lib/
COPY --from=build /app/build/h2o-h2c-app /server
RUN ldconfig
EXPOSE 8082
CMD ["/server"]
