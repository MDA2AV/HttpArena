FROM rust:1.94-trixie AS build
WORKDIR /app

COPY Cargo.toml Cargo.lock* ./
COPY src/ src/

RUN cargo build --release

FROM debian:trixie-slim
WORKDIR /app

COPY --from=build /app/target/release/actix-websocket .

EXPOSE 8080
ENTRYPOINT ["./actix-websocket"]
