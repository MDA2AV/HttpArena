FROM rust:1.94-trixie AS build
WORKDIR /app

COPY Cargo.toml Cargo.lock* ./
COPY src/ src/

# Build on the benchmark host, or a CPU with compatible instruction sets.
RUN RUSTFLAGS="-C target-cpu=native" cargo build --release

FROM debian:trixie-slim
WORKDIR /app

COPY --from=build /app/target/release/actix-websocket .

EXPOSE 8080
ENTRYPOINT ["./actix-websocket"]
