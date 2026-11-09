FROM rust:1.99-trixie AS build
RUN apt-get update && apt-get install -y --no-install-recommends cmake libclang-dev && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY Cargo.toml Cargo.lock ./
RUN mkdir src && echo "fn main() {}" > src/main.rs && \
    cargo build --release --locked && \
    rm -rf src/ target/release/httparena-rama* target/release/deps/httparena_rama*
COPY src ./src
RUN cargo build --release --locked

FROM debian:trixie-slim
COPY --from=build /app/target/release/httparena-rama /server
EXPOSE 8080 8081 8082 8443
CMD ["/server"]
