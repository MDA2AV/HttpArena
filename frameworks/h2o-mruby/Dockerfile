FROM buildpack-deps:bookworm AS build

RUN apt-get update && apt-get install -y --no-install-recommends \
    cmake clang libssl-dev zlib1g-dev libbrotli-dev git bison ruby

# Build h2o from source with HTTP/3 (quicly + picotls submodules) and mruby
WORKDIR /tmp/h2o
RUN git clone --recurse-submodules --depth 1 https://github.com/h2o/h2o.git . && \
    cmake -B build \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_C_COMPILER=clang \
      -DCMAKE_C_FLAGS="-flto=auto -march=native -mtune=native" \
      -DWITH_MRUBY=on \
      -S . && \
    cmake --build build -j && \
    cmake --install build

FROM debian:bookworm-slim
# libbrotli1 carries libbrotlidec/libbrotlienc: the build stage installs
# libbrotli-dev, so h2o links against brotli and will not start without it
# ("error while loading shared libraries: libbrotlidec.so.1").
RUN apt-get update && apt-get install -y --no-install-recommends \
    libssl3 libbrotli1 jq && \
    rm -rf /var/lib/apt/lists/*
COPY --from=build /usr/local/bin/h2o /usr/local/bin/h2o
COPY --from=build /usr/local/share/h2o /usr/local/share/h2o
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
EXPOSE 8080 8443/tcp 8443/udp
CMD ["/entrypoint.sh"]
