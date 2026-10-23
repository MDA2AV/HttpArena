ARG FLARE_REPO=https://github.com/ehsanmok/flare.git
ARG FLARE_REF=v0.13.0
ARG FLARE_COMMIT=8fe83c5ee12bbc15d672387055171bca4ed7c50f

# rustls C-ABI shim for QUIC (HTTP/3).
FROM rust:1-bookworm AS rustls
ARG FLARE_REPO
ARG FLARE_REF
ARG FLARE_COMMIT
RUN git clone --depth 1 --branch "${FLARE_REF}" "${FLARE_REPO}" /flare && \
    test "$(git -C /flare rev-parse HEAD)" = "${FLARE_COMMIT}"
RUN cargo build --release --locked --manifest-path /flare/flare/tls/ffi/rustls_wrapper/Cargo.toml

# Mojo toolchain and dependencies from flare's pixi.lock; `pixi run` also
# builds flare's OpenSSL / zlib / brotli / fs shims on activation.
FROM ghcr.io/prefix-dev/pixi:0.82.1-noble AS build
ARG FLARE_REPO
ARG FLARE_REF
ARG FLARE_COMMIT
RUN apt-get update && apt-get install -y --no-install-recommends git ca-certificates && \
    rm -rf /var/lib/apt/lists/*
RUN git clone --depth 1 --branch "${FLARE_REF}" "${FLARE_REPO}" /flare && \
    test "$(git -C /flare rev-parse HEAD)" = "${FLARE_COMMIT}"
WORKDIR /flare
RUN pixi install --locked
COPY main.mojo /src/main.mojo
RUN mkdir -p /out/bin /out/lib && \
    pixi run mojo build -D ASSERT=none -I . /src/main.mojo -o /out/bin/server
COPY --from=rustls /flare/flare/tls/ffi/rustls_wrapper/target/release/libflare_rustls_quic.so /out/lib/
# Stage the shims, simdjson's wrapper, and every library they and the
# server resolve from the pixi environment.
RUN pixi run sh -c ' \
    cp -L "$CONDA_PREFIX"/lib/libflare_tls.so "$CONDA_PREFIX"/lib/libflare_zlib.so \
          "$CONDA_PREFIX"/lib/libflare_brotli.so "$CONDA_PREFIX"/lib/libflare_fs.so \
          "$CONDA_PREFIX"/lib/libsimdjson_wrapper.so /out/lib/ && \
    LD_LIBRARY_PATH="$CONDA_PREFIX/lib" ldd /out/bin/server /out/lib/*.so \
      | awk -v p="$CONDA_PREFIX/lib/" "index(\$3, p) == 1 {print \$3}" | sort -u \
      | xargs -I{} cp -L {} /out/lib/'

FROM ubuntu:24.04
WORKDIR /app
COPY --from=build /out/bin/server /app/bin/server
COPY --from=build /out/lib/ /app/lib/
COPY start.sh /app/start.sh
ENV LD_LIBRARY_PATH=/app/lib FLARE_LIB_DIR=/app/lib CONDA_PREFIX=/app MAX_KEEPALIVE=1000000
CMD ["/app/start.sh"]
