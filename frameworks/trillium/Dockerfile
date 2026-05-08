FROM rust:1.94-bookworm AS build
WORKDIR /app
COPY Cargo.toml .
RUN mkdir src && echo "fn main() {}" > src/main.rs && \
    cargo build --release && \
    rm -rf src/ target/release/httparena-trillium* target/release/deps/httparena_trillium*
COPY src ./src
COPY templates ./templates
COPY askama.toml .
RUN RUSTFLAGS="-C target-cpu=native" cargo build --release

FROM debian:bookworm-slim
COPY --from=build /app/target/release/httparena-trillium /server
EXPOSE 8080 8081 8443/tcp 8443/udp
CMD ["/server"]
