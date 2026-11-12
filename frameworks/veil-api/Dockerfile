FROM rust:1.98-bookworm AS build
RUN apt-get update -y && apt-get install -y --no-install-recommends cmake nasm libclang-dev protobuf-compiler \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY . .
RUN cargo build --release --locked

FROM debian:bookworm-slim
COPY --from=build /app/target/release/httparena-veil-api /app/server
COPY veil.toml /app/veil.toml
EXPOSE 8080 8081 8082 8443/tcp 8443/udp
CMD ["/app/server"]
