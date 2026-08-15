FROM buildpack-deps:bookworm AS build

RUN apt-get update && apt-get install -y --no-install-recommends \
    cmake clang libssl-dev zlib1g-dev libuv1-dev libbrotli-dev

# Build h2o from source. No -flto here: linking upstream's standalone `h2o`
# target with LTO segfaults clang on current bookworm. The app below still
# builds with LTO, and it links libh2o-evloop as a shared object, so LTO would
# not have crossed that boundary anyway.
ARG H2O_VERSION=ccea64b17ade832753db933658047ede9f31a380
WORKDIR /tmp/h2o
RUN curl -LSs "https://github.com/h2o/h2o/archive/${H2O_VERSION}.tar.gz" | \
    tar --strip-components=1 -xz && \
    cmake -B build \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_C_COMPILER=clang \
      -DCMAKE_C_FLAGS="-march=native -mtune=native" \
      -DWITH_MRUBY=off \
      -S . && \
    cmake --build build -j && \
    cmake --install build

# Build app. Also no -flto: clang's LTO link segfaults here for the same
# reason as above, and the app is a single translation unit linking a shared
# libh2o-evloop, so there is nothing for LTO to inline across. -O3 -march=native
# still applies.
COPY CMakeLists.txt /app/
COPY src /app/src/
WORKDIR /app/build
RUN cmake \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_C_COMPILER=clang \
      -DCMAKE_C_FLAGS="-march=native -mtune=native" \
      -S .. && \
    cmake --build . -j

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
    libssl3 libbrotli1 && \
    rm -rf /var/lib/apt/lists/*
COPY --from=build /usr/local/lib/libh2o-evloop.so* /usr/local/lib/
COPY --from=build /app/build/h2o-app /server
RUN ldconfig
EXPOSE 8080 8081 8443
CMD ["/server"]
