# =============================================================================
# HTTPArena image: IRIS gateway (baseline, pipelined, json, static).
# Source is pulled from the public IRIS repository (AGPL-3.0) at a pinned ref.
# =============================================================================
FROM ubuntu:24.04 AS build

ARG IRIS_REPO=https://github.com/Cobra007-star-source/IRIS.git
ARG IRIS_REF=v0.3.0-ha

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        g++ cmake make git ca-certificates \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /src
RUN git clone --depth 1 --branch "${IRIS_REF}" "${IRIS_REPO}" .

RUN cmake -B build -DCMAKE_BUILD_TYPE=Release \
        -DIRIS_BUILD_GATEWAY=ON -DIRIS_PROFILE=racing -DIRIS_BUILD_DB=OFF \
        -DIRIS_BUILD_EXAMPLES=OFF -DIRIS_BUILD_BENCHMARKS=OFF \
        -DIRIS_BUILD_TESTS=OFF -DIRIS_BUILD_SIMDJSON=OFF -DIRIS_BUILD_BOWTIE=OFF \
 && cmake --build build --target iris-ha-gw -j "$(nproc)"

FROM ubuntu:24.04
COPY --from=build /src/build/gateway/iris-ha-gw /iris-ha-gw

ENV PORT=8080
ENV DATASET_PATH=/data/dataset.json
ENV STATIC_DIR=/data/static

EXPOSE 8080
ENTRYPOINT ["/iris-ha-gw", "--port", "8080"]
