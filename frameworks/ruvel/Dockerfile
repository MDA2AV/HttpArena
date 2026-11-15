FROM rust:1.100-trixie AS build
WORKDIR /app
COPY Cargo.toml Cargo.lock ./
RUN mkdir src && echo "fn main() {}" > src/main.rs && cargo build --release --locked && rm -rf src/ target/release/server* target/release/deps/server*
COPY src ./src
RUN  RUSTFLAGS="-C target-cpu=native" cargo build --release

FROM debian:trixie-slim
COPY --from=build /app/target/release/server /server
ENV PORT=8080
EXPOSE 8080
CMD ["/server"]

