FROM rust:1.94 AS build
WORKDIR /app
COPY Cargo.toml .
RUN mkdir src && echo "fn main() {}" > src/main.rs && cargo build --release && rm -rf src/ target/release/httparena-rocket* target/release/deps/httparena_rocket*
COPY src ./src
RUN cargo build --release

FROM debian:bookworm-slim
COPY --from=build /app/target/release/httparena-rocket /server
ENV ROCKET_ADDRESS=0.0.0.0 \
    ROCKET_PORT=8080 \
    ROCKET_LOG_LEVEL=off
EXPOSE 8080
CMD ["/server"]
