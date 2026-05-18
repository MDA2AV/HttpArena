FROM rust:1.94-bookworm AS build
WORKDIR /app
COPY Cargo.toml .
RUN mkdir src && echo "fn main() {}" > src/main.rs && \
    cargo build --release && \
    rm -rf src/ target/release/httparena-trillium-proxy* target/release/deps/httparena_trillium_proxy*
COPY src ./src
RUN RUSTFLAGS="-C target-cpu=native" cargo build --release

FROM debian:bookworm-slim
COPY --from=build /app/target/release/httparena-trillium-proxy /server
EXPOSE 8443/tcp 8443/udp
CMD ["/server"]
