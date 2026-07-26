FROM rust:1.95-slim-bookworm AS build
RUN apt-get update \
    && apt-get install -y --no-install-recommends pkg-config libssl-dev protobuf-compiler \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /build
COPY . .
ARG BIN=httparena-sark
RUN RUSTFLAGS="-C target-cpu=native" cargo build --release -p httparena-sark --bin "$BIN"

FROM debian:bookworm-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*
ARG BIN=httparena-sark
COPY --from=build /build/target/release/${BIN} /server
ENTRYPOINT ["/server"]
