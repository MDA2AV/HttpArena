FROM rust:1.94-trixie AS build
WORKDIR /app
COPY Cargo.toml Cargo.lock ./
RUN mkdir src && echo "fn main() {}" > src/main.rs && cargo build --release --locked && rm -rf src/ target/release/httparena-actix* target/release/deps/httparena_actix*
COPY src ./src
RUN RUSTFLAGS="-C target-cpu=native" cargo build --release --locked

FROM debian:trixie-slim
COPY --from=build /app/target/release/httparena-actix /server
EXPOSE 8080
CMD ["/server"]
