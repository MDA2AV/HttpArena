FROM rust:1.97-bookworm AS build
WORKDIR /app
# Build on the benchmark host, or a CPU with compatible instruction sets.
ENV RUSTFLAGS="-C target-cpu=native" \
    CARGO_PROFILE_RELEASE_LTO=thin
COPY Cargo.toml Cargo.lock ./
RUN mkdir src && echo "fn main() {}" > src/main.rs && cargo build --release --locked \
    && rm src/main.rs && cargo clean --release -p httparena-ntex
COPY src ./src
RUN cargo build --release --locked

FROM debian:bookworm-slim
COPY --from=build /app/target/release/httparena-ntex /server
EXPOSE 8080 8081
CMD ["/server"]
