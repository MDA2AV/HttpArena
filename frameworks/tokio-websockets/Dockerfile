FROM rust:1.95 AS build
RUN rustup default nightly-2026-06-27
WORKDIR /app
COPY Cargo.toml .
RUN mkdir src && echo "fn main() {}" > src/main.rs && cargo build --release && rm -rf src/ target/release/httparena-tokio-websockets* target/release/deps/httparena_tokio-websockets*
COPY src ./src
RUN RUSTFLAGS="-C target-cpu=native" cargo build --release

FROM debian:bookworm-slim
COPY --from=build /app/target/release/httparena-tokio-websockets /server
EXPOSE 8080
CMD ["/server"]
