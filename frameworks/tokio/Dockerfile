FROM rust:1.95 AS build
WORKDIR /app
COPY Cargo.toml Cargo.lock ./
RUN mkdir src && echo "fn main() {}" > src/main.rs \
    && cargo build --release \
    && rm -rf src target/release/httparena-tokio target/release/deps/httparena_tokio*
COPY src ./src
RUN RUSTFLAGS="-C target-cpu=native" cargo build --release

FROM debian:bookworm-slim
COPY --from=build /app/target/release/httparena-tokio /server
EXPOSE 8080
CMD ["/server"]
