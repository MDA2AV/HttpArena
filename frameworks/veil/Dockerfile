# The Proxy-Wasm module that answers /baseline11, /baseline2, /pipeline and /json/{count}.
FROM rust:1.98-bookworm AS filter
RUN rustup target add wasm32-wasip1
WORKDIR /filter
COPY filter/ .
RUN cargo build --release --locked --target wasm32-wasip1

# veil's published container image (full-container build: epoll readiness reactor, static binary).
FROM ghcr.io/aofusa/veil:musl-v0.10.1
COPY --from=filter /filter/target/wasm32-wasip1/release/httparena_filter.wasm /etc/veil/httparena_filter.wasm
COPY veil.toml /etc/veil/veil.toml
EXPOSE 8080 8081 8082 8443/tcp 8443/udp
CMD ["/veil", "-c", "/etc/veil/veil.toml"]
