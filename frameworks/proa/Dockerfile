FROM rust:1.99-bookworm AS build
WORKDIR /work
RUN apt-get update && apt-get install -y --no-install-recommends cmake && rm -rf /var/lib/apt/lists/*
ENV RUSTFLAGS="-C target-cpu=native"
ENV CFLAGS="-O3 -march=native"
COPY Cargo.toml Cargo.lock ./
COPY src/ src/
RUN cargo build --release --locked

FROM debian:bookworm-slim
COPY --from=build /work/target/release/httparena-proa /usr/local/bin/httparena-proa
EXPOSE 8080 8081
ENTRYPOINT ["/usr/local/bin/httparena-proa"]
