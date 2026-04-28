FROM ghcr.io/userver-framework/ubuntu-24.04-userver-base AS builder

WORKDIR /src
RUN git clone https://github.com/userver-framework/userver.git && \
    cd userver && git checkout v3.0

COPY userver_benchmark/ ./
RUN mkdir build && cd build && \
    cmake -DUSERVER_IS_THE_ROOT_PROJECT=0 -DUSERVER_FEATURE_CRYPTOPP_BLAKE2=0 \
          -DUSERVER_FEATURE_UTEST=0 \
          -DUSERVER_FEATURE_POSTGRESQL=1 \
          -DUSERVER_FEATURE_ERASE_LOG_WITH_LEVEL=warning \
          -DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_FLAGS="-march=native" -DCMAKE_C_FLAGS="-march=native" \
          -DCMAKE_CXX_COMPILER=clang++-17 -DCMAKE_C_COMPILER=clang-17 \
          -DUSERVER_LTO=0 .. && \
    make -j $(nproc)

FROM builder AS runner
WORKDIR /app
COPY userver_configs/* ./
COPY --from=builder /src/build/userver_httparena ./

EXPOSE 8080
CMD ./userver_httparena -c ./static_config.yaml
