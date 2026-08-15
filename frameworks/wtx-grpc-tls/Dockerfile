FROM rust:1.95 AS build
RUN rustup default nightly-2026-06-27
WORKDIR /app
COPY Cargo.toml build.rs ./
COPY proto ./proto
RUN mkdir src && echo "fn main() {}" > src/main.rs && cargo build --release && rm -rf src/ target/release/httparena-wtx-grpc-tls* target/release/deps/httparena_wtx-grpc-tls*
COPY src ./src
RUN RUSTFLAGS="-C target-cpu=native" cargo build --release

FROM debian:bookworm-slim
COPY --from=build /app/target/release/httparena-wtx-grpc-tls /server
EXPOSE 8443
CMD ["/server"]
