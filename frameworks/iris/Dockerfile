# =============================================================================
# HTTPArena image: IRIS gateway (baseline, pipelined, json, static, json-tls,
# async-db). Source is pulled from the public IRIS repository (AGPL-3.0).
# =============================================================================
FROM ubuntu:24.04 AS build

ARG IRIS_REPO=https://github.com/Cobra007-star-source/IRIS.git
ARG IRIS_REF=v0.3.2-ha

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        g++ cmake make git ca-certificates libpq-dev libssl-dev \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /src
RUN git clone --depth 1 --branch "${IRIS_REF}" "${IRIS_REPO}" .

RUN cmake -B build -DCMAKE_BUILD_TYPE=Release \
        -DIRIS_BUILD_GATEWAY=ON -DIRIS_PROFILE=racing -DIRIS_BUILD_DB=ON \
        -DIRIS_BUILD_EXAMPLES=OFF -DIRIS_BUILD_BENCHMARKS=OFF \
        -DIRIS_BUILD_TESTS=OFF -DIRIS_BUILD_SIMDJSON=OFF -DIRIS_BUILD_BOWTIE=OFF \
 && cmake --build build --target iris-ha-gw -j "$(nproc)"

FROM ubuntu:24.04
RUN apt-get update \
 && apt-get install -y --no-install-recommends libpq5 libssl3 \
 && rm -rf /var/lib/apt/lists/*

COPY --from=build /src/build/gateway/iris-ha-gw /iris-ha-gw

ENV PORT=8080
ENV TLS_PORT=8081
ENV DATASET_PATH=/data/dataset.json
ENV STATIC_DIR=/data/static
ENV TLS_CERT=/certs/server.crt
ENV TLS_KEY=/certs/server.key

EXPOSE 8080 8081
ENTRYPOINT ["/iris-ha-gw"]
