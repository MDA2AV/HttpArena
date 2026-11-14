FROM rust:1.97-bookworm AS build
WORKDIR /app
# Build on the benchmark host, or a CPU with compatible instruction sets.
ENV RUSTFLAGS="-C target-cpu=native"
COPY Cargo.toml Cargo.lock ./
RUN mkdir src && echo "fn main() {}" > src/main.rs && cargo build --release --locked \
    && cargo clean --release -p httparena-ntex-ws && rm src/main.rs
COPY src ./src
RUN cargo build --release --locked

FROM debian:bookworm-slim
COPY --from=build /app/target/release/httparena-ntex-ws /server
EXPOSE 8080
CMD ["/server"]
