FROM rust:1.95 AS build
RUN rustup default nightly-2026-05-07
WORKDIR /app
COPY Cargo.toml .
RUN mkdir src && echo "fn main() {}" > src/main.rs && cargo build --release && rm -rf src/ target/release/httparena-wtx-http2* target/release/deps/httparena_wtx-http2*
COPY src ./src
RUN RUSTFLAGS="-C target-cpu=native" cargo build --release

FROM debian:bookworm-slim
COPY --from=build /app/target/release/httparena-wtx-http2 /server
EXPOSE 8082
CMD ["/server"]
