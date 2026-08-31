FROM rust:1.94 AS build
WORKDIR /app
COPY Cargo.toml .
RUN mkdir src && echo "fn main() {}" > src/main.rs && cargo build --release \
    && rm -rf src/ target/release/httparena-salvo* target/release/deps/httparena_salvo*
COPY src ./src
RUN cargo build --release

FROM debian:trixie-slim
COPY --from=build /app/target/release/httparena-salvo /server
EXPOSE 8080
CMD ["/server"]
