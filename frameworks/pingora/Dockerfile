FROM rust:1.85-bookworm AS build
WORKDIR /app

# Pingora's "openssl" feature links against the system OpenSSL. bookworm
# ships libssl3 + libssl-dev already usable by the openssl-sys build script.
RUN apt-get update \
 && apt-get install -y --no-install-recommends pkg-config libssl-dev cmake \
 && rm -rf /var/lib/apt/lists/*

# Prime the dependency cache with an empty lib so we only rebuild app sources
# when src/ changes.
COPY Cargo.toml .
RUN mkdir src \
 && echo "fn main() {}" > src/main.rs \
 && cargo build --release \
 && rm -rf src/ target/release/httparena-pingora* target/release/deps/httparena_pingora*

COPY src ./src
RUN RUSTFLAGS="-C target-cpu=native" cargo build --release

FROM debian:bookworm-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates libssl3 \
 && rm -rf /var/lib/apt/lists/*
COPY --from=build /app/target/release/httparena-pingora /server
EXPOSE 8080
CMD ["/server"]
