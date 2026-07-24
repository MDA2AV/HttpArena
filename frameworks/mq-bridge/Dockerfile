FROM rust:1.94 AS build
WORKDIR /app
# git is needed for the pinned git dependency on mq-bridge.
COPY Cargo.toml .
# Pre-cache dependencies against a stub so source edits don't refetch the graph.
RUN mkdir src && echo "fn main() {}" > src/main.rs && \
    cargo build --release && \
    rm -rf src target/release/httparena-mqbridge* target/release/deps/httparena_mqbridge*
COPY src ./src
RUN RUSTFLAGS="-C target-cpu=native" cargo build --release

FROM debian:bookworm-slim
COPY --from=build /app/target/release/httparena-mqbridge /server
# 8080: HTTP/1.1 + h2c.  8443: HTTP/2 over TLS (certs mounted at /certs).
EXPOSE 8080 8443
CMD ["/server"]
