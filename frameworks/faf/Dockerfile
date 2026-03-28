FROM rust:1.88 AS build
WORKDIR /app
COPY Cargo.toml .
RUN mkdir src && echo "fn main() {}" > src/main.rs && cargo build --release && rm -rf src/ target/release/httparena-faf* target/release/deps/httparena_faf*
COPY src ./src
RUN RUSTFLAGS="-C target-cpu=native" cargo build --release && strip target/release/httparena-faf

FROM debian:bookworm-slim
COPY --from=build /app/target/release/httparena-faf /server
EXPOSE 8080
CMD ["/server"]
