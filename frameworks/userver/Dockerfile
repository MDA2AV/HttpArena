FROM ghcr.io/userver-framework/ubuntu-24.04-userver:v3.0 AS builder

WORKDIR /src
COPY userver_benchmark/ ./
RUN mkdir build && cd build && \
    cmake -DCMAKE_BUILD_TYPE=Release \
          -DCMAKE_CXX_FLAGS="-march=native" \
          -DCMAKE_C_FLAGS="-march=native" .. && \
    cmake --build . -j $(nproc)


FROM builder AS runner
WORKDIR /app
COPY --from=builder /src/configs/config-vars.httparena.yaml ./configs/config_vars.yaml
COPY --from=builder /src/configs/static_config.yaml ./configs/
COPY --from=builder /src/build/userver_httparena ./

EXPOSE 8080 8443 8081
CMD ./userver_httparena -c ./configs/static_config.yaml
