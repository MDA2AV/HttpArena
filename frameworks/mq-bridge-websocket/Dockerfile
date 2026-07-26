FROM rust:1.94 AS build
WORKDIR /app
COPY Cargo.toml .
RUN mkdir src && echo "fn main() {}" > src/main.rs && \
    cargo build --release && \
    rm -rf src target/release/httparena-mqbridge-ws* target/release/deps/httparena_mqbridge_ws*
COPY src ./src
RUN RUSTFLAGS="-C target-cpu=native" cargo build --release

FROM debian:bookworm-slim
COPY --from=build /app/target/release/httparena-mqbridge-ws /server
EXPOSE 8080
CMD ["/server"]
