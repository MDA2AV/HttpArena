FROM ubuntu:24.04 AS build

ENV DEBIAN_FRONTEND=noninteractive

# libstdc++ 14: BT-YE uses <print>, clang-20 alone brings libstdc++ 13
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates clang-20 libstdc++-14-dev cmake git ninja-build \
    && rm -rf /var/lib/apt/lists/*

# BT-YE and its dependencies (svarg, hidi, Boost, AWS-LC, kelcoro, ...) are fetched by its CMake (CPM)
ARG BTYE_COMMIT=2f3a38f46ee8d80e84a6f70159048ec57182c39b
RUN git clone --filter=blob:none https://github.com/kelbon/BT-YE.git /src/btye \
    && git -C /src/btye checkout ${BTYE_COMMIT}

COPY CMakeLists.txt arena.yaml main.cpp /src/entry/
WORKDIR /src/entry

RUN cmake -S . -B build -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_COMPILER=clang-20 \
        -DCMAKE_CXX_COMPILER=clang++-20 \
        -DCMAKE_C_FLAGS="-march=native -mtune=native" \
        -DCMAKE_CXX_FLAGS="-march=native -mtune=native" \
        -DBTYE_DIR=/src/btye \
    && cmake --build build --target server --parallel "$(nproc)"

FROM ubuntu:24.04
COPY --from=build /src/entry/build/server /server
EXPOSE 8443 8082
CMD ["/server"]
