FROM ubuntu:24.04 AS build

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates clang-20 cmake git ninja-build \
    && rm -rf /var/lib/apt/lists/*

# hidi and its dependencies (Boost, AWS-LC, kelcoro, ...) are fetched by hidi's CMake (CPM)
ARG HIDI_COMMIT=8ef2451db0252dab7f5ab4c05928e75f7644a56c
RUN git clone --filter=blob:none https://github.com/kelbon/hidi.git /src/hidi \
    && git -C /src/hidi checkout ${HIDI_COMMIT}

COPY CMakeLists.txt main.cpp /src/entry/
WORKDIR /src/entry

RUN cmake -S . -B build -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_COMPILER=clang-20 \
        -DCMAKE_CXX_COMPILER=clang++-20 \
        -DCMAKE_C_FLAGS="-march=native -mtune=native" \
        -DCMAKE_CXX_FLAGS="-march=native -mtune=native" \
        -DHIDI_DIR=/src/hidi \
    && cmake --build build --target server --parallel "$(nproc)"

FROM ubuntu:24.04
RUN apt-get update \
    && apt-get install -y --no-install-recommends libjemalloc2 \
    && rm -rf /var/lib/apt/lists/*
ENV LD_PRELOAD=libjemalloc.so.2
COPY --from=build /src/entry/build/server /server
EXPOSE 8443 8082
CMD ["/server"]
