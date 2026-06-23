FROM rust:1.95-slim-bookworm AS build
RUN apt-get update \
    && apt-get install -y --no-install-recommends pkg-config libssl-dev protobuf-compiler \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /build
COPY . .
RUN RUSTFLAGS="-C target-cpu=native" cargo build --release -p httparena-grpc

FROM debian:bookworm-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*
ARG GRPC_TLS=0
ENV SARK_GRPC_TLS=${GRPC_TLS}
COPY --from=build /build/target/release/httparena-sark-grpc /server
ENTRYPOINT ["/server"]
