FROM ubuntu:24.04 AS build
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates cmake ninja-build git g++-14 libssl-dev zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

ARG CINATRA_REF=21b958d48bff023a3cb4d9712641cb9fa7f3c8dd
WORKDIR /src/cinatra
RUN git init . \
    && git remote add origin https://github.com/qicosmos/cinatra.git \
    && git fetch --depth 1 origin ${CINATRA_REF} \
    && git checkout --detach FETCH_HEAD \
    && git submodule update --init --depth 1 iguana
RUN cmake -S benchmark/httparena -B build -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_CXX_COMPILER=g++-14 \
        -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=ON \
    && cmake --build build -j$(nproc) \
    && strip build/bin/httparena_server

FROM ubuntu:24.04
RUN apt-get update && apt-get install -y --no-install-recommends \
        libstdc++6 libssl3t64 zlib1g \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /src/cinatra/build/bin/httparena_server /server
EXPOSE 8080 8081
ENTRYPOINT ["/server"]
