FROM rust:1.94-trixie AS build
WORKDIR /app
# Build on the benchmark host, or a CPU with compatible instruction sets.
ENV RUSTFLAGS="-C target-cpu=native"
COPY Cargo.toml Cargo.lock ./
RUN mkdir src && echo "fn main() {}" > src/main.rs && cargo build --release --locked \
    && cargo clean --release -p httparena-actix && rm src/main.rs
COPY src ./src
COPY askama.toml ./
COPY templates ./templates
RUN cargo build --release --locked

FROM debian:trixie-slim
COPY --from=build /app/target/release/httparena-actix /server
EXPOSE 8080 8081 8443
CMD ["/server"]
