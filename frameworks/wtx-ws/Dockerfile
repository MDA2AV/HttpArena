FROM rust:1.95 AS build
RUN rustup default nightly-2026-05-07
WORKDIR /app
COPY Cargo.toml .
RUN mkdir src && echo "fn main() {}" > src/main.rs && cargo build --release && rm -rf src/ target/release/httparena-wtx-ws* target/release/deps/httparena_wtx-ws*
COPY src ./src
RUN RUSTFLAGS="-C target-cpu=native" cargo build --release

FROM debian:bookworm-slim
COPY --from=build /app/target/release/httparena-wtx-ws /server
EXPOSE 8080
CMD ["/server"]
