FROM ubuntu:24.04 AS build

ARG DOBA_REF=v0.1.0

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       ca-certificates \
       cmake \
       g++ \
       make \
       libssl-dev \
       rapidjson-dev \
       zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

ADD "https://github.com/martianlabs/doba.git#${DOBA_REF}" /doba

WORKDIR /source
COPY CMakeLists.txt main.cpp ./

RUN cmake -S . -B /build \
      -DCMAKE_BUILD_TYPE=Release \
      -DDOBA_HTTPARENA_FULL=ON \
      -DDOBA_INCLUDE_DIR=/doba/include \
    && cmake --build /build --config Release --parallel

FROM ubuntu:24.04

RUN apt-get update \
    && apt-get install -y --no-install-recommends libssl3t64 zlib1g \
    && rm -rf /var/lib/apt/lists/*

COPY --from=build /build/doba_httparena_http_v11 /server

EXPOSE 8080 8081

ENTRYPOINT ["/server"]
