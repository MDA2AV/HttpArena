FROM ubuntu:24.04 AS build

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates cmake curl g++-14 libaio-dev ninja-build \
    && rm -rf /var/lib/apt/lists/*
ENV CXX=g++-14

ARG GALAY_REF=4bd05e43309314746f9a7663b10e608cada32826
WORKDIR /src/galay
RUN curl -fLSs --retry 3 "https://codeload.github.com/gzj-creator/galay/tar.gz/${GALAY_REF}" -o /tmp/galay.tar.gz \
    && tar -xzf /tmp/galay.tar.gz --strip-components=1 \
    && rm /tmp/galay.tar.gz \
    && cmake --preset consumer-minimal -G Ninja -B /build/galay \
        -DGALAY_BUILD_HTTP=ON -DGALAY_BUILD_DEBUG=OFF -DGALAY_BUILD_SHARED_LIBS=OFF \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/opt/galay \
    && cmake --build /build/galay --target install -j"$(nproc)"

WORKDIR /src/arena
COPY CMakeLists.txt main.cc ./
RUN cmake -S . -B /build/arena -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_PREFIX_PATH=/opt/galay \
    && cmake --build /build/arena -j"$(nproc)" \
    && strip /build/arena/server

FROM ubuntu:24.04

RUN apt-get update && apt-get install -y --no-install-recommends libaio1t64 libstdc++6 \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /build/arena/server /server

EXPOSE 8080
ENTRYPOINT ["/server"]
