# nghttp2 1.69 includes the duration-mode connection shutdown fix in PR #2613.
# Keep glibc and jemalloc for the high-throughput load generator.

FROM ubuntu:24.04 AS builder
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates git cmake ninja-build g++ pkg-config \
    libssl-dev libev-dev libjemalloc-dev zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /src
RUN git clone --depth 1 --branch v1.69.0 --recurse-submodules --shallow-submodules https://github.com/nghttp2/nghttp2.git \
    && cmake -S nghttp2 -B build -G Ninja \
      -DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_STANDARD=20 \
      -DENABLE_APP=ON -DENABLE_EXAMPLES=OFF -DENABLE_HPACK_TOOLS=OFF \
      -DBUILD_SHARED_LIBS=OFF -DBUILD_STATIC_LIBS=ON \
    && cmake --build build --target h2load -j 4
FROM ubuntu:24.04
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates libev4t64 libjemalloc2 libssl3t64 zlib1g \
    && rm -rf /var/lib/apt/lists/*
COPY --from=builder /src/build/src/h2load /usr/local/bin/h2load
ENTRYPOINT ["h2load"]
